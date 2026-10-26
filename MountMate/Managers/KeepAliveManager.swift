//  Created by homielab.com

import AppKit
import Combine
import Foundation
import Network

/// Keeps designated mounts alive.
///
/// Owns the automatic reconnection loop for:
/// - **Network shares** marked "Keep Mounted" (SMB, NFS, AFP)
/// - **Local/external volumes** marked "Keep Mounted" (USB, Thunderbolt, …)
///
/// Triggers:
/// - A periodic sweep at the configured interval (with exponential backoff
///   per target while the target is down)
/// - Network path changes (`NWPathMonitor`): on interface switch, mounts are
///   remounted through the new primary interface; on network recovery, a
///   reconnect sweep starts immediately
/// - System wake (`NSWorkspace.didWakeNotification`): prompt reconnect sweep
/// - App launch / login: initial sweep
///
/// The manager never fights the user: volumes and shares unmounted explicitly
/// through MountMate are suppressed until the user mounts them again.
///
/// Phase 2 (cloud storage mounts) can plug into the same sweep/backoff
/// machinery without further architectural changes.
class KeepAliveManager: ObservableObject {
  static let shared = KeepAliveManager()

  // MARK: - Settings Keys

  private enum SettingsKey {
    static let enabled = "keepAliveEnabled"
    static let retryInterval = "keepAliveRetryInterval"
    static let remountOnNetworkChange = "keepAliveRemountOnNetworkChange"
    static let remountOnWake = "keepAliveRemountOnWake"
  }

  /// Base delay between reconnect attempts for a target, in seconds.
  static let allowedRetryIntervals: [Double] = [10, 30, 60, 120, 300]

  // MARK: - Published State

  /// Master switch for the whole keep-alive feature.
  @Published var isEnabled: Bool {
    didSet {
      guard oldValue != isEnabled else { return }
      UserDefaults.standard.set(isEnabled, forKey: SettingsKey.enabled)
      if isEnabled {
        sweepNow()
      } else {
        resetRetryState()
      }
    }
  }

  /// Base reconnect interval in seconds. Backoff doubles this per consecutive
  /// failure, up to eight times the base interval.
  @Published var retryInterval: Double {
    didSet {
      guard oldValue != retryInterval else { return }
      UserDefaults.standard.set(retryInterval, forKey: SettingsKey.retryInterval)
      startSweepTimer()
    }
  }

  /// Remount active shares when the primary network interface changes.
  @Published var remountOnNetworkChange: Bool {
    didSet {
      guard oldValue != remountOnNetworkChange else { return }
      UserDefaults.standard.set(
        remountOnNetworkChange, forKey: SettingsKey.remountOnNetworkChange)
    }
  }

  /// Reconnect shares and volumes promptly after the Mac wakes from sleep.
  @Published var remountOnWake: Bool {
    didSet {
      guard oldValue != remountOnWake else { return }
      UserDefaults.standard.set(remountOnWake, forKey: SettingsKey.remountOnWake)
    }
  }

  /// Identifiers of targets that are currently down and being retried.
  @Published private(set) var reconnectingShareIDs: Set<UUID> = []
  @Published private(set) var reconnectingVolumeIDs: Set<String> = []

  var maxRetryInterval: Double { retryInterval * 8 }

  // MARK: - Retry State

  private var shareRetries = RetryBook<UUID>()
  private var volumeRetries = RetryBook<String>()
  private let retryStateLock = NSLock()

  /// Identifiers of targets the user unmounted on purpose (session-scoped).
  private var suppressedShareIDs: Set<UUID> = []
  private var suppressedVolumeIDs: Set<String> = []
  private let suppressionLock = NSLock()

  // MARK: - Infrastructure

  private var sweepTimer: Timer?
  private var pathMonitor: NWPathMonitor?
  private let pathMonitorQueue = DispatchQueue(label: "com.homielab.mountmate.pathmonitor")
  private var cancellables = Set<AnyCancellable>()
  /// Main thread only.
  private var isSweeping = false
  /// Incremented for every sweep so a late completion (or the watchdog) of
  /// an older sweep never resets `isSweeping` for a newer one. Main only.
  private var sweepGeneration = 0
  /// Upper bound for one sweep. Mounts have their own timeouts, but if some
  /// completion still never arrives, `isSweeping` must not stay stuck (which
  /// would silently disable keep-alive for the rest of the session).
  private static let sweepWatchdogInterval: TimeInterval = 180

  /// The non-tunnel interface network paths were last routed through.
  /// Main thread only.
  private var currentInterface: InterfaceSnapshot?

  private init() {
    let defaults = UserDefaults.standard
    isEnabled =
      defaults.object(forKey: SettingsKey.enabled) == nil
      ? true : defaults.bool(forKey: SettingsKey.enabled)
    remountOnNetworkChange =
      defaults.object(forKey: SettingsKey.remountOnNetworkChange) == nil
      ? true : defaults.bool(forKey: SettingsKey.remountOnNetworkChange)
    remountOnWake =
      defaults.object(forKey: SettingsKey.remountOnWake) == nil
      ? true : defaults.bool(forKey: SettingsKey.remountOnWake)
    let storedInterval =
      defaults.object(forKey: SettingsKey.retryInterval) == nil
      ? 30.0 : defaults.double(forKey: SettingsKey.retryInterval)
    retryInterval = Self.allowedRetryIntervals.contains(storedInterval) ? storedInterval : 30.0

    startSweepTimer()
    startNetworkMonitoring()
    setupWakeObserver()

    // Delay the login sweep so the network stack and disk list are ready.
    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
      self?.sweepNow()
    }

    PersistenceManager.shared.$networkShares
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.reconcileTargets() }
      .store(in: &cancellables)
    PersistenceManager.shared.$keepAliveVolumes
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.reconcileTargets() }
      .store(in: &cancellables)
  }

  deinit {
    sweepTimer?.invalidate()
    pathMonitor?.cancel()
    NSWorkspace.shared.notificationCenter.removeObserver(self)
  }

  // MARK: - Public API (user intent)

  /// Called when the user explicitly unmounts a share through MountMate.
  func suppress(shareID: UUID) {
    suppressionLock.lock()
    suppressedShareIDs.insert(shareID)
    suppressionLock.unlock()
    retryStateLock.lock()
    shareRetries.remove(shareID)
    retryStateLock.unlock()
    DispatchQueue.main.async { [weak self] in
      self?.reconnectingShareIDs.remove(shareID)
      NotificationManager.shared.keepAliveForget(targetID: Self.notificationKey(shareID: shareID))
    }
  }

  /// Called when the user explicitly unmounts a volume through MountMate.
  func suppress(volume: Volume) {
    guard let compositeId = volume.compositeId else { return }
    suppressionLock.lock()
    suppressedVolumeIDs.insert(compositeId)
    suppressionLock.unlock()
    retryStateLock.lock()
    volumeRetries.remove(compositeId)
    retryStateLock.unlock()
    DispatchQueue.main.async { [weak self] in
      self?.reconnectingVolumeIDs.remove(compositeId)
      NotificationManager.shared.keepAliveForget(
        targetID: Self.notificationKey(volumeID: compositeId))
    }
  }

  /// Called when several volumes are unmounted on purpose at once (eject a
  /// whole disk, "Unmount All").
  func suppress(volumes: [Volume]) {
    let ids = volumes.compactMap(\.compositeId)
    suppressionLock.lock()
    suppressedVolumeIDs.formUnion(ids)
    suppressionLock.unlock()
    retryStateLock.lock()
    for id in ids { volumeRetries.remove(id) }
    retryStateLock.unlock()
    DispatchQueue.main.async { [weak self] in
      self?.reconnectingVolumeIDs.subtract(ids)
      for id in ids {
        NotificationManager.shared.keepAliveForget(targetID: Self.notificationKey(volumeID: id))
      }
    }
  }

  /// Lifts the suppression only (retry state untouched). Used when a user
  /// unmount that suppressed the share up front fails, so the share is still
  /// mounted and must stay protected by keep-alive.
  func unsuppress(shareID: UUID) {
    suppressionLock.lock()
    suppressedShareIDs.remove(shareID)
    suppressionLock.unlock()
  }

  /// Called when the user mounts a share again — clears any suppression and
  /// retry state so keep-alive tracking restarts cleanly. Automatic mounts
  /// must NOT call this, or the backoff never accumulates.
  func resume(shareID: UUID) {
    suppressionLock.lock()
    suppressedShareIDs.remove(shareID)
    suppressionLock.unlock()
    retryStateLock.lock()
    shareRetries.remove(shareID)
    retryStateLock.unlock()
  }

  /// Called when the user mounts a volume again — clears any suppression and
  /// retry state so keep-alive tracking restarts cleanly.
  func resume(volume: Volume) {
    guard let compositeId = volume.compositeId else { return }
    suppressionLock.lock()
    suppressedVolumeIDs.remove(compositeId)
    suppressionLock.unlock()
    retryStateLock.lock()
    volumeRetries.remove(compositeId)
    retryStateLock.unlock()
  }

  /// Runs a reconnect sweep immediately (e.g. after wake, network recovery,
  /// or a manual "Reconnect now" action).
  ///
  /// - Parameter resetBackoff: make every target due right away. Used after
  ///   wake and network recovery: failures from before (e.g. away from the
  ///   server's network) must not delay reconnecting by up to 8× the
  ///   interval now that the server may be reachable again.
  func sweepNow(resetBackoff: Bool = false) {
    DispatchQueue.main.async { [weak self] in
      if resetBackoff {
        self?.clearBackoffDelays()
      }
      self?.sweep()
    }
  }

  /// Clears every pending backoff delay. Attempt counts are kept, so a
  /// target that keeps failing backs off again from where it was.
  private func clearBackoffDelays() {
    retryStateLock.withLock {
      shareRetries.clearDelays()
      volumeRetries.clearDelays()
    }
  }

  // MARK: - Scheduling

  private func startSweepTimer() {
    sweepTimer?.invalidate()
    // Timer cadence is the configured interval; per-target backoff decides
    // whether an individual target is actually retried on a given sweep.
    let timer = Timer(timeInterval: retryInterval, repeats: true) { [weak self] _ in
      self?.sweepNow()
    }
    // Let macOS coalesce this with other wake-ups; exact timing doesn't matter.
    timer.tolerance = retryInterval * 0.1
    RunLoop.main.add(timer, forMode: .common)
    sweepTimer = timer
  }

  private func setupWakeObserver() {
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(handleWake), name: NSWorkspace.didWakeNotification, object: nil)
  }

  @objc private func handleWake(_ notification: Notification) {
    guard isEnabled, remountOnWake else { return }
    Log.keepAlive.notice("System woke from sleep. Scheduling keep-alive reconnect sweep.")
    // Give the network stack a moment to re-establish connectivity.
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
      self?.sweepNow(resetBackoff: true)
    }
  }

  // MARK: - Network Monitoring

  private func startNetworkMonitoring() {
    let monitor = NWPathMonitor()
    pathMonitor = monitor
    monitor.pathUpdateHandler = { [weak self] path in
      // NWPathMonitor calls back on its own queue; the settings, share list
      // and interface tracking used below are main-thread state.
      DispatchQueue.main.async {
        self?.handlePathUpdate(path)
      }
    }
    monitor.start(queue: pathMonitorQueue)
  }

  /// A physical (non-tunnel) network interface.
  struct InterfaceSnapshot: Equatable {
    let name: String
    let type: NWInterface.InterfaceType
  }

  /// The path's physical interfaces in path order, ignoring VPN tunnels
  /// (utun, ipsec — reported as `.other`) and loopback, whose coming and
  /// going says nothing about how the shares' server is reached.
  static func physicalInterfaces(of path: NWPath) -> [InterfaceSnapshot] {
    path.availableInterfaces
      .filter { [.wifi, .wiredEthernet, .cellular].contains($0.type) }
      .map { InterfaceSnapshot(name: $0.name, type: $0.type) }
  }

  /// Whether mounted shares should be remounted after a path update: only
  /// when the interface they were reached through is gone, or the primary
  /// physical interface changed kind (e.g. Wi-Fi → Ethernet). Changes that
  /// only add, remove or reorder tunnel/loopback interfaces never qualify.
  static func shouldRemountShares(
    previous: InterfaceSnapshot?, current: InterfaceSnapshot?, available: [InterfaceSnapshot]
  ) -> Bool {
    // First observation, or recovering from "no network": the reconnect
    // sweep handles that.
    guard let previous, let current else { return false }
    if !available.contains(where: { $0.name == previous.name }) { return true }
    return current.type != previous.type
  }

  /// Main thread only.
  private func handlePathUpdate(_ path: NWPath) {
    guard isEnabled else { return }

    if path.status == .satisfied {
      // NWPath does not document interface ordering, but in practice the
      // first entry is the primary interface the path is routed through.
      let available = Self.physicalInterfaces(of: path)
      let interface = available.first
      let interfaceChanged = Self.shouldRemountShares(
        previous: currentInterface, current: interface, available: available)
      // Back online (or on another network): earlier failures say nothing
      // about reachability now, so retry everything right away.
      let networkChanged = currentInterface == nil || interfaceChanged
      currentInterface = interface

      if interfaceChanged && remountOnNetworkChange {
        Log.keepAlive.notice(
          "Network interface changed (→ \(interface?.name ?? "?", privacy: .public)). Remounting shares."
        )
        remountSharesForInterfaceChange()
      } else {
        Log.keepAlive.notice("Network became available. Running keep-alive reconnect sweep.")
        sweepNow(resetBackoff: networkChanged)
      }
    } else {
      currentInterface = nil
      Log.keepAlive.notice("Network unavailable. Waiting for recovery before reconnecting mounts.")
    }
  }

  /// Re-establishes active share mounts through the new primary interface.
  /// Main thread only.
  private func remountSharesForInterfaceChange() {
    let shares = keepAliveShares
    guard !shares.isEmpty else { return }
    // One mount-table refresh for all shares (not one per share).
    NetworkMountManager.shared.refreshMountStatus { [weak self] in
      guard let self else { return }
      var needsSweep = false
      for share in shares {
        guard !self.isSuppressed(shareID: share.id) else { continue }
        guard NetworkMountManager.shared.isMounted(share: share) else {
          // Not mounted right now — the regular sweep will reconnect it.
          needsSweep = true
          continue
        }
        if !self.reconnectingShareIDs.contains(share.id) {
          self.reconnectingShareIDs.insert(share.id)
        }
        NetworkMountManager.shared.forceRemount(share: share) { [weak self] success in
          self?.recordResult(shareID: share.id, name: share.name, success: success)
          if success {
            Log.keepAlive.notice(
              "Remounted \(share.name, privacy: .private) through the new network interface.")
          } else {
            Log.keepAlive.error(
              "Could not remount \(share.name, privacy: .private) through the new network interface."
            )
          }
        }
      }
      if needsSweep {
        self.sweepNow(resetBackoff: true)
      }
    }
  }

  // MARK: - Target Discovery

  /// Shares that participate in keep-alive: every share explicitly marked
  /// "Keep Mounted", plus every login share (their mount should survive a
  /// drop just as much as it was wanted at login).
  var keepAliveShares: [NetworkShare] {
    guard isEnabled else { return [] }
    return PersistenceManager.shared.networkShares.filter { $0.keepMounted || $0.mountAtLogin }
  }

  /// Drops everything kept for targets that are no longer keep-alive targets
  /// (share deleted or no longer "Keep Mounted", volume's Keep Alive turned
  /// off or the drive unplugged): their retry state, their "reconnecting"
  /// flag (which would otherwise keep the menu bar badge up for good) and
  /// their notification throttle. Main thread only.
  func reconcileTargets() {
    reconcileTargets(
      validShareIDs: Set(keepAliveShares.map(\.id)),
      validVolumeIDs: presentKeepAliveVolumeIDs())
  }

  /// Internal (not private) for unit tests.
  func reconcileTargets(validShareIDs: Set<UUID>, validVolumeIDs: Set<String>) {
    let (staleShares, staleVolumes) = retryStateLock.withLock {
      (
        shareRetries.prune(keeping: validShareIDs),
        volumeRetries.prune(keeping: validVolumeIDs)
      )
    }
    let reconnectingShares = reconnectingShareIDs.subtracting(validShareIDs)
    let reconnectingVolumes = reconnectingVolumeIDs.subtracting(validVolumeIDs)
    // Only touch the published sets when something changes (see recordResult).
    if !reconnectingShares.isEmpty {
      reconnectingShareIDs.subtract(reconnectingShares)
    }
    if !reconnectingVolumes.isEmpty {
      reconnectingVolumeIDs.subtract(reconnectingVolumes)
    }
    for id in staleShares.union(reconnectingShares) {
      NotificationManager.shared.keepAliveForget(targetID: Self.notificationKey(shareID: id))
    }
    for id in staleVolumes.union(reconnectingVolumes) {
      NotificationManager.shared.keepAliveForget(targetID: Self.notificationKey(volumeID: id))
    }
  }

  /// Keep-alive volumes that are currently plugged in and not blocked: the
  /// only ones a sweep can reconnect.
  private func presentKeepAliveVolumeIDs() -> Set<String> {
    let keepAliveIDs = Set(PersistenceManager.shared.keepAliveVolumes.map(\.id))
    guard !keepAliveIDs.isEmpty, isEnabled else { return [] }
    let disks = DriveManager.shared.physicalDisks ?? []
    return Set(
      disks.flatMap(\.allVolumes).compactMap { volume -> String? in
        guard let id = volume.compositeId, keepAliveIDs.contains(id),
          !PersistenceManager.shared.isVolumeBlocked(volume)
        else { return nil }
        return id
      })
  }

  private func resetRetryState() {
    retryStateLock.withLock {
      shareRetries.removeAll()
      volumeRetries.removeAll()
    }
    DispatchQueue.main.async { [weak self] in
      self?.reconnectingShareIDs.removeAll()
      self?.reconnectingVolumeIDs.removeAll()
      NotificationManager.shared.keepAliveReset()
    }
  }

  /// Whether the user unmounted this share on purpose in this session.
  func isSuppressed(shareID: UUID) -> Bool {
    suppressionLock.withLock { suppressedShareIDs.contains(shareID) }
  }

  private func isSuppressed(volumeID: String) -> Bool {
    suppressionLock.withLock { suppressedVolumeIDs.contains(volumeID) }
  }

  // MARK: - Retry Bookkeeping

  /// Internal (not private) for unit tests.
  func recordAttempt(shareID: UUID) {
    retryStateLock.withLock {
      shareRetries.recordAttempt(shareID, backoff: backoffDelay(forAttempt:))
    }
  }

  private func recordAttempt(volumeID: String) {
    retryStateLock.withLock {
      volumeRetries.recordAttempt(volumeID, backoff: backoffDelay(forAttempt:))
    }
  }

  /// Number of consecutive failed attempts recorded for a share. For tests.
  func retryAttempt(forShareID shareID: UUID) -> Int {
    retryStateLock.withLock { shareRetries.attempt(for: shareID) }
  }

  /// When the share may next be retried (nil: right away). For tests.
  func nextRetryDate(forShareID shareID: UUID) -> Date? {
    retryStateLock.withLock { shareRetries.nextFireDate(for: shareID) }
  }

  /// Notification throttle keys: one per keep-alive target.
  static func notificationKey(shareID: UUID) -> String { "share.\(shareID.uuidString)" }
  static func notificationKey(volumeID: String) -> String { "volume.\(volumeID)" }

  /// Internal (not private) for unit tests.
  func recordResult(shareID: UUID, name: String, success: Bool) {
    // A share the user ejected in the meantime is not "reconnecting".
    let clear = success || isSuppressed(shareID: shareID)
    if clear {
      retryStateLock.withLock { shareRetries.remove(shareID) }
    }
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      // Every mutation of an @Published property re-renders its observers,
      // even when it changes nothing, and this runs for each healthy target
      // on every tick: only touch the set when membership really changes.
      let isReconnecting = self.reconnectingShareIDs.contains(shareID)
      if clear, isReconnecting {
        self.reconnectingShareIDs.remove(shareID)
      } else if !clear, !isReconnecting {
        self.reconnectingShareIDs.insert(shareID)
      }
      let key = Self.notificationKey(shareID: shareID)
      if success || !clear {
        NotificationManager.shared.keepAliveResult(targetID: key, name: name, success: success)
      } else {
        NotificationManager.shared.keepAliveForget(targetID: key)
      }
    }
  }

  /// Internal (not private) for unit tests.
  func recordResult(volumeID: String, name: String, success: Bool) {
    // A volume the user ejected in the meantime is not "reconnecting".
    let clear = success || isSuppressed(volumeID: volumeID)
    if clear {
      retryStateLock.withLock { volumeRetries.remove(volumeID) }
    }
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      // Only publish real changes (see recordResult(shareID:name:success:)).
      let isReconnecting = self.reconnectingVolumeIDs.contains(volumeID)
      if clear, isReconnecting {
        self.reconnectingVolumeIDs.remove(volumeID)
      } else if !clear, !isReconnecting {
        self.reconnectingVolumeIDs.insert(volumeID)
      }
      let key = Self.notificationKey(volumeID: volumeID)
      if success || !clear {
        NotificationManager.shared.keepAliveResult(targetID: key, name: name, success: success)
      } else {
        NotificationManager.shared.keepAliveForget(targetID: key)
      }
    }
  }

  /// Exponential backoff: base interval doubled per attempt, capped at eight
  /// times the base interval.
  func backoffDelay(forAttempt attempt: Int) -> TimeInterval {
    let multiplier = pow(2.0, Double(max(0, attempt - 1)))
    return min(retryInterval * multiplier, maxRetryInterval)
  }

  /// A target is due for a retry when it has never been attempted, or when
  /// its backoff delay has elapsed.
  private func isDueForRetry(shareID: UUID) -> Bool {
    retryStateLock.withLock { shareRetries.isDue(shareID) }
  }

  private func isDueForRetry(volumeID: String) -> Bool {
    retryStateLock.withLock { volumeRetries.isDue(volumeID) }
  }

  // MARK: - Reconnect Sweep

  /// Checks every keep-alive target and reconnects the ones that are down.
  ///
  /// Always hops to the main queue: mount completions and the published state
  /// it reads are main-thread bound, and `isSweeping` serializes sweeps.
  private func sweep() {
    guard isEnabled, !isSweeping else { return }
    // Nothing to keep alive: skip the mount table scan entirely so the
    // periodic timer costs nothing for most users.
    let hasShareTargets = !keepAliveShares.isEmpty
    guard hasShareTargets || !PersistenceManager.shared.keepAliveVolumes.isEmpty
    else { return }
    isSweeping = true
    sweepGeneration &+= 1
    let generation = sweepGeneration

    let group = DispatchGroup()
    if hasShareTargets {
      // Hold the group open until the status refresh has run and the
      // reconnect work has been queued, so `isSweeping` can't clear early
      // and let a second sweep overlap this one.
      group.enter()
      NetworkMountManager.shared.refreshMountStatus { [weak self] in
        defer { group.leave() }
        guard let self else { return }
        self.reconnectShares(group: group)
        self.reconnectVolumes(group: group)
      }
    } else {
      // Only volumes to keep alive: the network mount table isn't needed.
      reconnectVolumes(group: group)
    }

    group.notify(queue: .main) { [weak self] in
      guard let self else { return }
      // Targets that vanished while the sweep ran (drive pulled, share
      // removed) must not keep the "reconnecting" badge up.
      self.reconcileTargets()
      guard self.sweepGeneration == generation else { return }
      self.isSweeping = false
    }

    // Watchdog: never let one stuck completion block all future sweeps.
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.sweepWatchdogInterval) {
      [weak self] in
      guard let self, self.isSweeping, self.sweepGeneration == generation else { return }
      Log.keepAlive.error("Keep-alive sweep did not finish in time; allowing new sweeps.")
      self.isSweeping = false
    }
  }

  private func reconnectShares(group: DispatchGroup) {
    let shares = keepAliveShares
    guard !shares.isEmpty else { return }

    // The mounted-set snapshot was just refreshed by the sweep prologue.
    let mountedIDs = NetworkMountManager.shared.mountedShareIDs

    for share in shares {
      if mountedIDs.contains(share.id) {
        recordResult(shareID: share.id, name: share.name, success: true)
        continue
      }
      guard !isSuppressed(shareID: share.id) else { continue }
      guard isDueForRetry(shareID: share.id) else { continue }

      recordAttempt(shareID: share.id)
      group.enter()
      Log.keepAlive.notice("Attempting to remount network share \(share.name, privacy: .private).")
      // Not user-initiated: keeps the backoff state just recorded and any
      // user suppression intact.
      NetworkMountManager.shared.mount(share: share, userInitiated: false) {
        [weak self] success, error in
        self?.recordResult(shareID: share.id, name: share.name, success: success)
        if success {
          Log.keepAlive.notice("Remounted \(share.name, privacy: .private).")
        } else {
          Log.keepAlive.error(
            "Remount failed for \(share.name, privacy: .private): \(error ?? "skipped", privacy: .private)"
          )
        }
        group.leave()
      }
    }
  }

  private func reconnectVolumes(group: DispatchGroup) {
    let keepAliveVolumes = PersistenceManager.shared.keepAliveVolumes
    guard !keepAliveVolumes.isEmpty else { return }

    let disks = DriveManager.shared.physicalDisks ?? []
    let candidateVolumes = disks.flatMap(\.allVolumes).filter { volume in
      guard let compositeId = volume.compositeId else { return false }
      return keepAliveVolumes.contains { $0.id == compositeId }
        && !PersistenceManager.shared.isVolumeBlocked(volume)
    }

    for volume in candidateVolumes {
      guard let compositeId = volume.compositeId else { continue }
      if volume.isMounted {
        recordResult(volumeID: compositeId, name: volume.name, success: true)
        continue
      }
      guard !isSuppressed(volumeID: compositeId) else { continue }
      guard isDueForRetry(volumeID: compositeId) else { continue }

      recordAttempt(volumeID: compositeId)
      group.enter()
      Log.keepAlive.notice("Attempting to remount volume \(volume.name, privacy: .private).")
      // Silent mount: transient reconnect failures must not pop error dialogs.
      // The result is recorded when the mount really finishes, however long a
      // slow (spinning) drive takes.
      remount(
        volume: volume,
        mounter: { volume, completion in
          DriveManager.shared.mount(
            volume: volume, allowsErrorAlerts: false, isUserInitiated: false,
            completion: completion)
        },
        completion: { [weak self] result in
          var succeeded = false
          if case .success = result { succeeded = true }
          self?.recordResult(volumeID: compositeId, name: volume.name, success: succeeded)
          group.leave()
        })
    }
  }

  /// Runs `mounter` and reports its result once, on the main thread, when it
  /// completes. If it never completes, reports a timeout failure after
  /// `timeout` so a stuck mount cannot block the sweep. Internal (not private)
  /// for unit tests.
  func remount(
    volume: Volume,
    mounter: (Volume, @escaping (Result<Void, Error>) -> Void) -> Void,
    timeout: TimeInterval = DriveManager.mountUnmountTimeout * 2 + 20,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    let lock = NSLock()
    var finished = false
    let finish: (Result<Void, Error>) -> Void = { result in
      lock.lock()
      let isFirst = !finished
      finished = true
      lock.unlock()
      guard isFirst else { return }
      DispatchQueue.main.async { completion(result) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
      finish(.failure(MountFailure(message: "Timed out waiting for the mount to finish")))
    }
    mounter(volume, finish)
  }
}
