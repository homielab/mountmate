//  Created by homielab.com

import AppKit
import Combine
import Foundation

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
///   reconnect sweep starts immediately. With Keep Alive off, the network
///   coming up only retries the failed login mounts (`LoginMountRules`)
/// - System wake (`NSWorkspace.didWakeNotification`): prompt reconnect sweep
/// - App launch / login: initial sweep
///
/// The manager never fights the user: volumes and shares unmounted explicitly
/// through MountMate are suppressed until the user mounts them again.
///
/// Network changes: `KeepAliveManager+Network.swift` (decisions in
/// `NetworkChangeRules`); the sweep: `KeepAliveManager+Sweep.swift`.
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
        // Nothing may run after the sweep in flight once Keep Alive is off.
        sweepPending = false
        pendingSweepResetsBackoff = false
        resetRetryState()
        // Login shares the sweep was retrying go back to their own retries,
        // whose timer skipped its turns while Keep Alive was on.
        retryLoginMounts()
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
  private let networkMonitor: NetworkChangeMonitoring
  /// Replaces the share remount on an interface change (tests).
  let interfaceChangeAction: (() -> Void)?
  /// Replaces the reconnect sweep itself (tests).
  let sweepAction: (() -> Void)?
  /// Replaces the login mount retry while Keep Alive is off (tests).
  let loginMountRetryAction: (() -> Void)?
  private var cancellables = Set<AnyCancellable>()
  /// Main thread only.
  var isSweeping = false
  /// Incremented for every sweep so a late completion (or the watchdog) of
  /// an older sweep never resets `isSweeping` for a newer one. Main only.
  var sweepGeneration = 0
  /// A sweep was asked for while one was running (network back, wake,
  /// "Reconnect Now"): run exactly one more as soon as it finishes, so the
  /// request isn't lost behind a sweep stuck on an offline server. Main only.
  var sweepPending = false
  /// The pending sweep must clear backoff delays first (failures recorded by
  /// the running sweep predate the request). Main only.
  var pendingSweepResetsBackoff = false
  /// Upper bound for one sweep. Mounts have their own timeouts, but if some
  /// completion still never arrives, `isSweeping` must not stay stuck (which
  /// would silently disable keep-alive for the rest of the session).
  static let sweepWatchdogInterval: TimeInterval = 180

  /// The non-tunnel interface network paths were last routed through.
  /// Main thread only.
  var currentInterface: InterfaceSnapshot?

  /// Tests inject a fake `networkMonitor`, an `interfaceChangeAction`, a
  /// `sweepAction` and a `loginMountRetryAction`.
  init(
    networkMonitor: NetworkChangeMonitoring = NetworkChangeMonitor(),
    interfaceChangeAction: (() -> Void)? = nil,
    sweepAction: (() -> Void)? = nil,
    loginMountRetryAction: (() -> Void)? = nil
  ) {
    self.networkMonitor = networkMonitor
    self.interfaceChangeAction = interfaceChangeAction
    self.sweepAction = sweepAction
    self.loginMountRetryAction = loginMountRetryAction

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
    networkMonitor.onChange = { [weak self] path in self?.handleNetworkChange(path) }
    networkMonitor.start()
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
    networkMonitor.stop()
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

  /// Volumes of `volumes` the user has already suppressed. Take this before
  /// `suppress(...)` so a failed unmount only lifts what it added.
  func suppressedVolumes(among volumes: [Volume]) -> [Volume] {
    suppressionLock.withLock {
      volumes.filter { $0.compositeId.map(suppressedVolumeIDs.contains) ?? false }
    }
  }

  /// Lifts the suppression a failed unmount/eject added up front, so the
  /// volumes (still mounted) stay protected by keep-alive. Volumes in
  /// `keeping` were suppressed before the action and stay suppressed.
  func unsuppress(volumes: [Volume], keeping: [Volume] = []) {
    let kept = Set(keeping.compactMap(\.compositeId))
    let ids = volumes.compactMap(\.compositeId).filter { !kept.contains($0) }
    suppressionLock.withLock { suppressedVolumeIDs.subtract(ids) }
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

  /// Resumes the volume only for a mount the user asked for. Automatic mounts
  /// (keep-alive sweep, mount again on wake) must NOT reset the backoff, or a
  /// broken volume would be retried at the base interval forever.
  func resumeIfUserInitiated(volume: Volume, isUserInitiated: Bool) {
    guard isUserInitiated else { return }
    resume(volume: volume)
  }

  /// Runs a reconnect sweep immediately (e.g. after wake, network recovery,
  /// or a manual "Reconnect now" action).
  ///
  /// - Parameter resetBackoff: make every target due right away. Used after
  ///   wake and network recovery: failures from before (e.g. away from the
  ///   server's network) must not delay reconnecting by up to 8× the
  ///   interval now that the server may be reachable again.
  ///
  /// While a sweep is running the request is queued: one more sweep runs as
  /// soon as it finishes, however many requests arrived meanwhile.
  func sweepNow(resetBackoff: Bool = false) {
    DispatchQueue.main.async { [weak self] in
      guard let self, self.isEnabled else { return }
      if resetBackoff {
        // Right away too, so "Retrying in …" goes away at once.
        self.clearBackoffDelays()
      }
      if self.isSweeping {
        self.sweepPending = true
        self.pendingSweepResetsBackoff = self.pendingSweepResetsBackoff || resetBackoff
        return
      }
      self.runSweep()
    }
  }

  /// Runs the sweep queued while the previous one was running. Main only.
  func runPendingSweep() {
    guard sweepPending else { return }
    let resetBackoff = pendingSweepResetsBackoff
    sweepPending = false
    pendingSweepResetsBackoff = false
    guard isEnabled else { return }
    if resetBackoff {
      clearBackoffDelays()
    }
    runSweep()
  }

  private func runSweep() {
    if let sweepAction {
      sweepAction()
    } else {
      sweep()
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

  /// Main thread only.
  func markReconnecting(shareID: UUID) {
    if !reconnectingShareIDs.contains(shareID) {
      reconnectingShareIDs.insert(shareID)
    }
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

  func isSuppressed(volumeID: String) -> Bool {
    suppressionLock.withLock { suppressedVolumeIDs.contains(volumeID) }
  }

  // MARK: - Retry Bookkeeping

  /// Internal (not private) for unit tests.
  func recordAttempt(shareID: UUID) {
    retryStateLock.withLock {
      shareRetries.recordAttempt(shareID, backoff: backoffDelay(forAttempt:))
    }
  }

  /// Internal (not private) for unit tests.
  func recordAttempt(volumeID: String) {
    retryStateLock.withLock {
      volumeRetries.recordAttempt(volumeID, backoff: backoffDelay(forAttempt:))
    }
  }

  /// Number of consecutive failed attempts recorded for a share. For tests.
  func retryAttempt(forShareID shareID: UUID) -> Int {
    retryStateLock.withLock { shareRetries.attempt(for: shareID) }
  }

  /// Number of consecutive failed attempts recorded for a volume. For tests.
  func retryAttempt(forVolumeID volumeID: String) -> Int {
    retryStateLock.withLock { volumeRetries.attempt(for: volumeID) }
  }

  /// When the share may next be retried (nil: right away).
  func nextRetryDate(forShareID shareID: UUID) -> Date? {
    retryStateLock.withLock { shareRetries.nextFireDate(for: shareID) }
  }

  /// When the volume may next be retried (nil: right away).
  func nextRetryDate(forVolumeID volumeID: String) -> Date? {
    retryStateLock.withLock { volumeRetries.nextFireDate(for: volumeID) }
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
  func isDueForRetry(shareID: UUID) -> Bool {
    retryStateLock.withLock { shareRetries.isDue(shareID) }
  }

  func isDueForRetry(volumeID: String) -> Bool {
    retryStateLock.withLock { volumeRetries.isDue(volumeID) }
  }
}
