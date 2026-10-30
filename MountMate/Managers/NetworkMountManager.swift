//  Created by homielab.com

import AppKit
import Foundation
import NetFS

struct ShareUsage: Equatable {
  let totalBytes: Int64
  let freeBytes: Int64

  var usedBytes: Int64 { max(0, totalBytes - freeBytes) }
  var percentage: Double { min(1, Double(usedBytes) / Double(totalBytes)) }

  /// "12 GB": how the share row and the low-space warning show a size.
  static func formatted(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useGB, .useMB, .useKB, .useTB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
  }
}

class NetworkMountManager: ObservableObject, NetworkShareMounterHost {
  static let shared = NetworkMountManager()

  private(set) lazy var mounter = NetworkShareMounter(host: self)

  @Published var mountedShareIDs: Set<UUID> = []
  /// Where each saved (and manually connected) share is currently mounted,
  /// from the last status refresh. Main thread only.
  private(set) var mountPointsByShareID: [UUID: String] = [:]
  /// Total and free bytes of each mounted share, from the last status refresh.
  @Published private(set) var usageByShareID: [UUID: ShareUsage] = [:]
  @Published var manuallyConnectedShares: [NetworkShare] = []
  @Published var isUnmountingManualShares = false
  /// "Mount All Saved Shares" / "Unmount All Saved Shares" is running.
  @Published private(set) var isMountingSavedShares = false
  @Published private(set) var isUnmountingSavedShares = false

  private let shareAdoption = ShareAdoption()

  private var workspaceObservers: [NSObjectProtocol] = []
  private var mountEventDebounce: DispatchWorkItem?
  /// `refreshMountStatus` runs overlap (keep-alive, mount events, Eject
  /// All); these keep a slow older run from overwriting a newer result.
  /// Main thread only.
  private var mountStatusGate = LatestResultGate()
  private var shareUsageGate = LatestResultGate()
  /// When the last share capacity read started (`ShareUsageReadRules`).
  /// Main thread only.
  private var lastUsageReadAt: Date?
  /// Shares that read asked for, answered or not; a share drops out when it
  /// unmounts, so mounting it again reads it right away. Main thread only.
  private var usageReadShareIDs = Set<UUID>()

  private init() {
    // Initial check
    refreshMountStatus()

    // Refresh share status on mount/unmount/wake events (debounced so a burst of
    // events reads the mount table once), instead of on every disk refresh.
    let center = NSWorkspace.shared.notificationCenter
    for name in [
      NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
      NSWorkspace.didWakeNotification,
    ] {
      workspaceObservers.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          self?.scheduleMountEventRefresh()
        })
    }
  }

  private func scheduleMountEventRefresh() {
    mountEventDebounce?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.refreshMountStatus() }
    mountEventDebounce = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
  }

  /// Refreshes which shares are mounted and, when due, their capacity.
  func refreshMountStatus(completion: (() -> Void)? = nil) {
    refreshMountStatus(readUsage: true, completion: completion)
  }

  /// `readUsage: false` only reads the local mount table and never contacts
  /// a server: Keep Alive uses it so its periodic checks let a NAS sleep.
  /// With `true`, capacity is read when `ShareUsageReadRules` says it is due.
  func refreshMountStatus(readUsage: Bool, completion: (() -> Void)? = nil) {
    // Snapshot the saved shares on the main thread (PersistenceManager is
    // main-thread state); this may be called from any thread.
    DispatchQueue.main.async { [weak self] in
      guard let self = self else {
        completion?()
        return
      }
      let savedShares = PersistenceManager.shared.networkShares
      let ticket = self.mountStatusGate.begin()
      DispatchQueue.global(qos: .userInitiated).async {
        self.refreshMountStatus(
          savedShares: savedShares, ticket: ticket, readUsage: readUsage, completion: completion)
      }
    }
  }

  /// Background part of `refreshMountStatus(readUsage:completion:)`.
  /// `ticket` comes from `mountStatusGate`: a result older than the one
  /// already shown is dropped (its completion still runs; the newer state is
  /// in place).
  private func refreshMountStatus(
    savedShares: [NetworkShare], ticket: Int, readUsage: Bool, completion: (() -> Void)?
  ) {
    guard let mountedShares = MountTable.networkShares() else {
      Log.network.error("Could not read the mount table (getfsstat failed).")
      DispatchQueue.main.async { completion?() }
      return
    }
    Log.network.debug(
      "Mount table: \(mountedShares.count, privacy: .public) network share(s).")

    let parsedData = self.shareAdoption.parse(mountedShares, savedShares: savedShares)

    DispatchQueue.main.async {
      guard self.mountStatusGate.shouldApply(ticket) else {
        completion?()
        return
      }
      // Assigning an @Published property re-renders every observing view
      // even when the value is identical, and this runs on every
      // keep-alive tick: only publish actual changes.
      if self.mountedShareIDs != parsedData.mountedShareIDs {
        self.mountedShareIDs = parsedData.mountedShareIDs
      }
      self.mountPointsByShareID = parsedData.mountPoints
      if self.manuallyConnectedShares != parsedData.manualShares {
        self.manuallyConnectedShares = parsedData.manualShares
      }
      completion?()

      // Usage is read after completion so a slow server never delays
      // mounts or keep-alive sweeps.
      let now = Date()
      let mountedIDs = Set(parsedData.mountPoints.keys)
      self.usageReadShareIDs.formIntersection(mountedIDs)
      guard
        ShareUsageReadRules.shouldRead(
          requested: readUsage, mountedShareIDs: mountedIDs,
          attemptedShareIDs: self.usageReadShareIDs, lastReadAt: self.lastUsageReadAt,
          now: now)
      else { return }
      self.lastUsageReadAt = now
      self.usageReadShareIDs = mountedIDs
      let mounts = Array(parsedData.mountPoints)
      DispatchQueue.global(qos: .userInitiated).async {
        self.readShareUsage(of: mounts, ticket: ticket)
      }
    }
  }

  /// Reads the capacity of each mounted share (`statfs`) and publishes it.
  /// Shares are read in parallel: an unreachable server costs one timeout,
  /// not one per share. Background queue.
  private func readShareUsage(of mounts: [(key: UUID, value: String)], ticket: Int) {
    Log.network.debug("Reading capacity of \(mounts.count, privacy: .public) network share(s).")
    var results = [FileSystemUsage.Outcome?](repeating: nil, count: mounts.count)
    let lock = NSLock()
    DispatchQueue.concurrentPerform(iterations: mounts.count) { index in
      let result = FileSystemUsage.read(atPath: mounts[index].value)
      lock.withLock { results[index] = result }
    }

    DispatchQueue.main.async {
      guard self.shareUsageGate.shouldApply(ticket) else { return }
      var usage = [UUID: ShareUsage]()
      for (index, mount) in mounts.enumerated() {
        switch results[index] {
        case .usage(let total, let free) where total > 0:
          usage[mount.key] = ShareUsage(totalBytes: total, freeBytes: free)
        case .timedOut:
          // Keep the last known value while the server is slow to answer.
          usage[mount.key] = self.usageByShareID[mount.key]
        default:
          break
        }
      }
      if self.usageByShareID != usage {
        self.usageByShareID = usage
      }
      let names = Dictionary(
        (PersistenceManager.shared.networkShares + self.manuallyConnectedShares)
          .map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
      NotificationManager.shared.sharesRefreshed(
        usage: usage, mountedShareIDs: Set(self.mountPointsByShareID.keys), names: names)
    }
  }

  /// Returns the currently mounted network shares that are not already saved in
  /// MountMate. Refreshing first keeps the result useful when Settings has been
  /// open for a while.
  func discoverManuallyMountedShares(completion: @escaping ([NetworkShare]) -> Void) {
    refreshMountStatus { [weak self] in
      completion(self?.manuallyConnectedShares ?? [])
    }
  }

  /// Resolves a Finder URL dropped anywhere inside a mounted share back to its
  /// network share.
  func manuallyMountedShare(containing url: URL) -> NetworkShare? {
    NetworkMountTable.manualShare(
      containing: url, in: manuallyConnectedShares, mountPoints: mountPointsByShareID)
  }

  /// Mounts a saved share. Concurrent requests for the same share share one
  /// mount operation and its result; see `NetworkShareMounter`.
  ///
  /// - Parameter userInitiated: `true` when the user asked for this mount
  ///   (menu or Settings). Only such mounts clear keep-alive suppression and
  ///   retry/backoff state. Automatic mounts (login, keep-alive, network
  ///   change) pass `false`: clearing the retry state on every keep-alive
  ///   attempt would reset the backoff each time, and an automatic mount must
  ///   never undo the user's own eject.
  func mount(
    share: NetworkShare, userInitiated: Bool = true,
    completion: @escaping (Bool, String?) -> Void
  ) {
    mounter.mount(share: share, userInitiated: userInitiated, completion: completion)
  }

  /// Opens a Finder window at the share's mount point after a successful
  /// mount, when "Open in Finder after mounting" is on and `trigger` is a
  /// user request. Call on the main thread.
  func openInFinderAfterMounting(_ share: NetworkShare, trigger: MountTrigger) {
    let mountPoint = getMountPoint(for: share)
    guard
      OpenAfterMountRules.shouldOpen(
        trigger: trigger, isEnabled: OpenAfterMountRules.isEnabled(), succeeded: true,
        isBlocked: false, mountPoint: mountPoint)
    else { return }
    OpenAfterMountRules.open([mountPoint])
  }

  /// Mounts the "Mount at login" shares at launch; the failed ones are
  /// tried again after 15 s, 30 s, 1 min, 2 min, 2 min and when the network
  /// comes up (`retryLoginMounts`), while Keep Alive is off.
  private(set) lazy var loginMounts = LoginMountRetrier(
    shares: { PersistenceManager.shared.networkShares },
    isMounted: { [weak self] share in self?.isMounted(share: share) ?? false },
    isSuppressed: { KeepAliveManager.shared.isSuppressed(shareID: $0) },
    mount: { [weak self] share, completion in
      guard let self else { return completion(false, nil) }
      // Automatic: must not clear keep-alive suppression or backoff state.
      // The error is already sanitized by mount().
      self.mount(share: share, userInitiated: false, completion: completion)
    },
    schedule: { delay, block in
      let work = DispatchWorkItem(block: block)
      DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
      return { work.cancel() }
    },
    retryWhenDue: { [weak self] in
      // Keep Alive on: its reconnect sweep already retries login shares;
      // turning it off calls retryLoginMounts(), which restarts the timer.
      guard !KeepAliveManager.shared.isEnabled else { return }
      self?.retryLoginMounts()
    },
    onGiveUp: { share, error in
      NotificationManager.shared.loginMountFailed(shareID: share.id, name: share.name, error: error)
    })

  /// Main thread only.
  func mountAllAutoShares() {
    loginMounts.mountAtLaunch()
  }

  /// The network became available while Keep Alive is off, or the login
  /// retry timer fired: mounts the "Mount at login" shares that failed at
  /// launch (`LoginMountRules`).
  /// Main thread only.
  func retryLoginMounts() {
    guard loginMounts.hasPendingShares else { return }
    // Read the mount table first: the share may have been mounted elsewhere.
    refreshMountStatus(readUsage: false) { [weak self] in
      self?.loginMounts.retry()
    }
  }

  /// Unmounts and immediately mounts a share again so the connection is
  /// re-established over the current network path. Used after network
  /// interface changes when the stale mount still exists. `completion`
  /// receives whether the share ended up mounted.
  func forceRemount(share: NetworkShare, completion: ((Bool) -> Void)? = nil) {
    let lastKnownMountPoint = mountPointsByShareID[share.id]
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      // Unmount where the share really is, never just the configured path:
      // that folder may hold a different share with the same name.
      if let mountPoint = self.liveMountPoint(for: share, lastKnown: lastKnownMountPoint) {
        // Only remount mounts MountMate made (at the share's own folder).
        // A mount elsewhere, e.g. the user's own Finder mount in /Volumes,
        // is left alone: it is mounted, which is all keep-alive needs.
        guard NetworkMountTable.samePath(mountPoint, self.configuredMountPoint(for: share)) else {
          DispatchQueue.main.async { completion?(true) }
          return
        }
        let umountResult = runProcess(executable: "/sbin/umount", arguments: [mountPoint])
        if !umountResult.succeeded {
          Log.network.notice(
            "Unmount before remounting \(share.name, privacy: .private) failed (\(umountResult.timedOut ? "timed out" : "exit \(umountResult.exitCode ?? -1)", privacy: .public)): \(umountResult.stderr, privacy: .private)"
          )
          let stillMounted =
            self.currentMountTable().map { !self.mounts(of: share, in: $0).isEmpty } ?? true
          if !Self.shouldRemount(afterUnmountSucceeded: false, stillMounted: stillMounted) {
            // Busy share: it is still mounted, so there is nothing to
            // reconnect and a second mount would only fail.
            DispatchQueue.main.async { completion?(true) }
            return
          }
        }
      }
      DispatchQueue.main.async {
        // Automatic: must not clear keep-alive suppression or backoff state.
        self.mount(share: share, userInitiated: false) { success, _ in
          completion?(success)
        }
      }
    }
  }

  /// Whether `forceRemount` should mount again: always after a successful
  /// unmount, and after a failed one only when the share is gone anyway.
  static func shouldRemount(afterUnmountSucceeded: Bool, stillMounted: Bool) -> Bool {
    afterUnmountSucceeded || !stillMounted
  }

  /// Marks a share as intentionally unmounted by the user so the keep-alive
  /// layer does not fight that decision. Cleared on the next explicit mount.
  func markShareUnmountedByUser(_ share: NetworkShare) {
    KeepAliveManager.shared.suppress(shareID: share.id)
  }

  func unmount(share: NetworkShare, completion: @escaping (Bool, String?) -> Void) {
    attemptUnmount(share: share, force: false) { failure in
      completion(failure == nil, failure?.message)
    }
  }

  /// `umount -f`: only after the user confirmed it (busy share, dead server).
  func forceUnmount(share: NetworkShare, completion: @escaping (Bool, String?) -> Void) {
    attemptUnmount(share: share, force: true) { failure in
      completion(failure == nil, failure?.message)
    }
  }

  /// Unmounts a share; `completion(nil)` on success, else the translated
  /// failure (with `canForce`) so the caller can offer a Force Unmount.
  func attemptUnmount(
    share: NetworkShare, force: Bool,
    completion: @escaping (NetworkMountPlan.UnmountFailure?) -> Void
  ) {
    let lastKnownMountPoint = mountPointsByShareID[share.id]

    // Suppress keep-alive BEFORE unmounting: otherwise a sweep running in the
    // window between umount finishing and the suppression could remount the
    // share the user just ejected. Undone below if the unmount fails.
    let wasSuppressed = KeepAliveManager.shared.isSuppressed(shareID: share.id)
    markShareUnmountedByUser(share)

    DispatchQueue.global(qos: .userInitiated).async {
      // Unmount where the share really is (from a fresh mount table), never
      // just the configured path: that folder may hold a different share.
      guard let mountPoint = self.liveMountPoint(for: share, lastKnown: lastKnownMountPoint)
      else {
        // Not mounted any more (e.g. ejected in Finder): nothing to do.
        DispatchQueue.main.async {
          self.refreshMountStatus { completion(nil) }
        }
        return
      }

      let result = runProcess(
        executable: "/sbin/umount", arguments: (force ? ["-f"] : []) + [mountPoint])

      DispatchQueue.main.async {
        if !result.succeeded {
          if !wasSuppressed {
            KeepAliveManager.shared.unsuppress(shareID: share.id)
          }
          let failure = NetworkMountPlan.unmountFailure(for: result, shareName: share.name)
          self.refreshMountStatus {
            completion(failure)
          }
        } else {
          self.refreshMountStatus {
            completion(nil)
          }
        }
      }
    }
  }

  /// A share to unmount at a known mount point (from the mount table).
  struct ShareUnmountTarget: Equatable, Sendable {
    let name: String
    let mountPoint: String
    /// The saved share, so a failed unmount can undo its keep-alive
    /// suppression; nil for manually connected shares.
    var shareID: UUID? = nil
  }

  /// A share that could not be unmounted, with the translated reason and
  /// whether `umount -f` is worth offering.
  struct ShareUnmountFailure: Equatable {
    let target: ShareUnmountTarget
    let failure: NetworkMountPlan.UnmountFailure
  }

  /// Unmounts every target in parallel, so one share on a hung server does
  /// not hold up the others, and returns the ones that failed in the original
  /// order. Blocks until all are done; call off the main thread. `umount` is
  /// injectable for tests.
  static func unmountShares(
    _ targets: [ShareUnmountTarget], force: Bool,
    umount: (ShareUnmountTarget, Bool) -> ProcessResult = { target, force in
      runProcess(
        executable: "/sbin/umount", arguments: (force ? ["-f"] : []) + [target.mountPoint])
    }
  ) -> [ShareUnmountFailure] {
    let results = BulkVolumeActions.mapConcurrently(targets) { umount($0, force) }
    return zip(targets, results).compactMap { target, result in
      guard !result.succeeded else { return nil }
      return ShareUnmountFailure(
        target: target,
        failure: NetworkMountPlan.unmountFailure(for: result, shareName: target.name))
    }
  }

  func unmountAllManuallyConnectedShares(
    completion: @escaping ([ShareUnmountFailure]) -> Void
  ) {
    // Manually connected shares are unmounted where the mount table says they
    // are (read on the main thread, before going to the background). No
    // fallback to a configured path: that could hit a saved share's folder.
    let targets = manuallyConnectedShares.compactMap { share -> ShareUnmountTarget? in
      guard let mountPoint = mountPointsByShareID[share.id] else { return nil }
      return ShareUnmountTarget(name: share.name, mountPoint: mountPoint)
    }
    unmountManualShares(targets, force: false, completion: completion)
  }

  /// `umount -f` for manually connected shares that failed to unmount: only
  /// after the user confirmed it.
  func forceUnmountManualShares(
    _ targets: [ShareUnmountTarget], completion: @escaping ([ShareUnmountFailure]) -> Void
  ) {
    unmountManualShares(targets, force: true, completion: completion)
  }

  private func unmountManualShares(
    _ targets: [ShareUnmountTarget], force: Bool,
    completion: @escaping ([ShareUnmountFailure]) -> Void
  ) {
    guard !targets.isEmpty else {
      completion([])
      return
    }
    isUnmountingManualShares = true
    DispatchQueue.global(qos: .userInitiated).async {
      let failures = Self.unmountShares(targets, force: force)
      DispatchQueue.main.async {
        self.isUnmountingManualShares = false
        self.refreshMountStatus()
        completion(failures)
      }
    }
  }

  /// A saved share that could not be mounted, with the (sanitized) error.
  struct ShareMountFailure: Equatable {
    let name: String
    let reason: String?
  }

  /// What "Mount All Saved Shares" and "Unmount All Saved Shares" act on now.
  /// Main thread.
  var savedShareCandidates: SavedShareBulkRules.Candidates {
    SavedShareBulkRules.candidates(
      shares: PersistenceManager.shared.networkShares, mountedIDs: mountedShareIDs)
  }

  /// Mounts every saved share that is not mounted, all at once (each through
  /// `mount(share:userInitiated:true)`, so it clears keep-alive suppression
  /// like a click on its row), and reports the ones that failed in their
  /// saved order. Main thread.
  func mountAllShares(
    trigger: MountTrigger, completion: @escaping ([ShareMountFailure]) -> Void
  ) {
    let shares = savedShareCandidates.mount
    guard !shares.isEmpty, !isMountingSavedShares else {
      completion([])
      return
    }
    isMountingSavedShares = true
    var failures = [UUID: ShareMountFailure]()
    let group = DispatchGroup()
    for share in shares {
      group.enter()
      mount(share: share, userInitiated: true) { success, error in
        DispatchQueue.main.async {
          if success {
            self.openInFinderAfterMounting(share, trigger: trigger)
          } else {
            failures[share.id] = ShareMountFailure(name: share.name, reason: error)
          }
          group.leave()
        }
      }
    }
    group.notify(queue: .main) {
      self.isMountingSavedShares = false
      completion(shares.compactMap { failures[$0.id] })
    }
  }

  /// Unmounts every mounted saved share in parallel and reports the ones that
  /// failed, with their reasons. Main thread.
  func unmountAllShares(completion: @escaping ([ShareUnmountFailure]) -> Void) {
    unmountSavedShares(savedShareCandidates.unmount, force: false, completion: completion)
  }

  /// `umount -f` for saved shares that failed to unmount: only after the
  /// user confirmed it.
  func forceUnmountSavedShares(
    withIDs ids: Set<UUID>, completion: @escaping ([ShareUnmountFailure]) -> Void
  ) {
    let shares = PersistenceManager.shared.networkShares.filter { ids.contains($0.id) }
    unmountSavedShares(shares, force: true, completion: completion)
  }

  private func unmountSavedShares(
    _ shares: [NetworkShare], force: Bool,
    completion: @escaping ([ShareUnmountFailure]) -> Void
  ) {
    guard !shares.isEmpty, !isUnmountingSavedShares else {
      completion([])
      return
    }
    isUnmountingSavedShares = true
    // Suppress keep-alive before unmounting (see `attemptUnmount`); undone
    // below for the shares that stay mounted.
    let wasSuppressed = Set(
      shares.map(\.id).filter { KeepAliveManager.shared.isSuppressed(shareID: $0) })
    for share in shares { markShareUnmountedByUser(share) }
    let lastKnown = mountPointsByShareID

    DispatchQueue.global(qos: .userInitiated).async {
      // Unmount where each share really is; one that is gone already counts
      // as unmounted.
      let targets = shares.compactMap { share -> ShareUnmountTarget? in
        guard let mountPoint = self.liveMountPoint(for: share, lastKnown: lastKnown[share.id])
        else { return nil }
        return ShareUnmountTarget(name: share.name, mountPoint: mountPoint, shareID: share.id)
      }
      let failures = Self.unmountShares(targets, force: force)
      DispatchQueue.main.async {
        for id in failures.compactMap(\.target.shareID) where !wasSuppressed.contains(id) {
          KeepAliveManager.shared.unsuppress(shareID: id)
        }
        self.refreshMountStatus {
          self.isUnmountingSavedShares = false
          completion(failures)
        }
      }
    }
  }

  func isMounted(share: NetworkShare) -> Bool {
    return mountedShareIDs.contains(share.id)
  }

  /// Where the share is (or will be) mounted. Uses the cached mount table from
  /// the last status refresh so it is safe to call from UI code.
  func getMountPoint(for share: NetworkShare) -> String {
    if let mountedPath = mountPointsByShareID[share.id] {
      return mountedPath
    }

    return configuredMountPoint(for: share)
  }

  /// Where MountMate mounts the share: its custom mount point, or
  /// `~/mountmate/<name>`. Also used by the share editor to detect two saved
  /// shares that would use the same folder.
  func configuredMountPoint(for share: NetworkShare) -> String {
    NetworkMountTable.configuredMountPoint(
      for: share, homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
  }

  /// Network mounts in the kernel mount table, or nil if it could not be
  /// read. This never touches the mount points themselves, so it cannot hang
  /// on an unresponsive server.
  func currentMountTable() -> [MountedNetworkShare]? {
    MountTable.networkShares()
  }

  /// The mounts in `mountTable` that are `share` (see `ShareAdoption`).
  func mounts(of share: NetworkShare, in mountTable: [MountedNetworkShare])
    -> [MountedNetworkShare]
  {
    shareAdoption.mounts(of: share, in: mountTable)
  }

  /// Forgets any adopted mount for a share (call when it is edited or removed).
  func forgetAdoption(forShareID shareID: UUID) {
    shareAdoption.forget(shareID: shareID)
  }

  func adopt(_ mountPoint: String, for share: NetworkShare) {
    Log.network.info(
      "Share \(share.name, privacy: .private) is already mounted at \(mountPoint, privacy: .private) under another server name."
    )
    shareAdoption.adopt(mountPoint, for: share)
  }

  /// Where `share` is mounted right now according to a fresh mount table, or
  /// nil if it is not mounted. Prefers `lastKnown` (from the last refresh)
  /// when the share is still mounted there. If the mount table cannot be
  /// read, falls back to `lastKnown`, then the configured mount point.
  /// Blocking; must not run on the main thread.
  private func liveMountPoint(for share: NetworkShare, lastKnown: String?) -> String? {
    guard let mountTable = currentMountTable() else {
      return lastKnown ?? configuredMountPoint(for: share)
    }
    return NetworkMountTable.liveMountPoint(
      of: mounts(of: share, in: mountTable), lastKnown: lastKnown)
  }
}
