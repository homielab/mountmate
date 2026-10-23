//  Created by homielab.com

import Combine
import DiskArbitration
import Foundation
import SwiftUI

class DriveManager: ObservableObject {
  static let shared = DriveManager()

  @Published var physicalDisks: [PhysicalDisk]? = nil
  @Published var isRefreshing = false
  @Published var userActionError: AppAlert? = nil
  @Published var refreshError: String? = nil
  /// Volumes (by `Volume.id`) with a mount, unmount or unlock in flight. Each
  /// operation inserts its own ID and removes it in its own completion, so
  /// concurrent operations and unrelated refreshes never clear each other.
  @Published private(set) var busyVolumeIDs: Set<String> = []
  /// Disks (by `PhysicalDisk.id`) with an eject in flight.
  @Published private(set) var busyEjectingDiskIDs: Set<String> = []
  @Published private(set) var isUnmountingAll = false
  /// Whole disks whose `diskutil info` failed during the last refresh and
  /// that have no earlier classification cached. They are listed but never
  /// treated as removable (no eject, Unmount All, Mount All or sleep unmount)
  /// until a later refresh confirms what they are.
  @Published private(set) var unverifiedDiskIDs: Set<String> = []

  /// Source-compatible accessors for views written for a single busy item.
  /// Prefer `isBusy(_:)` / `isEjecting(_:)`, which are correct when several
  /// operations run at once.
  var busyVolumeIdentifier: String? { busyVolumeIDs.first }
  var busyEjectingIdentifier: String? { busyEjectingDiskIDs.first }

  func isBusy(_ volumeID: String) -> Bool { busyVolumeIDs.contains(volumeID) }
  func isEjecting(_ diskID: String) -> Bool { busyEjectingDiskIDs.contains(diskID) }

  let driveExpansionSubject = PassthroughSubject<Bool, Never>()

  private var refreshDebounceTimer: Timer?
  private var isFetchInProgress = false
  private var needsFollowupRefresh = false
  /// Callbacks waiting for the fetch in progress to finish (success or failure).
  private var refreshCompletions: [() -> Void] = []
  /// Callbacks requested while a fetch was in progress; they wait for the
  /// follow-up fetch so they observe state newer than their request.
  private var followupRefreshCompletions: [() -> Void] = []

  private var refreshRetryCount = 0
  private let maxRefreshRetries = 1

  /// See handleRefreshFailure; reset by every successful refresh.
  private var hasRunFollowupAfterFailure = false

  /// Number of "Unmount All" runs in flight (user click and sleep can overlap).
  private var unmountAllRunCount = 0

  /// diskutil mount/unmount can take well over 15 seconds while a sleeping
  /// USB hard drive spins up.
  private static let mountUnmountTimeout: TimeInterval = 30

  /// Last successful `diskutil info` of each whole disk, keyed by BSD name.
  /// Reused when a later `diskutil info` fails or times out (busy or
  /// spinning-up disk) so a disk is never re-classified (e.g. an internal
  /// disk shown as removable) just because its info was briefly unavailable.
  private var wholeDiskInfoCache: [String: CachedDiskInfo] = [:]
  private let wholeDiskInfoCacheLock = NSLock()
  private struct CachedDiskInfo {
    let info: [String: Any]
    /// Identity of the disk in `diskutil list` when cached (see
    /// `listIdentity(of:)`); a mismatch means the BSD name now belongs to a
    /// different disk.
    let identity: String
  }

  /// Size, content type and partition layout of a whole disk as reported by
  /// `diskutil list`. Cheap to compute and stable across refreshes; renaming
  /// a volume does not change it.
  private static func listIdentity(of diskData: [String: Any]) -> String {
    let size = (diskData["Size"] as? Int64).map(String.init) ?? "?"
    let content = diskData["Content"] as? String ?? ""
    let partitions = (diskData["Partitions"] as? [[String: Any]] ?? []).map {
      "\($0["Content"] as? String ?? ""):\(($0["Size"] as? Int64).map(String.init) ?? "?")"
    }
    return "\(size)|\(content)|\(partitions.joined(separator: ","))"
  }

  /// Set when a refresh found a volume whose statfs timed out; cleared by
  /// the next refresh without timeouts. Allows a single automatic follow-up
  /// refresh, so a permanently hung volume cannot cause a refresh loop.
  private var hasScheduledUsageRetry = false

  /// When each volume (by `Volume.id`) first appeared in the list. Used to
  /// tell a mount racing a just-attached disk from a genuine failure.
  private var volumeFirstSeen: [String: Date] = [:]
  private let volumeFirstSeenLock = NSLock()

  private init() {
    setupDiskChangeObservers()
    refreshDrives()
  }

  deinit {
    NSWorkspace.shared.notificationCenter.removeObserver(self)
    refreshDebounceTimer?.invalidate()
  }

  // MARK: - Busy State

  /// Main thread only (hops over otherwise). Calls made from one thread keep
  /// their order, so a start always lands before its own completion.
  private func setBusy(_ volumeID: String, _ busy: Bool) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { self.setBusy(volumeID, busy) }
      return
    }
    if busy {
      busyVolumeIDs.insert(volumeID)
    } else {
      busyVolumeIDs.remove(volumeID)
    }
  }

  private func setEjecting(_ diskID: String, _ busy: Bool) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { self.setEjecting(diskID, busy) }
      return
    }
    if busy {
      busyEjectingDiskIDs.insert(diskID)
    } else {
      busyEjectingDiskIDs.remove(diskID)
    }
  }

  // MARK: - Public Actions

  /// - Parameter completion: Called on the main thread once a refresh that
  ///   started after this call has finished, successfully or not. Operations
  ///   use it to keep their spinner until the list shows the new state.
  func refreshDrives(
    qos: DispatchQoS.QoSClass = .background, then completion: (() -> Void)? = nil
  ) {
    // The in-progress flags are only touched on the main thread; callers on
    // background queues (keep-alive, mount completions) hop over first.
    guard Thread.isMainThread else {
      DispatchQueue.main.async { self.refreshDrives(qos: qos, then: completion) }
      return
    }
    if isFetchInProgress {
      needsFollowupRefresh = true
      if let completion { followupRefreshCompletions.append(completion) }
      return
    }
    isFetchInProgress = true
    if let completion { refreshCompletions.append(completion) }

    if physicalDisks != nil {
      isRefreshing = true
    }

    // PersistenceManager's lists are mutated on the main thread; parsing runs
    // on a background queue, so it gets an immutable copy.
    let filters = VolumeFilterSnapshot(
      ignoredIDs: Set(PersistenceManager.shared.ignoredVolumes.map(\.id)),
      protectedIDs: Set(PersistenceManager.shared.protectedVolumes.map(\.id)))

    DispatchQueue.global(qos: qos).async { [weak self] in
      guard let self = self else { return }

      // #if DEBUG
      // let (output, error) = self.loadMockData()
      // #else
      let listResult = runProcess(executable: "/usr/sbin/diskutil", arguments: ["list", "-plist"])
      // #endif

      guard listResult.succeeded else {
        let errMsg = listResult.timedOut ? "diskutil timed out." : listResult.stderr
        self.handleRefreshFailure(error: errMsg)
        return
      }

      guard let allDisksData = listResult.stdout.data(using: .utf8), !listResult.stdout.isEmpty
      else {
        self.updateState(with: [], unverifiedDiskIDs: [])
        return
      }

      do {
        if let plist = try PropertyListSerialization.propertyList(
          from: allDisksData, options: [], format: nil) as? [String: Any]
        {
          let parsed = self.parseDisks(from: plist, filters: filters)
          self.updateState(
            with: parsed.disks, unverifiedDiskIDs: parsed.unverifiedDiskIDs,
            usageTimedOut: filters.usage.timedOut)
        } else {
          self.handleRefreshFailure(error: "diskutil returned an unexpected property list.")
        }
      } catch {
        self.handleRefreshFailure(error: error.localizedDescription)
      }
    }
  }

  private func updateState(
    with disks: [PhysicalDisk], unverifiedDiskIDs: Set<String>, usageTimedOut: Bool = false
  ) {
    DispatchQueue.main.async {
      self.refreshRetryCount = 0
      self.hasRunFollowupAfterFailure = false
      // Publishing re-renders the whole list; skip it when nothing changed
      // (most refreshes after mount/unmount notifications or popover opens).
      if self.physicalDisks != disks {
        self.physicalDisks = disks
      }
      if self.unverifiedDiskIDs != unverifiedDiskIDs {
        self.unverifiedDiskIDs = unverifiedDiskIDs
      }
      self.recordFirstSeen(of: disks)
      self.isFetchInProgress = false
      self.isRefreshing = false
      self.refreshError = nil

      // A disk spinning up can make statfs time out ("Could not read storage
      // details."); look again shortly, once.
      if !usageTimedOut {
        self.hasScheduledUsageRetry = false
      } else if !self.hasScheduledUsageRetry {
        self.hasScheduledUsageRetry = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
          self.refreshDrives(qos: .utility)
        }
      }

      let finished = self.refreshCompletions
      self.refreshCompletions = []
      if self.needsFollowupRefresh {
        self.needsFollowupRefresh = false
        self.refreshCompletions = self.followupRefreshCompletions
        self.followupRefreshCompletions = []
        self.refreshDrives(qos: .userInitiated)
      }
      finished.forEach { $0() }
    }
  }

  private func recordFirstSeen(of disks: [PhysicalDisk]) {
    let now = Date()
    let ids = Set(disks.flatMap(\.allVolumes).map(\.id))
    volumeFirstSeenLock.withLock {
      volumeFirstSeen = volumeFirstSeen.filter { ids.contains($0.key) }
      for id in ids where volumeFirstSeen[id] == nil {
        volumeFirstSeen[id] = now
      }
    }
  }

  private func handleRefreshFailure(error: String) {
    DispatchQueue.main.async {
      self.isFetchInProgress = false
      self.isRefreshing = false

      // Release everyone waiting on this refresh (their spinners).
      let finished = self.refreshCompletions + self.followupRefreshCompletions
      self.refreshCompletions = []
      self.followupRefreshCompletions = []
      // A refresh requested during the failed fetch is still owed. The retry
      // below serves it; after the final failure it runs once (and not again
      // until a refresh succeeds), so failures cannot loop.
      let hadPendingFollowup = self.needsFollowupRefresh
      self.needsFollowupRefresh = false

      if self.refreshRetryCount < self.maxRefreshRetries {
        self.refreshRetryCount += 1
        let retryDelay = 5.0
        print(
          "❗️ Refresh failed (\(error)), will retry in \(retryDelay) seconds... (Attempt \(self.refreshRetryCount))"
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) {
          self.refreshDrives()
        }
      } else {
        print("❌ Refresh failed after \(self.maxRefreshRetries) retries. Showing error to user.")
        // Start over: a later one-off failure gets its retry again instead of
        // wiping the list immediately.
        self.refreshRetryCount = 0
        self.physicalDisks = []
        self.unverifiedDiskIDs = []

        let message = NSLocalizedString(
          "MountMate could not get disk information. The system may be busy, a disk may be unresponsive, or permissions may be incorrect.",
          comment: "Final refresh error message")
        self.refreshError = message

        if hadPendingFollowup && !self.hasRunFollowupAfterFailure {
          self.hasRunFollowupAfterFailure = true
          self.refreshDrives(qos: .userInitiated)
        }
      }
      finished.forEach { $0() }
    }
  }

  private func loadMockData() -> (output: String?, error: String?) {
    guard let url = Bundle.main.url(forResource: "testDisks", withExtension: "plist") else {
      print("⚠️ MOCK DATA ERROR: testDisks.plist not found in the app bundle.")
      return (nil, "testDisks.plist not found")
    }
    do {
      let output = try String(contentsOf: url)
      return (output, nil)
    } catch {
      print("❌ MOCK DATA ERROR: Could not read content from testDisks.plist. Error: \(error)")
      return (nil, error.localizedDescription)
    }
  }

  /// Removable disks the bulk actions ("Unmount All", "Mount All",
  /// unmount-on-sleep) act on. Disks whose type could not be confirmed this
  /// refresh are left alone.
  var bulkActionDisks: [PhysicalDisk] {
    (physicalDisks ?? []).filter { $0.isRemovable && !unverifiedDiskIDs.contains($0.id) }
  }

  /// The volumes "Unmount All" would unmount right now.
  var unmountAllCandidates: [Volume] {
    bulkActionDisks
      .flatMap(\.allVolumes)
      .filter { $0.isMounted && $0.category == .user && !$0.isProtected }
  }

  /// - Parameter suppressReconnect: `false` when the unmount is not a user
  ///   decision (e.g. the unmount-all-on-sleep action) so that keep-alive
  ///   targets are reconnected on the next wake or sweep.
  /// - Parameter reportFailures: show an alert naming volumes that could not
  ///   be unmounted. Off for automatic actions nobody is watching (sleep).
  /// - Parameter completion: Called on the main thread once every unmount
  ///   has finished (immediately when there is nothing to unmount). Call on
  ///   the main thread.
  func unmountAllDrives(
    suppressReconnect: Bool = true, reportFailures: Bool = true,
    completion: (() -> Void)? = nil
  ) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async {
        self.unmountAllDrives(
          suppressReconnect: suppressReconnect, reportFailures: reportFailures,
          completion: completion)
      }
      return
    }
    let drivesToUnmount = unmountAllCandidates

    guard !drivesToUnmount.isEmpty else {
      completion?()
      return
    }
    if suppressReconnect {
      KeepAliveManager.shared.suppress(volumes: drivesToUnmount)
    }
    unmountAllRunCount += 1
    isUnmountingAll = true

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let failures = Self.runConcurrently(drivesToUnmount) { volume in
        runProcess(
          executable: "/usr/sbin/diskutil", arguments: ["unmount", volume.deviceIdentifier],
          timeout: Self.mountUnmountTimeout
        ).succeeded
      }
      DispatchQueue.main.async {
        completion?()
        guard let self else { return }
        if reportFailures {
          self.reportBulkFailures(
            failures,
            title: NSLocalizedString("Unmount Failed", comment: "Alert title"),
            format: NSLocalizedString(
              "Could not unmount: %@", comment: "Bulk unmount failure; list of volume names"))
        }
        self.refreshDrives(qos: .userInitiated) {
          self.unmountAllRunCount -= 1
          self.isUnmountingAll = self.unmountAllRunCount > 0
        }
      }
    }
  }

  func mountAllVolumes() {
    let volumesToMount = bulkActionDisks
      .flatMap(\.allVolumes)
      .filter {
        // EFI partitions cannot be mounted by diskutil (see .mountEFIVolume).
        !$0.isMounted && $0.category == .user && $0.name.uppercased() != "EFI"
          && !PersistenceManager.shared.isVolumeBlocked($0)
      }

    guard !volumesToMount.isEmpty else { return }

    for volume in volumesToMount {
      KeepAliveManager.shared.resume(volume: volume)
      // Lets the mount through MountMate's own auto-mount block.
      let userInfo = ["deviceIdentifier": volume.deviceIdentifier]
      NotificationCenter.default.post(name: .willManuallyMount, object: nil, userInfo: userInfo)
    }

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let failures = Self.runConcurrently(volumesToMount) { volume in
        let result = runProcess(
          executable: "/usr/sbin/diskutil", arguments: ["mount", volume.deviceIdentifier],
          timeout: Self.mountUnmountTimeout)
        // Locked (encrypted) volumes are expected to stay unmounted here;
        // they are skipped rather than reported as failures.
        return result.succeeded || Self.isLockedVolumeFailure(result)
      }
      DispatchQueue.main.async {
        guard let self else { return }
        self.reportBulkFailures(
          failures,
          title: NSLocalizedString("Mount Failed", comment: "Alert title"),
          format: NSLocalizedString(
            "Could not mount: %@", comment: "Bulk mount failure; list of volume names"))
        self.refreshDrives(qos: .userInitiated)
      }
    }
  }

  private static func isLockedVolumeFailure(_ result: ProcessResult) -> Bool {
    guard !result.timedOut else { return false }
    let output = "\(result.stdout)\n\(result.stderr)".lowercased()
    return output.contains("encrypted and locked") || output.contains("unlockvolume")
  }

  /// Runs `operation` for every volume in parallel (at most one per CPU core)
  /// and returns the volumes it failed for, in the original order. Blocks
  /// until all are done; call off the main thread.
  private static func runConcurrently(
    _ volumes: [Volume], operation: (Volume) -> Bool
  ) -> [Volume] {
    final class Results: @unchecked Sendable {
      private let lock = NSLock()
      private var succeeded: [Bool]
      init(count: Int) { succeeded = Array(repeating: false, count: count) }
      func set(_ index: Int, _ ok: Bool) { lock.withLock { succeeded[index] = ok } }
      var values: [Bool] { lock.withLock { succeeded } }
    }
    let results = Results(count: volumes.count)
    DispatchQueue.concurrentPerform(iterations: volumes.count) { index in
      results.set(index, operation(volumes[index]))
    }
    return zip(volumes, results.values).filter { !$0.1 }.map(\.0)
  }

  private func reportBulkFailures(_ failures: [Volume], title: String, format: String) {
    guard !failures.isEmpty else { return }
    let names = failures.map(\.name).joined(separator: ", ")
    userActionError = AppAlert(
      title: title, message: String(format: format, names), kind: .basic)
  }

  /// User-facing description of a failed diskutil run.
  private static func failureMessage(for result: ProcessResult, timeout: TimeInterval) -> String {
    if result.timedOut {
      return String(
        format: NSLocalizedString(
          "The operation timed out after %d seconds.",
          comment: "Disk operation error; number of seconds"), Int32(timeout))
    }
    if result.stderr.isEmpty {
      return String(
        format: NSLocalizedString(
          "diskutil exited with code %d.", comment: "Disk operation error; process exit code"),
        result.exitCode ?? -1)
    }
    return result.stderr
  }

  func eject(disk: PhysicalDisk) {
    // Nothing could confirm what this disk is (it may be the internal
    // disk). Never refuse silently. Disk images are never internal.
    guard disk.type == .diskImage || !unverifiedDiskIDs.contains(disk.id) else {
      userActionError = AppAlert(
        title: NSLocalizedString("Eject Failed", comment: "Alert title"),
        message: String(
          format: NSLocalizedString(
            "MountMate could not determine whether “%@” is an external disk, so it was not ejected. Try again in a moment.",
            comment: "Eject refused because the disk type is unknown; disk name"),
          disk.name ?? disk.id),
        kind: .basic)
      return
    }
    KeepAliveManager.shared.suppress(volumes: disk.allVolumes)
    setEjecting(disk.id, true)
    DispatchQueue.global(qos: .userInitiated).async {
      // A RAID master is a virtual logical disk. `eject` is only valid for a
      // physical device, while unmountDisk safely unmounts every volume in the
      // set and produces the same Finder-visible result.
      let ejectArgs = disk.isRAIDSet ? ["unmountDisk", disk.id] : ["eject", disk.id]
      // A sleeping (spun-down) disk has to wake before it can be ejected,
      // which can take well over the default 15s. The first attempt often
      // unmounts the volumes but fails the eject while the drive spins up,
      // so allow more time and retry once before reporting an error (#70).
      let ejectTimeout: TimeInterval = 60
      var result = runProcess(
        executable: "/usr/sbin/diskutil", arguments: ejectArgs, timeout: ejectTimeout)
      if !result.succeeded && !result.timedOut && !Self.isBusyError(result.stderr) {
        Thread.sleep(forTimeInterval: 2)
        result = runProcess(
          executable: "/usr/sbin/diskutil", arguments: ejectArgs, timeout: ejectTimeout)
      }
      DispatchQueue.main.async {
        if !result.succeeded {
          self.setEjecting(disk.id, false)
          self.handleDiskUtilError(
            Self.failureMessage(for: result, timeout: ejectTimeout),
            for: disk.name ?? disk.id, disk: disk, operation: .eject)
          self.refreshDrives(qos: .userInitiated)
        } else {
          self.refreshDrives(qos: .userInitiated) { self.setEjecting(disk.id, false) }
        }
      }
    }
  }

  func forceEject(disk: PhysicalDisk) {
    KeepAliveManager.shared.suppress(volumes: disk.allVolumes)
    setEjecting(disk.id, true)
    DispatchQueue.global(qos: .userInitiated).async {
      let timeout = Self.mountUnmountTimeout
      let forceUnmountResult = runProcess(
        executable: "/usr/sbin/diskutil", arguments: ["unmountDisk", "force", disk.id],
        timeout: timeout)
      let result =
        disk.isRAIDSet
        ? forceUnmountResult
        : runProcess(
          executable: "/usr/sbin/diskutil", arguments: ["eject", disk.id], timeout: timeout)
      DispatchQueue.main.async {
        if !result.succeeded {
          self.setEjecting(disk.id, false)
          self.handleDiskUtilError(
            Self.failureMessage(for: result, timeout: timeout),
            for: disk.name ?? disk.id, disk: disk, operation: .eject)
          self.refreshDrives(qos: .userInitiated)
        } else {
          self.refreshDrives(qos: .userInitiated) { self.setEjecting(disk.id, false) }
        }
      }
    }
  }

  /// True when diskutil refused because something is using the disk; retrying
  /// will not help and the user should get the Force Eject prompt right away.
  private static func isBusyError(_ stderr: String) -> Bool {
    let lower = stderr.lowercased()
    return lower.contains("busy") || lower.contains("in use")
      || lower.contains("dissented by pid")
      || lower.contains("at least one volume could not be unmounted")
  }

  func forceUnmount(volume: Volume) {
    KeepAliveManager.shared.suppress(volume: volume)
    setBusy(volume.id, true)
    DispatchQueue.global(qos: .userInitiated).async {
      let result = runProcess(
        executable: "/usr/sbin/diskutil", arguments: ["unmount", "force", volume.deviceIdentifier],
        timeout: Self.mountUnmountTimeout)
      DispatchQueue.main.async {
        if !result.succeeded {
          self.setBusy(volume.id, false)
          self.handleDiskUtilError(
            Self.failureMessage(for: result, timeout: Self.mountUnmountTimeout),
            for: volume.name, volume: volume, operation: .unmount)
          self.refreshDrives(qos: .userInitiated)
        } else {
          self.refreshDrives(qos: .userInitiated) { self.setBusy(volume.id, false) }
        }
      }
    }
  }

  /// Delay before retrying a mount that failed right after the disk appeared.
  private static let mountRetryDelay: TimeInterval = 5
  /// A volume listed for less than this long may still be settling (probing,
  /// MountMate's own auto-mount block), so a failed mount is retried once.
  private static let recentAppearanceWindow: TimeInterval = 20

  /// Mounts a volume.
  ///
  /// - Parameter allowsErrorAlerts: Pass `false` for automatic (keep-alive)
  ///   mount attempts so transient reconnect failures never surface as error
  ///   dialogs.
  /// - Parameter isUserInitiated: Set to `false` for automatic reconnects so
  ///   blocked-volume mount approval cannot be bypassed.
  func mount(
    volume: Volume, allowsErrorAlerts: Bool = true, isUserInitiated: Bool = true
  ) {
    if isUserInitiated {
      let userInfo = ["deviceIdentifier": volume.deviceIdentifier]
      NotificationCenter.default.post(name: .willManuallyMount, object: nil, userInfo: userInfo)
    }
    KeepAliveManager.shared.resume(volume: volume)
    // Stays set through the retry below and is cleared in handleMountResult.
    setBusy(volume.id, true)
    DispatchQueue.global(qos: .userInitiated).async {
      let result = runProcess(
        executable: "/usr/sbin/diskutil", arguments: ["mount", volume.deviceIdentifier],
        timeout: Self.mountUnmountTimeout)
      if isUserInitiated {
        Self.postDidFinishManualMount(volume)
      }

      if self.shouldRetryMount(after: result, volume: volume) {
        print(
          "Initial mount failed for \(volume.deviceIdentifier) shortly after it appeared, possibly due to a race condition. Retrying in \(Int(Self.mountRetryDelay))s..."
        )

        DispatchQueue.global(qos: .userInitiated).asyncAfter(
          deadline: .now() + Self.mountRetryDelay
        ) {
          if isUserInitiated {
            let userInfo = ["deviceIdentifier": volume.deviceIdentifier]
            NotificationCenter.default.post(
              name: .willManuallyMount, object: nil, userInfo: userInfo)
          }
          let retryResult = runProcess(
            executable: "/usr/sbin/diskutil", arguments: ["mount", volume.deviceIdentifier],
            timeout: Self.mountUnmountTimeout)
          if isUserInitiated {
            Self.postDidFinishManualMount(volume)
          }
          self.handleMountResult(retryResult, for: volume, allowsErrorAlerts: allowsErrorAlerts)
        }
      } else {
        self.handleMountResult(result, for: volume, allowsErrorAlerts: allowsErrorAlerts)
      }
    }
  }

  /// A generic "failed to mount" is retried once only when it is plausibly
  /// transient: the volume appeared moments ago and diskutil did not say the
  /// file system is unsupported. Real failures surface without the delay.
  private func shouldRetryMount(after result: ProcessResult, volume: Volume) -> Bool {
    guard !result.succeeded, !result.timedOut else { return false }
    let error = result.stderr.lowercased()
    guard error.contains("failed to mount") else { return false }
    // Note: diskutil's generic hint ("If the volume is damaged, try the
    // readOnly option") is printed for every failure, so "damaged" is not
    // a usable marker here.
    let permanentMarkers = ["unrecognized", "not supported", "unsupported", "corrupt"]
    if permanentMarkers.contains(where: { error.contains($0) }) { return false }
    let firstSeen = volumeFirstSeenLock.withLock { volumeFirstSeen[volume.id] }
    // Not listed yet: the disk has only just appeared.
    guard let firstSeen else { return true }
    return Date().timeIntervalSince(firstSeen) < Self.recentAppearanceWindow
  }

  private static func postDidFinishManualMount(_ volume: Volume) {
    NotificationCenter.default.post(
      name: .didFinishManualMount, object: nil,
      userInfo: ["deviceIdentifier": volume.deviceIdentifier])
  }

  private func handleMountResult(
    _ result: ProcessResult, for volume: Volume, allowsErrorAlerts: Bool = true
  ) {
    DispatchQueue.main.async {
      guard !result.succeeded else {
        // Keep the spinner until the list shows the volume as mounted.
        self.refreshDrives(qos: .userInitiated) { self.setBusy(volume.id, false) }
        return
      }
      // Cleared before handling the error: a locked volume starts an unlock
      // that marks the volume busy again.
      self.setBusy(volume.id, false)
      if allowsErrorAlerts {
        self.handleDiskUtilError(
          Self.failureMessage(for: result, timeout: Self.mountUnmountTimeout),
          for: volume.name, volume: volume, operation: .mount)
      }
      self.refreshDrives(qos: .userInitiated)
    }
  }

  func mountLockedVolume(_ volume: Volume, passphrase: String) {
    KeepAliveManager.shared.resume(volume: volume)
    let userInfo = ["deviceIdentifier": volume.id]
    NotificationCenter.default.post(name: .willManuallyMount, object: nil, userInfo: userInfo)
    setBusy(volume.id, true)

    // The password the user just typed always wins over a saved one.
    DispatchQueue.global(qos: .userInitiated).async {
      self.performUnlock(volume: volume, passphrase: passphrase, isSavedPassword: false)
    }
  }

  /// Tries the keychain password for a locked volume without prompting.
  /// Returns false when there is no saved password.
  private func unlockWithSavedPassword(_ volume: Volume) -> Bool {
    guard let saved = KeychainManager.shared.load(account: volume.id), !saved.isEmpty else {
      return false
    }
    KeepAliveManager.shared.resume(volume: volume)
    NotificationCenter.default.post(
      name: .willManuallyMount, object: nil, userInfo: ["deviceIdentifier": volume.id])
    setBusy(volume.id, true)
    DispatchQueue.global(qos: .userInitiated).async {
      self.performUnlock(volume: volume, passphrase: saved, isSavedPassword: true)
    }
    return true
  }

  /// True when `diskutil apfs unlockVolume` rejected the passphrase itself
  /// (as opposed to a timeout or any other failure).
  private static func isWrongPassphrase(_ result: ProcessResult) -> Bool {
    guard !result.timedOut else { return false }
    let output = "\(result.stdout)\n\(result.stderr)".lowercased()
    if output.contains("-69749") || output.contains("-69808") { return true }
    return (output.contains("passphrase") || output.contains("password"))
      && (output.contains("incorrect") || output.contains("invalid")
        || output.contains("wrong") || output.contains("not valid"))
  }

  /// Runs `diskutil apfs unlockVolume` (which also mounts the volume).
  /// Blocking; call off the main thread.
  private func performUnlock(volume: Volume, passphrase: String, isSavedPassword: Bool) {
    let result = runProcess(
      executable: "/usr/sbin/diskutil",
      arguments: ["apfs", "unlockVolume", volume.id, "-stdinpassphrase"],
      input: Data(passphrase.utf8), timeout: Self.mountUnmountTimeout)
    // Withdraw the single-use mount approval posted before unlocking, under
    // the same identifier, so it does not stay valid for its full lifetime.
    NotificationCenter.default.post(
      name: .didFinishManualMount, object: nil, userInfo: ["deviceIdentifier": volume.id])
    DispatchQueue.main.async {
      guard !result.succeeded else {
        self.refreshDrives(qos: .userInitiated) { self.setBusy(volume.id, false) }
        return
      }
      self.setBusy(volume.id, false)
      let wrongPassphrase = Self.isWrongPassphrase(result)
      if wrongPassphrase || (isSavedPassword && !result.timedOut) {
        // A mistyped password, or a saved one that failed: ask again instead
        // of showing a generic error. "That password didn't work" only when
        // diskutil actually rejected the passphrase.
        if !wrongPassphrase {
          print("⚠️ Unlock with saved password failed: \(result.stderr)")
        }
        self.presentUnlockPrompt(for: volume, passwordFailed: wrongPassphrase)
      } else {
        self.handleDiskUtilError(
          Self.failureMessage(for: result, timeout: Self.mountUnmountTimeout),
          for: volume.name, volume: volume, operation: .mount)
      }
      self.refreshDrives(qos: .userInitiated)
    }
  }

  func unmount(volume: Volume) {
    KeepAliveManager.shared.suppress(volume: volume)
    setBusy(volume.id, true)
    DispatchQueue.global(qos: .userInitiated).async {
      let result = runProcess(
        executable: "/usr/sbin/diskutil",
        arguments: ["unmount", volume.deviceIdentifier], timeout: Self.mountUnmountTimeout)
      DispatchQueue.main.async {
        if !result.succeeded {
          self.setBusy(volume.id, false)
          self.handleDiskUtilError(
            Self.failureMessage(for: result, timeout: Self.mountUnmountTimeout),
            for: volume.name, volume: volume, operation: .unmount)
          self.refreshDrives(qos: .userInitiated)
        } else if let image = self.diskImageToDetach(afterUnmounting: volume) {
          // Match Finder: once the last volume of a disk image is unmounted,
          // detach the image so it no longer lingers in the list (#72). The
          // disk's eject spinner takes over from the volume's.
          self.setBusy(volume.id, false)
          self.eject(disk: image)
        } else {
          self.refreshDrives(qos: .userInitiated) { self.setBusy(volume.id, false) }
        }
      }
    }
  }

  /// The disk image containing `volume`, if no other volume on it is still
  /// mounted. Returns nil for real disks, which stay attached after unmount.
  private func diskImageToDetach(afterUnmounting volume: Volume) -> PhysicalDisk? {
    guard
      let disk = (physicalDisks ?? []).first(where: {
        $0.type == .diskImage && $0.allVolumes.contains { $0.id == volume.id }
      })
    else { return nil }
    let othersMounted = disk.allVolumes.contains { $0.id != volume.id && $0.isMounted }
    return othersMounted ? nil : disk
  }

  func remount(volume: Volume) {
    // Keep-alive must not reconnect the volume in the gap between the
    // unmount and the mount below; mount(volume:) resumes it.
    KeepAliveManager.shared.suppress(volume: volume)
    setBusy(volume.id, true)
    DispatchQueue.global(qos: .userInitiated).async {
      let result = runProcess(
        executable: "/usr/sbin/diskutil",
        arguments: ["unmount", volume.deviceIdentifier], timeout: Self.mountUnmountTimeout)
      DispatchQueue.main.async {
        if !result.succeeded {
          // Still mounted: undo the suppression.
          KeepAliveManager.shared.resume(volume: volume)
          self.setBusy(volume.id, false)
          self.handleDiskUtilError(
            Self.failureMessage(for: result, timeout: Self.mountUnmountTimeout),
            for: volume.name, volume: volume, operation: .unmount)
          self.refreshDrives(qos: .userInitiated)
          return
        }

        // Stays busy: mount(volume:) clears it when it finishes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
          self.mount(volume: volume)
        }
      }
    }
  }

  func normalizedMountPointPath(_ rawPath: String) -> String {
    (rawPath.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
  }

  func customMountPointValidationError(for rawPath: String, excluding volume: Volume? = nil)
    -> String?
  {
    let path = normalizedMountPointPath(rawPath)

    guard !path.isEmpty else {
      return NSLocalizedString(
        "Custom Mount Point Empty Path",
        comment: "Custom mount point validation")
    }
    guard path.hasPrefix("/") else {
      return NSLocalizedString(
        "Custom Mount Point Must Be Absolute",
        comment: "Custom mount point validation")
    }
    guard path != "/" else {
      return NSLocalizedString(
        "Custom Mount Point Cannot Be Root",
        comment: "Custom mount point validation")
    }
    if let mountedVolumeName = mountedVolumeName(at: path, excluding: volume) {
      return String(
        format: NSLocalizedString(
          "Custom Mount Point In Use",
          comment: "Custom mount point validation"), mountedVolumeName)
    }

    var isDirectory = ObjCBool(false)
    if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    {
      return NSLocalizedString(
        "Custom Mount Point Must Be Folder",
        comment: "Custom mount point validation")
    }

    return nil
  }

  func inspectDirectory(at rawPath: String) throws -> (
    exists: Bool, isDirectory: Bool, isEmpty: Bool
  ) {
    let path = normalizedMountPointPath(rawPath)
    var isDirectory = ObjCBool(false)
    let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
    guard exists else { return (false, false, true) }
    guard isDirectory.boolValue else { return (true, false, false) }

    let contents = try FileManager.default.contentsOfDirectory(atPath: path)
    return (true, true, contents.isEmpty)
  }

  // MARK: - Parsing and Data Creation Helpers

  /// Composite IDs of ignored and protected volumes, copied on the main
  /// thread so background parsing never reads PersistenceManager's arrays
  /// while the UI mutates them.
  private struct VolumeFilterSnapshot {
    let ignoredIDs: Set<String>
    let protectedIDs: Set<String>
    /// Filled in while parsing (on the parsing thread only).
    let usage = UsageReport()
  }

  private final class UsageReport {
    /// A statfs timed out (or was still blocked from an earlier refresh).
    var timedOut = false
  }

  private func parseDisks(from plist: [String: Any], filters: VolumeFilterSnapshot) -> (
    disks: [PhysicalDisk], unverifiedDiskIDs: Set<String>
  ) {
    guard let allDisksAndPartitions = plist["AllDisksAndPartitions"] as? [[String: Any]] else {
      return ([], [])
    }

    var childDeviceIDs = Set<String>()
    for diskData in allDisksAndPartitions {
      if let partitions = diskData["Partitions"] as? [[String: Any]] {
        for partition in partitions {
          childDeviceIDs.insert(partition["DeviceIdentifier"] as? String ?? "")
        }
      }
    }

    let rootDisks = allDisksAndPartitions.filter { diskData in
      let deviceID = diskData["DeviceIdentifier"] as? String ?? ""
      let isSynthesizedAPFS = diskData["APFSPhysicalStores"] != nil
      return !childDeviceIDs.contains(deviceID) && !isSynthesizedAPFS
    }

    // Fetch info for all root disks in parallel to drastically reduce refresh latency
    let group = DispatchGroup()
    let lock = NSLock()
    var rootInfoMap = [String: [String: Any]]()

    for disk in rootDisks {
      guard let identifier = disk["DeviceIdentifier"] as? String else { continue }
      group.enter()
      DispatchQueue.global(qos: .userInitiated).async {
        // Only a real info plist counts; a timeout or error yields nil.
        if let info = self.getInfoForDisk(for: identifier), info["DeviceIdentifier"] != nil {
          lock.withLock {
            rootInfoMap[identifier] = info
          }
        }
        group.leave()
      }
    }
    group.wait()
    let freshInfo = rootInfoMap

    // Fall back to the last good info of a disk whose info is missing now.
    var rootInfo = [String: [String: Any]]()
    var unclassifiedDiskIDs = Set<String>()
    wholeDiskInfoCacheLock.withLock {
      // Forget disks that are gone, so a reused BSD name never inherits the
      // classification of a different disk.
      let presentIDs = Set(rootDisks.compactMap { $0["DeviceIdentifier"] as? String })
      wholeDiskInfoCache = wholeDiskInfoCache.filter { presentIDs.contains($0.key) }

      for diskData in rootDisks {
        guard let identifier = diskData["DeviceIdentifier"] as? String else { continue }
        let identity = Self.listIdentity(of: diskData)
        if let info = freshInfo[identifier] {
          wholeDiskInfoCache[identifier] = CachedDiskInfo(info: info, identity: identity)
          rootInfo[identifier] = info
        } else if let cached = wholeDiskInfoCache[identifier], cached.identity == identity {
          print("⚠️ diskutil info failed for \(identifier); using cached disk information.")
          rootInfo[identifier] = cached.info
        } else {
          print("⚠️ diskutil info failed for \(identifier) and nothing is cached.")
          unclassifiedDiskIDs.insert(identifier)
        }
      }
    }

    // Second opinions for disks without any info: Disk Arbitration first (no
    // process), then `diskutil list external` once per refresh if needed.
    var fallbackKinds = [String: FallbackDiskKind]()
    if !unclassifiedDiskIDs.isEmpty {
      let session = DASessionCreate(kCFAllocatorDefault)
      var externalWholeDiskIDs: Set<String>?
      var didListExternal = false
      for identifier in unclassifiedDiskIDs {
        var kind = session.map { Self.diskArbitrationKind(of: identifier, session: $0) } ?? .unknown
        if kind == .unknown {
          if !didListExternal {
            didListExternal = true
            externalWholeDiskIDs = Self.externalWholeDiskIdentifiers()
          }
          if externalWholeDiskIDs?.contains(identifier) == true { kind = .external }
        }
        fallbackKinds[identifier] = kind
        print("ℹ️ Classified \(identifier) without diskutil info as \(kind).")
      }
    }

    let shouldShowInternalDisks = UserDefaults.standard.bool(forKey: "showInternalDisks")
    var newDisks: [PhysicalDisk] = []
    var unverifiedDiskIDs = Set<String>()

    for diskData in rootDisks {
      guard let physicalIdentifier = diskData["DeviceIdentifier"] as? String else { continue }
      let infoPlist = rootInfo[physicalIdentifier]
      let diskPartitions = diskData["Partitions"] as? [[String: Any]]
      if DiskTopology.isRAIDMember(infoPlist, partitions: diskPartitions) { continue }

      let isInternal: Bool
      let fallbackKind = fallbackKinds[physicalIdentifier]
      if let infoPlist {
        isInternal = (infoPlist["Internal"] as? Bool) ?? false
      } else {
        // Only hide a disk positively known to be internal. A disk nothing
        // could classify is listed (as unverified, never removable) rather
        // than made to vanish.
        isInternal = fallbackKind == .internalDisk
      }
      if isInternal && !shouldShowInternalDisks { continue }

      var partitions: [Volume] = []
      var containers: [APFSContainer] = []

      if let diskPartitions = diskData["Partitions"] as? [[String: Any]] {
        for partitionData in diskPartitions {
          if let contentType = partitionData["Content"] as? String,
            contentType == "Apple_APFS"
          {
            let storeID = partitionData["DeviceIdentifier"] as? String ?? ""
            if let containerData = findAPFSContainer(
              forStore: storeID, in: allDisksAndPartitions),
              let container = createContainer(from: containerData, filters: filters)
            {
              containers.append(container)
            }
          } else {
            if let volume = createVolume(
              from: partitionData, snapshotsData: nil, filters: filters)
            {
              partitions.append(volume)
            }
          }
        }
      } else if diskData["APFSVolumes"] as? [[String: Any]] != nil {
        if let container = createContainer(from: diskData, filters: filters) {
          containers.append(container)
        }
      }

      if partitions.isEmpty && containers.isEmpty, DiskTopology.hasWholeDiskVolume(diskData) {
        if let volume = createVolume(from: diskData, snapshotsData: nil, filters: filters) {
          partitions.append(volume)
        }
      }

      if !partitions.isEmpty || !containers.isEmpty {
        let connectionInfo =
          infoPlist != nil
          ? getConnectionInfo(from: infoPlist, isInternal: isInternal)
          : Self.fallbackConnectionInfo(for: fallbackKind ?? .unknown)
        let diskName =
          infoPlist?["IORegistryEntryName"] as? String ?? infoPlist?["MediaName"]
          as? String
          ?? (partitions.first ?? containers.first?.volumes.first)?.name
        let totalBytes = diskData["Size"] as? Int64 ?? 0

        let allVolumesForStats = partitions + containers.flatMap { $0.volumes }
        let stats = calculateParentDiskStats(
          totalBytes: totalBytes, volumes: allVolumesForStats)

        let physicalDisk = PhysicalDisk(
          id: physicalIdentifier, diskUUID: infoPlist?["DiskUUID"] as? String,
          connectionType: connectionInfo.type, name: diskName,
          totalSize: stats.total, freeSpace: stats.free, usedSpace: stats.used,
          usagePercentage: stats.percentage, type: connectionInfo.diskType,
          isRAIDSet: DiskTopology.isRAIDMaster(infoPlist),
          partitions: partitions, containers: containers, storageError: stats.error)
        newDisks.append(physicalDisk)
        if infoPlist == nil, fallbackKind == nil || fallbackKind == .unknown {
          unverifiedDiskIDs.insert(physicalIdentifier)
        }
      }
    }

    let sortedDisks = newDisks.sorted {
      let order: (PhysicalDiskType) -> Int = { type in
        type == .internalDisk ? 0 : (type == .physical ? 1 : 2)
      }
      if order($0.type) != order($1.type) { return order($0.type) < order($1.type) }
      return ($0.name ?? "") < ($1.name ?? "")
    }
    return (sortedDisks, unverifiedDiskIDs)
  }

  /// How a whole disk was classified when `diskutil info` was unavailable.
  private enum FallbackDiskKind: CustomStringConvertible {
    case internalDisk, external, diskImage, unknown
    var description: String {
      switch self {
      case .internalDisk: "internal"
      case .external: "external"
      case .diskImage: "disk image"
      case .unknown: "unknown"
      }
    }
  }

  /// Disk Arbitration's view of a whole disk: a fast, process-free second
  /// opinion when `diskutil info` failed.
  private static func diskArbitrationKind(of bsdName: String, session: DASession)
    -> FallbackDiskKind
  {
    guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName),
      let description = DADiskCopyDescription(disk) as? [String: Any]
    else { return .unknown }
    if (description[kDADiskDescriptionDeviceModelKey as String] as? String) == "Disk Image" {
      return .diskImage
    }
    guard let isInternal = description[kDADiskDescriptionDeviceInternalKey as String] as? Bool
    else { return .unknown }
    return isInternal ? .internalDisk : .external
  }

  /// Type for a disk without `diskutil info`. An unknown disk is typed as
  /// internal so nothing treats it as removable (`PhysicalDisk.isRemovable`);
  /// it is also in `unverifiedDiskIDs`.
  private static func fallbackConnectionInfo(for kind: FallbackDiskKind) -> (
    type: String, diskType: PhysicalDiskType
  ) {
    let unknown = NSLocalizedString("Unknown", comment: "Unknown connection type")
    switch kind {
    case .external: return (unknown, .physical)
    case .diskImage: return (NSLocalizedString("Disk Image", comment: "Disk Image"), .diskImage)
    case .internalDisk, .unknown: return (unknown, .internalDisk)
    }
  }

  /// BSD names of the whole disks macOS reports as external
  /// (`diskutil list -plist external`). A cheap second source used only for
  /// disks whose `diskutil info` failed with nothing cached. Nil on failure.
  private static func externalWholeDiskIdentifiers() -> Set<String>? {
    let result = runProcess(
      executable: "/usr/sbin/diskutil", arguments: ["list", "-plist", "external"], timeout: 8)
    guard result.succeeded, let data = result.stdout.data(using: .utf8),
      let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        as? [String: Any],
      let wholeDisks = plist["WholeDisks"] as? [String]
    else { return nil }
    return Set(wholeDisks)
  }

  private func createContainer(
    from containerData: [String: Any], filters: VolumeFilterSnapshot
  ) -> APFSContainer? {
    guard let containerID = containerData["DeviceIdentifier"] as? String,
      let apfsVolumesData = containerData["APFSVolumes"] as? [[String: Any]]
    else {
      return nil
    }

    let volumes = apfsVolumesData.compactMap { apfsVolumeData -> Volume? in
      guard
        let deviceIdentifier = apfsVolumeData["DeviceIdentifier"] as? String,
        !DiskTopology.isSealedSnapshotDevice(deviceIdentifier)
      else { return nil }
      return createVolume(
        from: apfsVolumeData,
        snapshotsData: apfsVolumeData["MountedSnapshots"] as? [[String: Any]],
        filters: filters)
    }
    return APFSContainer(id: containerID, volumes: volumes)
  }

  public func getInfoForDisk(for identifier: String, timeout: TimeInterval = 8.0) -> [String: Any]?
  {
    guard !identifier.isEmpty else { return nil }
    let result = runProcess(
      executable: "/usr/sbin/diskutil", arguments: ["info", "-plist", identifier], timeout: timeout)
    return result.stdout.data(using: .utf8).flatMap {
      try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil)
        as? [String: Any]
    }
  }

  /// The synthesized APFS container backed by `storeID`. A container can span
  /// several physical stores (e.g. a Fusion drive), so any of them matches.
  private func findAPFSContainer(forStore storeID: String, in allDisks: [[String: Any]])
    -> [String:
    Any]?
  {
    return allDisks.first { disk in
      guard let physicalStores = disk["APFSPhysicalStores"] as? [[String: Any]] else {
        return false
      }
      return physicalStores.contains { ($0["DeviceIdentifier"] as? String) == storeID }
    }
  }

  private func calculateParentDiskStats(totalBytes: Int64, volumes: [Volume]) -> (
    total: String?, free: String?, used: String?, percentage: Double?, error: String?
  ) {
    if let errorMessage = volumes.compactMap(\.storageError).first {
      return (nil, nil, nil, nil, errorMessage)
    }
    guard totalBytes > 0 else { return (nil, nil, nil, nil, nil) }

    let usedBytes = volumes.reduce(0) { $0 + ($1.usedBytes ?? 0) }

    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useGB, .useMB, .useKB, .useTB]
    formatter.countStyle = .file
    let totalSizeStr = formatter.string(fromByteCount: totalBytes)
    let freeBytes = totalBytes - usedBytes
    let freeSpaceStr = formatter.string(fromByteCount: freeBytes > 0 ? freeBytes : 0)
    let usedSpaceStr = formatter.string(fromByteCount: usedBytes)
    let usagePercentage = totalBytes > 0 ? min(1.0, Double(usedBytes) / Double(totalBytes)) : 0

    return (totalSizeStr, freeSpaceStr, usedSpaceStr, usagePercentage, nil)
  }

  private func createVolume(
    from volumeData: [String: Any],
    snapshotsData: [[String: Any]]?,
    filters: VolumeFilterSnapshot
  ) -> Volume? {
    guard let deviceIdentifier = volumeData["DeviceIdentifier"] as? String else { return nil }

    let contentType = volumeData["Content"] as? String
    if contentType == "Apple_RAID" || contentType == "Apple_RAID_Offline" {
      return nil
    }

    let volumeUUID = volumeData["VolumeUUID"] as? String ?? deviceIdentifier
    let diskUUID = volumeData["DiskUUID"] as? String

    let volumeName =
      volumeData["VolumeName"] as? String ?? volumeData["Content"] as? String
      ?? deviceIdentifier

    let tempVolume = Volume(
      id: volumeUUID, deviceIdentifier: deviceIdentifier, diskUUID: diskUUID, name: volumeName,
      isMounted: false, mountPoint: nil, freeSpace: nil, totalSize: nil, usedSpace: nil,
      usedBytes: nil, fileSystemType: nil, usagePercentage: nil, category: .user,
      isProtected: false, snapshots: [], storageError: nil)
    // Same matching as PersistenceManager.isVolumeIgnored/isVolumeProtected,
    // against the main-thread snapshot.
    let compositeId = tempVolume.compositeId
    // Volumes without a volume UUID (e.g. Microsoft Reserved) are ignored by
      // their partition UUID; see Volume.ignoreIdentifier.
      if let ignoreID = tempVolume.ignoreIdentifier, filters.ignoredIDs.contains(ignoreID) {
        return nil
      }

    let isProtected = compositeId.map { filters.protectedIDs.contains($0) } ?? false
    let snapshots = snapshotsData?.compactMap { createSnapshot(from: $0) } ?? []

    let category: DriveCategory = contentType == "EFI" ? .system : .user

    let mountPoint: String?
    if let path = volumeData["MountPoint"] as? String {
      let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty && trimmed.caseInsensitiveCompare("Not Mounted") != .orderedSame {
        mountPoint = path
      } else {
        mountPoint = nil
      }
    } else {
      mountPoint = nil
    }
    let isMounted = mountPoint != nil
    let fileSystemType = contentType ?? (volumeData["FilesystemName"] as? String) ?? "Unknown"

    var freeSpaceStr: String?
    var totalSizeStr: String?
    var usedSpaceStr: String?
    var usagePercentage: Double?
    var usedBytes: Int64?
    var storageError: String?

    if let totalSize = volumeData["Size"] as? Int64, totalSize > 0 {
      let formatter = ByteCountFormatter()
      formatter.allowedUnits = [.useGB, .useMB, .useKB, .useTB]
      formatter.countStyle = .file
      totalSizeStr = formatter.string(fromByteCount: totalSize)

      var calculatedUsedBytes: Int64?
      if let capacityInUse = volumeData["CapacityInUse"] as? Int64 {
        calculatedUsedBytes = capacityInUse
      } else if isMounted, let mountPoint = mountPoint {
        // Non-APFS volumes: `diskutil list` has no usage, so ask the file
        // system. statfs needs no privacy permission, but it can block on an
        // unresponsive disk, so it is bounded by a timeout.
        switch Self.fileSystemUsage(atPath: mountPoint) {
        case .usage(let total, let free):
          calculatedUsedBytes = total - free
        case .timedOut:
          filters.usage.timedOut = true
          fallthrough
        case .failed:
          print("Could not read file system usage for \(volumeName) (failed or timed out).")
          storageError = NSLocalizedString(
            "Could not read storage details.",
            comment: "Shown when a volume's used/free space cannot be read")
        }
      }

      if let finalUsedBytes = calculatedUsedBytes {
        usedBytes = finalUsedBytes

        let freeBytes = totalSize - finalUsedBytes
        freeSpaceStr = formatter.string(fromByteCount: freeBytes > 0 ? freeBytes : 0)
        usedSpaceStr = formatter.string(fromByteCount: finalUsedBytes)
        usagePercentage = Double(finalUsedBytes) / Double(totalSize)
      }
    }

    return Volume(
      id: volumeUUID, deviceIdentifier: deviceIdentifier, diskUUID: diskUUID, name: volumeName,
      isMounted: isMounted, mountPoint: mountPoint, freeSpace: freeSpaceStr,
      totalSize: totalSizeStr, usedSpace: usedSpaceStr, usedBytes: usedBytes,
      fileSystemType: fileSystemType,
      usagePercentage: usagePercentage, category: category, isProtected: isProtected,
      snapshots: snapshots,
      storageError: storageError)
  }

  private func createSnapshot(from snapshotData: [String: Any]) -> APFSSnapshot? {
    guard let name = snapshotData["SnapshotName"] as? String,
      let uuid = snapshotData["SnapshotUUID"] as? String
    else { return nil }
    return APFSSnapshot(id: uuid, name: name)
  }

  private func getConnectionInfo(from infoPlist: [String: Any]?, isInternal: Bool) -> (
    type: String, diskType: PhysicalDiskType
  ) {
    let defaultType = NSLocalizedString("Unknown", comment: "Unknown connection type")
    guard let info = infoPlist else {
      return (defaultType, isInternal ? .internalDisk : .physical)
    }

    let isRAIDMaster = DiskTopology.isRAIDMaster(info)
    let isVirtual = info["VirtualOrPhysical"] as? String == "Virtual"

    let diskType: PhysicalDiskType
    if isInternal {
      diskType = .internalDisk
    } else if isVirtual && !isRAIDMaster {
      diskType = .diskImage
    } else {
      diskType = .physical
    }

    let connectionType: String
    if isRAIDMaster {
      connectionType = NSLocalizedString("Apple RAID", comment: "Apple RAID")
    } else if diskType == .diskImage {
      connectionType = NSLocalizedString("Disk Image", comment: "Disk Image")
    } else {
      connectionType = info["BusProtocol"] as? String ?? defaultType
    }

    return (connectionType, diskType)
  }

  // MARK: - Error Handling

  private enum DiskOperation { case mount, unmount, eject }
  private enum DiskUtilError {
    case mountEFIVolume, unmountBusyVolume
    case mountInUseVolume(String?)
    case unmountInUseVolume(String?)
    case
      ejectInUseVolume(String?)
    case
      mountLockedVolume, other
  }

  private func handleDiskUtilError(
    _ error: String, for name: String, volume: Volume? = nil, disk: PhysicalDisk? = nil,
    operation: DiskOperation
  ) {
    let parsedError = self.parseDiskUtilError(error, for: name, operation: operation)
    let title: String
    let message: String
    let kind: AppAlertKind

    switch parsedError {
    case .mountLockedVolume:
      guard let volume else {
        title = String(
          format: NSLocalizedString("“%@” is locked", comment: "Alert title"), name)
        message = String(
          format: NSLocalizedString(
            "Enter the password to unlock “%@”", comment: "Alert message"), name)
        kind = .basic
        break
      }
      if !unlockWithSavedPassword(volume) {
        presentUnlockPrompt(for: volume, passwordFailed: false)
      }
      return
    case .mountEFIVolume:
      title = NSLocalizedString("Mount Failed", comment: "Alert title")
      message = NSLocalizedString(
        "The “EFI” partition cannot be mounted directly. This is a special system partition and this behavior is normal.",
        comment: "Error message")
      kind = .basic
    case .unmountBusyVolume:
      title = NSLocalizedString("Eject Failed", comment: "Alert title")
      message =
        String(
          format: NSLocalizedString(
            "Failed to eject “%@” because one of its volumes is busy or in use.",
            comment: "Error message"), name) + "\n\n"
        + NSLocalizedString("Details", comment: "Error details prefix") + ":\n" + error
      if let disk = disk {
        kind = .forceEject { self.forceEject(disk: disk) }
      } else {
        kind = .basic
      }
    case .mountInUseVolume(let process), .unmountInUseVolume(let process),
      .ejectInUseVolume(let process):
      let verb: String
      switch parsedError {
      case .mountInUseVolume:
        title = NSLocalizedString("Mount Failed", comment: "Alert title")
        verb = NSLocalizedString("mount", comment: "verb")
      case .unmountInUseVolume:
        title = NSLocalizedString("Unmount Failed", comment: "Alert title")
        verb = NSLocalizedString("unmount", comment: "verb")
      default:
        title = NSLocalizedString("Eject Failed", comment: "Alert title")
        verb = NSLocalizedString("eject", comment: "verb")
      }

      if let proc = process {
        message =
          String(
            format: NSLocalizedString(
              "Failed to %@ “%@” because it is currently in use by “%@”.",
              comment: "Error message"), verb, name, proc) + "\n\n"
          + NSLocalizedString("Details", comment: "Error details prefix") + ":\n" + error
      } else {
        message =
          String(
            format: NSLocalizedString(
              "Failed to %@ “%@” because it is currently in use by another application.",
              comment: "Error message"), verb, name) + "\n\n"
          + NSLocalizedString("Details", comment: "Error details prefix") + ":\n" + error
      }

      if operation == .eject, let disk = disk {
        kind = .forceEject { self.forceEject(disk: disk) }
      } else if operation == .unmount, let volume = volume {
        kind = .forceUnmount { self.forceUnmount(volume: volume) }
      } else {
        kind = .basic
      }
    case .other:
      let verb: String
      switch operation {
      case .mount:
        title = NSLocalizedString("Mount Failed", comment: "Alert title")
        verb = NSLocalizedString("mount", comment: "verb")
      case .unmount:
        title = NSLocalizedString("Unmount Failed", comment: "Alert title")
        verb = NSLocalizedString("unmount", comment: "verb")
      case .eject:
        title = NSLocalizedString("Eject Failed", comment: "Alert title")
        verb = NSLocalizedString("eject", comment: "verb")
      }
      message =
        "\(String(format: NSLocalizedString("An unknown error occurred while trying to %@ “%@”.", comment: "Error message"), verb, name))\n\n"
        + NSLocalizedString("Details", comment: "Error details prefix") + ":\n\(error)"
      kind = .basic
    }
    self.userActionError = AppAlert(title: title, message: message, kind: kind)
  }

  /// Asks for the password of a locked APFS volume and unlocks it.
  private func presentUnlockPrompt(for volume: Volume, passwordFailed: Bool) {
    let title = String(
      format: NSLocalizedString("“%@” is locked", comment: "Alert title"), volume.name)
    let message =
      passwordFailed
      ? String(
        format: NSLocalizedString(
          "That password didn’t work. Enter the password to unlock “%@”",
          comment: "Alert message after a wrong or outdated saved password"), volume.name)
      : String(
        format: NSLocalizedString(
          "Enter the password to unlock “%@”", comment: "Alert message"), volume.name)
    let handler = { (passphrase: String, saveInKeychain: Bool) in
      if saveInKeychain {
        _ = KeychainManager.shared.save(password: passphrase, for: volume.id)
      }
      self.mountLockedVolume(volume, passphrase: passphrase)
    }
    userActionError = AppAlert(
      title: title, message: message,
      kind: .lockedVolume(LockedVolumeAppAlert(onConfirm: handler)))
  }

  private func parseDiskUtilError(_ rawError: String, for name: String, operation: DiskOperation)
    -> DiskUtilError
  {
    let lowerCaseError = rawError.lowercased()

    if operation == .mount && name.uppercased() == "EFI" {
      return .mountEFIVolume
    }

    if lowerCaseError.contains("at least one volume could not be unmounted") {
      return .unmountBusyVolume
    }

    if lowerCaseError.contains("busy") || lowerCaseError.contains("in use")
      || lowerCaseError.contains("dissented by pid")
    {
      var processName: String? = nil
      if let range = rawError.range(
        of: "(dissented by PID \\d+ )?\\((/[^)]+)\\)",
        options: [.regularExpression, .caseInsensitive])
      {
        let match = String(rawError[range])
        if let start = match.firstIndex(of: "("), let end = match.firstIndex(of: ")") {
          let pathRange = match.index(after: start)..<end
          let path = String(match[pathRange])
          processName = URL(fileURLWithPath: path).lastPathComponent
        }
      }

      return switch operation {
      case .mount: .mountInUseVolume(processName)
      case .unmount: .unmountInUseVolume(processName)
      case .eject: .ejectInUseVolume(processName)
      }
    }

    if rawError.contains(
      "This is an encrypted and locked APFS Volume; use \"diskutil apfs unlockVolume\"")
    {
      return .mountLockedVolume
    }

    return .other
  }

  /// Mount points whose statfs has not returned yet. While one is still
  /// blocked (unresponsive disk), later refreshes skip it immediately
  /// instead of piling up more blocked threads.
  private static var statfsInFlight = Set<String>()
  private static let statfsLock = NSLock()
  private static let statfsQueue = DispatchQueue(
    label: "com.homielab.mountmate.statfs", qos: .utility, attributes: .concurrent)

  enum FileSystemUsageResult {
    case usage(total: Int64, free: Int64)
    /// No answer within the timeout (or still blocked from an earlier call).
    case timedOut
    case failed
  }

  /// Total and available bytes of the file system mounted at `path`. Never
  /// blocks the caller for longer than `timeout`.
  static func fileSystemUsage(atPath path: String, timeout: TimeInterval = 2)
    -> FileSystemUsageResult
  {
    let started = statfsLock.withLock { statfsInFlight.insert(path).inserted }
    guard started else { return .timedOut }

    final class Box: @unchecked Sendable {
      var value: (total: Int64, free: Int64)?
    }
    let box = Box()
    let done = DispatchSemaphore(value: 0)
    statfsQueue.async {
      var stats = statfs()
      if statfs(path, &stats) == 0 {
        let blockSize = Int64(stats.f_bsize)
        // Same values FileManager reports as systemSize / systemFreeSize.
        box.value = (Int64(stats.f_blocks) * blockSize, Int64(stats.f_bavail) * blockSize)
      }
      Self.statfsLock.withLock { _ = Self.statfsInFlight.remove(path) }
      done.signal()
    }
    // The semaphore orders the write to `box` before this read.
    guard done.wait(timeout: .now() + timeout) == .success else { return .timedOut }
    guard let value = box.value else { return .failed }
    return .usage(total: value.total, free: value.free)
  }

  // MARK: - Notification Handling

  private func setupDiskChangeObservers() {
    let notificationCenter = NSWorkspace.shared.notificationCenter
    notificationCenter.addObserver(
      self, selector: #selector(handleDiskNotification),
      name: NSWorkspace.didMountNotification,
      object: nil)
    notificationCenter.addObserver(
      self, selector: #selector(handleDiskNotification),
      name: NSWorkspace.didUnmountNotification,
      object: nil)
  }

  @objc private func handleDiskNotification(notification: NSNotification) {
    refreshDebounceTimer?.invalidate()
    // Short debounce: coalesces bursts (a disk with several volumes posts one
    // notification per volume) without making plug-ins feel slow.
    refreshDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) {
      [weak self] _ in
      if let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
        print(
          "Disk notification received for volume: \(volumeURL.lastPathComponent). Refreshing list."
        )
      } else {
        print("Disk notification received. Refreshing list.")
      }
      self?.refreshDrives()
    }
  }

  private func mountedVolumeName(at rawPath: String, excluding volume: Volume? = nil) -> String? {
    let targetPath = URL(fileURLWithPath: normalizedMountPointPath(rawPath)).standardizedFileURL
      .path
    let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeUUIDStringKey]
    let mountedURLs =
      FileManager.default.mountedVolumeURLs(
        includingResourceValuesForKeys: Array(keys), options: []) ?? []

    for url in mountedURLs {
      guard url.standardizedFileURL.path == targetPath else { continue }

      if let volume,
        let currentMountPoint = volume.mountPoint,
        URL(fileURLWithPath: currentMountPoint).standardizedFileURL.path == targetPath
      {
        continue
      }

      let values = try? url.resourceValues(forKeys: keys)
      if let volume, values?.volumeUUIDString == volume.id {
        continue
      }

      return values?.volumeName ?? url.lastPathComponent
    }

    return nil
  }
}
