//  Created by homielab.com

import Combine
import Foundation
import SwiftUI

/// Why a mount did not succeed (the `diskutil` failure message).
struct MountFailure: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

class DriveManager: ObservableObject {
  static let shared = DriveManager()

  @Published var physicalDisks: [PhysicalDisk]? = nil
  @Published var isRefreshing = false
  @Published var userActionError: AppAlert? = nil
  @Published var refreshError: String? = nil
  /// True while `physicalDisks` is the last successful result kept after a
  /// refresh failed (shown with `refreshError`); cleared by the next
  /// successful refresh.
  @Published private(set) var isShowingStaleDisks = false
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
  /// Volumes (by `Volume.id`) with an unlock password saved in the Keychain.
  /// Read once at launch (attributes only, no access prompt), then kept up
  /// to date as passwords are saved and forgotten.
  @Published private(set) var volumeIDsWithSavedPassword: Set<String> = []

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
  static let mountUnmountTimeout: TimeInterval = 30

  /// `diskutil info` of each whole disk, reused while the disk's layout is
  /// unchanged (see `WholeDiskInfoCache`).
  private let wholeDiskInfoCache = WholeDiskInfoCache { identifier in
    // Only a real info plist counts; a timeout or error yields nil.
    guard let info = DriveManager.diskInfo(for: identifier), info["DeviceIdentifier"] != nil
    else { return nil }
    return info
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
    loadSavedPasswordAccounts()
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
    let filters = DiskListParser.Filters(
      ignoredIDs: Set(PersistenceManager.shared.ignoredVolumes.map(\.id)),
      protectedIDs: Set(PersistenceManager.shared.protectedVolumes.map(\.id)))

    DispatchQueue.global(qos: qos).async { [weak self] in
      guard let self = self else { return }

      let listResult = runProcess(executable: "/usr/sbin/diskutil", arguments: ["list", "-plist"])

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
          self.parseDisks(from: plist, filters: filters) { parsed in
            self.updateState(
              with: parsed.disks, unverifiedDiskIDs: parsed.unverifiedDiskIDs,
              usageTimedOut: parsed.usageTimedOut)
          }
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
      self.isShowingStaleDisks = false

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
      for completion in finished { completion() }
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
        Log.drive.error(
          "Refresh failed (\(String(describing: error), privacy: .private)), will retry in \(retryDelay, privacy: .public) seconds (attempt \(self.refreshRetryCount, privacy: .public))"
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) {
          self.refreshDrives()
        }
      } else {
        Log.drive.error(
          "Refresh failed after \(self.maxRefreshRetries, privacy: .public) retries. Showing error to user."
        )
        // Start over: a later one-off failure gets its retry again instead of
        // wiping the list immediately.
        self.refreshRetryCount = 0
        // Keep the last known list: one slow `diskutil list` must not make
        // every disk disappear. Only the first refresh, with nothing to
        // keep, ends the loading state with an empty list.
        if self.physicalDisks == nil {
          self.physicalDisks = []
        } else {
          self.isShowingStaleDisks = true
        }

        let message = NSLocalizedString(
          "MountMate could not get disk information. The system may be busy, a disk may be unresponsive, or permissions may be incorrect.",
          comment: "Final refresh error message")
        self.refreshError = message

        if hadPendingFollowup && !self.hasRunFollowupAfterFailure {
          self.hasRunFollowupAfterFailure = true
          self.refreshDrives(qos: .userInitiated)
        }
      }
      for completion in finished { completion() }
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
    let volumesToMount =
      bulkActionDisks
      .flatMap(\.allVolumes)
      .filter {
        // `.user` leaves out EFI partitions (category `.system`), which
        // diskutil cannot mount (see .mountEFIVolume).
        !$0.isMounted && $0.category == .user
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
        return result.succeeded || DiskUtilErrorClassifier.isLockedVolumeFailure(result)
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
      if !result.succeeded && !result.timedOut
        && !DiskUtilErrorClassifier.isBusyFailure(stderr: result.stderr)
      {
        Thread.sleep(forTimeInterval: 2)
        result = runProcess(
          executable: "/usr/sbin/diskutil", arguments: ejectArgs, timeout: ejectTimeout)
      }
      DispatchQueue.main.async {
        if !result.succeeded {
          self.setEjecting(disk.id, false)
          self.handleDiskUtilError(
            DiskUtilErrorClassifier.failureMessage(for: result, timeout: ejectTimeout),
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
            DiskUtilErrorClassifier.failureMessage(for: result, timeout: timeout),
            for: disk.name ?? disk.id, disk: disk, operation: .eject)
          self.refreshDrives(qos: .userInitiated)
        } else {
          self.refreshDrives(qos: .userInitiated) { self.setEjecting(disk.id, false) }
        }
      }
    }
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
            DiskUtilErrorClassifier.failureMessage(for: result, timeout: Self.mountUnmountTimeout),
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
  /// - Parameter readOnly: Mount with `diskutil mount readOnly`.
  /// - Parameter allowsErrorAlerts: Pass `false` for automatic (keep-alive)
  ///   mount attempts so transient reconnect failures never surface as error
  ///   dialogs.
  /// - Parameter isUserInitiated: Set to `false` for automatic reconnects so
  ///   blocked-volume mount approval cannot be bypassed.
  /// - Parameter completion: Called on the main thread once the mount has
  ///   finished (including the retry and the disk list refresh), with the
  ///   failure message of `diskutil` when it did not succeed.
  func mount(
    volume: Volume, readOnly: Bool = false, allowsErrorAlerts: Bool = true,
    isUserInitiated: Bool = true,
    completion: ((Result<Void, Error>) -> Void)? = nil
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
        executable: "/usr/sbin/diskutil",
        arguments: Self.mountArguments(for: volume, readOnly: readOnly),
        timeout: Self.mountUnmountTimeout)
      if isUserInitiated {
        Self.postDidFinishManualMount(volume)
      }

      if self.shouldRetryMount(after: result, volume: volume) {
        Log.drive.notice(
          "Initial mount failed for \(volume.deviceIdentifier, privacy: .public) shortly after it appeared, possibly due to a race condition. Retrying in \(Int(Self.mountRetryDelay), privacy: .public)s"
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
            executable: "/usr/sbin/diskutil",
            arguments: Self.mountArguments(for: volume, readOnly: readOnly),
            timeout: Self.mountUnmountTimeout)
          if isUserInitiated {
            Self.postDidFinishManualMount(volume)
          }
          self.handleMountResult(
            retryResult, for: volume, allowsErrorAlerts: allowsErrorAlerts, completion: completion)
        }
      } else {
        self.handleMountResult(
          result, for: volume, allowsErrorAlerts: allowsErrorAlerts, completion: completion)
      }
    }
  }

  /// The `diskutil` arguments that mount `volume`.
  static func mountArguments(for volume: Volume, readOnly: Bool) -> [String] {
    readOnly
      ? ["mount", "readOnly", volume.deviceIdentifier] : ["mount", volume.deviceIdentifier]
  }

  private func shouldRetryMount(after result: ProcessResult, volume: Volume) -> Bool {
    let firstSeen = volumeFirstSeenLock.withLock { volumeFirstSeen[volume.id] }
    return DiskUtilErrorClassifier.shouldRetryMount(
      after: result, firstSeen: firstSeen, now: Date(), window: Self.recentAppearanceWindow)
  }

  private static func postDidFinishManualMount(_ volume: Volume) {
    NotificationCenter.default.post(
      name: .didFinishManualMount, object: nil,
      userInfo: ["deviceIdentifier": volume.deviceIdentifier])
  }

  private func handleMountResult(
    _ result: ProcessResult, for volume: Volume, allowsErrorAlerts: Bool = true,
    completion: ((Result<Void, Error>) -> Void)? = nil
  ) {
    DispatchQueue.main.async {
      guard !result.succeeded else {
        // Keep the spinner until the list shows the volume as mounted.
        self.refreshDrives(qos: .userInitiated) {
          self.setBusy(volume.id, false)
          completion?(.success(()))
        }
        return
      }
      // Cleared before handling the error: a locked volume starts an unlock
      // that marks the volume busy again.
      self.setBusy(volume.id, false)
      if allowsErrorAlerts {
        self.handleDiskUtilError(
          DiskUtilErrorClassifier.failureMessage(for: result, timeout: Self.mountUnmountTimeout),
          for: volume.name, volume: volume, operation: .mount)
      }
      self.refreshDrives(qos: .userInitiated) {
        completion?(
          .failure(
            MountFailure(
              message: DiskUtilErrorClassifier.failureMessage(
                for: result, timeout: Self.mountUnmountTimeout))))
      }
    }
  }

  func mountLockedVolume(_ volume: Volume, passphrase: String, rememberPassphrase: Bool = false) {
    KeepAliveManager.shared.resume(volume: volume)
    let userInfo = ["deviceIdentifier": volume.id]
    NotificationCenter.default.post(name: .willManuallyMount, object: nil, userInfo: userInfo)
    setBusy(volume.id, true)

    // The password the user just typed always wins over a saved one.
    DispatchQueue.global(qos: .userInitiated).async {
      self.performUnlock(
        volume: volume, passphrase: passphrase, isSavedPassword: false,
        rememberPassphrase: rememberPassphrase)
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

  /// Saves the passphrase the user asked to remember, but only once it has
  /// unlocked the volume, so a mistyped password is never stored.
  ///
  /// - Returns: nil when nothing was saved, otherwise the Keychain status.
  static func rememberPassphraseIfUnlocked(
    _ passphrase: String, for volume: Volume, unlocked: Bool, remember: Bool,
    store: PasswordStore
  ) -> OSStatus? {
    guard unlocked, remember else { return nil }
    return store.save(password: passphrase, for: volume.id, name: volume.name, kind: .apfsVolume)
  }

  /// Runs `diskutil apfs unlockVolume` (which also mounts the volume).
  /// Blocking; call off the main thread.
  private func performUnlock(
    volume: Volume, passphrase: String, isSavedPassword: Bool, rememberPassphrase: Bool = false
  ) {
    let result = runProcess(
      executable: "/usr/sbin/diskutil",
      arguments: ["apfs", "unlockVolume", volume.id, "-stdinpassphrase"],
      input: Data(passphrase.utf8), timeout: Self.mountUnmountTimeout)
    let saveStatus = Self.rememberPassphraseIfUnlocked(
      passphrase, for: volume, unlocked: result.succeeded, remember: rememberPassphrase,
      store: KeychainManager.shared)
    // Withdraw the single-use mount approval posted before unlocking, under
    // the same identifier, so it does not stay valid for its full lifetime.
    NotificationCenter.default.post(
      name: .didFinishManualMount, object: nil, userInfo: ["deviceIdentifier": volume.id])
    DispatchQueue.main.async {
      guard !result.succeeded else {
        if let saveStatus {
          self.handlePassphraseSaveResult(saveStatus, for: volume)
        }
        self.refreshDrives(qos: .userInitiated) { self.setBusy(volume.id, false) }
        return
      }
      self.setBusy(volume.id, false)
      let wrongPassphrase = DiskUtilErrorClassifier.isWrongPassphrase(result)
      if wrongPassphrase || (isSavedPassword && !result.timedOut) {
        // A mistyped password, or a saved one that failed: ask again instead
        // of showing a generic error. "That password didn't work" only when
        // diskutil actually rejected the passphrase.
        if !wrongPassphrase {
          Log.drive.error("Unlock with saved password failed: \(result.stderr, privacy: .private)")
        }
        self.presentUnlockPrompt(for: volume, passwordFailed: wrongPassphrase)
      } else {
        self.handleDiskUtilError(
          DiskUtilErrorClassifier.failureMessage(for: result, timeout: Self.mountUnmountTimeout),
          for: volume.name, volume: volume, operation: .mount)
      }
      self.refreshDrives(qos: .userInitiated)
    }
  }

  /// Main thread. Records a saved passphrase, or tells the user it could not
  /// be saved (the volume is unlocked either way).
  private func handlePassphraseSaveResult(_ status: OSStatus, for volume: Volume) {
    guard status != errSecSuccess else {
      volumeIDsWithSavedPassword.insert(volume.id)
      return
    }
    userActionError = AppAlert(
      title: NSLocalizedString("Password Not Saved", comment: "Alert title"),
      message: String(
        format: NSLocalizedString(
          "“%@” is unlocked, but MountMate could not save its password to the Keychain (error %d).",
          comment: "Alert message: APFS unlock succeeded, Keychain save failed"),
        volume.name, status),
      kind: .basic)
  }

  /// Deletes the saved unlock password of an APFS volume.
  func forgetSavedPassword(for volume: Volume) {
    DispatchQueue.global(qos: .userInitiated).async {
      let status = KeychainManager.shared.delete(account: volume.id)
      DispatchQueue.main.async {
        guard status == errSecSuccess || status == errSecItemNotFound else {
          self.userActionError = AppAlert(
            title: NSLocalizedString("Action Failed", comment: "Alert title"),
            message: String(
              format: NSLocalizedString(
                "MountMate could not remove the saved password from the Keychain (error %d).",
                comment: "Keychain delete error"),
              status),
            kind: .basic)
          return
        }
        self.volumeIDsWithSavedPassword.remove(volume.id)
      }
    }
  }

  /// Reads which volumes have a saved password, off the main thread.
  private func loadSavedPasswordAccounts() {
    DispatchQueue.global(qos: .utility).async {
      let accounts = KeychainManager.shared.savedAccounts()
      DispatchQueue.main.async { self.volumeIDsWithSavedPassword.formUnion(accounts) }
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
            DiskUtilErrorClassifier.failureMessage(for: result, timeout: Self.mountUnmountTimeout),
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

  /// Unmounts a volume that "Unmount When Idle" found unused. Never forced
  /// and never shows an alert: a volume still in use only gets a log line,
  /// and `completion(false)`. Keep-alive is not suppressed (keep-alive
  /// volumes are never unmounted for being idle). Call on the main thread;
  /// `completion` runs on the main thread.
  func unmountIdleVolume(_ volume: Volume, completion: @escaping (Bool) -> Void) {
    guard !isBusy(volume.id) else {
      completion(false)
      return
    }
    setBusy(volume.id, true)
    DispatchQueue.global(qos: .utility).async {
      let result = runProcess(
        executable: "/usr/sbin/diskutil",
        arguments: ["unmount", volume.deviceIdentifier], timeout: Self.mountUnmountTimeout)
      DispatchQueue.main.async {
        guard result.succeeded else {
          Log.drive.info(
            "Idle unmount of \(volume.name, privacy: .private) skipped (exit \(result.exitCode ?? -1, privacy: .public), timed out: \(result.timedOut, privacy: .public)); retrying after another idle period"
          )
          self.setBusy(volume.id, false)
          completion(false)
          return
        }
        Log.drive.info("Unmounted idle volume \(volume.name, privacy: .private)")
        self.refreshDrives(qos: .utility) { self.setBusy(volume.id, false) }
        completion(true)
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
            DiskUtilErrorClassifier.failureMessage(for: result, timeout: Self.mountUnmountTimeout),
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
    Self.normalizedMountPointPath(rawPath)
  }

  /// Trims surrounding whitespace and expands `~`.
  static func normalizedMountPointPath(_ rawPath: String) -> String {
    (rawPath.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
  }

  func customMountPointValidationError(for rawPath: String, excluding volume: Volume? = nil)
    -> String?
  {
    Self.customMountPointValidationError(for: rawPath) { path in
      self.mountedVolumeName(at: path, excluding: volume)
    }
  }

  /// Why `rawPath` cannot be used as a custom mount point, or nil if it can.
  /// - Parameter mountedVolumeName: the name of another volume already
  ///   mounted at the (normalized) path, if any.
  static func customMountPointValidationError(
    for rawPath: String, mountedVolumeName: (String) -> String?
  ) -> String? {
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
    // A control character (a line break above all) could end the field in the
    // root-written /etc/fstab rule and start a line of its own.
    if FstabRules.containsUnsafeFstabCharacter(path) {
      return NSLocalizedString(
        "Custom Mount Point Control Characters",
        comment: "Custom mount point validation")
    }
    if let mountedVolumeName = mountedVolumeName(path) {
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

  /// What checking a folder chosen as a custom mount point found.
  enum MountPointCheck {
    case invalid(String)
    case directory(exists: Bool, isDirectory: Bool, isEmpty: Bool)
    case inspectFailed(String)
    /// The file system did not answer within the timeout (a hung network share).
    case timedOut
  }

  /// Validates and inspects `rawPath` off the main thread and calls
  /// `completion` on the main thread, after `timeout` at the latest. The folder
  /// may sit on a network share that no longer answers.
  func checkCustomMountPoint(
    _ rawPath: String, excluding volume: Volume? = nil, timeout: TimeInterval = 2,
    completion: @escaping (MountPointCheck) -> Void
  ) {
    Self.runWithTimeout(
      timeout,
      work: { [self] () -> MountPointCheck in
        if let error = customMountPointValidationError(for: rawPath, excluding: volume) {
          return .invalid(error)
        }
        do {
          let state = try inspectDirectory(at: rawPath)
          return .directory(
            exists: state.exists, isDirectory: state.isDirectory, isEmpty: state.isEmpty)
        } catch {
          return .inspectFailed(error.localizedDescription)
        }
      },
      completion: { completion($0 ?? .timedOut) })
  }

  /// Runs `work` on a background queue; `completion` runs once on the main
  /// thread with its result, or with nil when it takes longer than `timeout`
  /// (the work then finishes unobserved).
  static func runWithTimeout<T: Sendable>(
    _ timeout: TimeInterval, work: @escaping @Sendable () -> T,
    completion: @escaping @Sendable (T?) -> Void
  ) {
    let lock = NSLock()
    nonisolated(unsafe) var finished = false
    let finish: @Sendable (T?) -> Void = { value in
      let isFirst = lock.withLock { () -> Bool in
        defer { finished = true }
        return !finished
      }
      guard isFirst else { return }
      DispatchQueue.main.async { completion(value) }
    }
    DispatchQueue.global(qos: .userInitiated).async { finish(work()) }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
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

  // MARK: - Disk List

  /// Reads `diskutil info` for the whole disks that need it (see
  /// `WholeDiskInfoCache`), then builds the list with `DiskListParser`.
  private func parseDisks(
    from plist: [String: Any], filters: DiskListParser.Filters,
    completion: @escaping (DiskListParser.Result) -> Void
  ) {
    guard let allDisksAndPartitions = DiskListParser.allDisksAndPartitions(in: plist) else {
      completion(.empty)
      return
    }
    let rootDisks = DiskListParser.rootDisks(in: allDisksAndPartitions)

    // `diskutil info` only for new, changed or stale disks; runs off this
    // thread and calls back once every disk has its info (or none).
    let disks = rootDisks.compactMap { diskData -> WholeDiskInfoCache.Disk? in
      guard let identifier = diskData["DeviceIdentifier"] as? String else { return nil }
      return WholeDiskInfoCache.Disk(
        identifier: identifier, identity: WholeDiskInfoCache.listIdentity(of: diskData))
    }
    wholeDiskInfoCache.lookup(disks) { lookup in
      Log.drive.debug(
        "Refresh: \(lookup.fetched.count, privacy: .public) diskutil info run(s), \(lookup.reused.count, privacy: .public) disk(s) from cache."
      )
      let parser = DiskListParser(
        filters: filters,
        showInternalDisks: UserDefaults.standard.bool(forKey: "showInternalDisks"),
        fileSystemUsage: { Self.fileSystemUsage(atPath: $0) },
        readOnlyMountPoints: MountTable.readOnlyMountPoints(in: MountTable.entries() ?? []),
        classifyDisksWithoutInfo: DiskListParser.classifyWithSystem)
      completion(
        parser.parse(
          allDisksAndPartitions: allDisksAndPartitions, rootInfo: lookup.info,
          unclassifiedDiskIDs: lookup.unclassified))
    }
  }

  public func getInfoForDisk(for identifier: String, timeout: TimeInterval = 8.0) -> [String: Any]?
  {
    Self.diskInfo(for: identifier, timeout: timeout)
  }

  /// `diskutil info -plist` of a disk or volume; nil on failure or timeout.
  static func diskInfo(for identifier: String, timeout: TimeInterval = 8.0) -> [String: Any]? {
    guard !identifier.isEmpty else { return nil }
    let result = runProcess(
      executable: "/usr/sbin/diskutil", arguments: ["info", "-plist", identifier], timeout: timeout)
    return result.stdout.data(using: .utf8).flatMap {
      try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil)
        as? [String: Any]
    }
  }

  // MARK: - Error Handling

  private func handleDiskUtilError(
    _ error: String, for name: String, volume: Volume? = nil, disk: PhysicalDisk? = nil,
    operation: DiskOperation
  ) {
    let parsedError = DiskUtilErrorClassifier.classify(error, for: name, operation: operation)

    if parsedError == .mountLockedVolume {
      guard let volume else {
        userActionError = AppAlert(
          title: String(
            format: NSLocalizedString("“%@” is locked", comment: "Alert title"), name),
          message: String(
            format: NSLocalizedString(
              "Enter the password to unlock “%@”", comment: "Alert message"), name),
          kind: .basic)
        return
      }
      if !unlockWithSavedPassword(volume) {
        presentUnlockPrompt(for: volume, passwordFailed: false)
      }
      return
    }
    guard
      let text = DiskUtilErrorClassifier.presentation(
        for: parsedError, name: name, operation: operation, details: error)
    else { return }

    let kind: AppAlertKind
    switch parsedError {
    case .unmountBusyVolume:
      kind = disk.map { disk in .forceEject { self.forceEject(disk: disk) } } ?? .basic
    case .inUse where operation == .eject:
      kind = disk.map { disk in .forceEject { self.forceEject(disk: disk) } } ?? .basic
    case .inUse where operation == .unmount:
      kind = volume.map { volume in .forceUnmount { self.forceUnmount(volume: volume) } } ?? .basic
    default:
      kind = .basic
    }
    userActionError = AppAlert(title: text.title, message: text.message, kind: kind)
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
      // Saved only after the unlock succeeds (see performUnlock).
      self.mountLockedVolume(volume, passphrase: passphrase, rememberPassphrase: saveInKeychain)
    }
    userActionError = AppAlert(
      title: title, message: message,
      kind: .lockedVolume(LockedVolumeAppAlert(onConfirm: handler)))
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
        Log.drive.info(
          "Disk notification received for volume \(volumeURL.lastPathComponent, privacy: .private). Refreshing list."
        )
      } else {
        Log.drive.info("Disk notification received. Refreshing list.")
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
