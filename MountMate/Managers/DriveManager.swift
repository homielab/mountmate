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
  @Published var volumeIDsWithSavedPassword: Set<String> = []

  /// Source-compatible accessors for views written for a single busy item.
  /// Prefer `isBusy(_:)` / `isEjecting(_:)`, which are correct when several
  /// operations run at once.
  var busyVolumeIdentifier: String? { busyVolumeIDs.first }
  var busyEjectingIdentifier: String? { busyEjectingDiskIDs.first }

  func isBusy(_ volumeID: String) -> Bool { busyVolumeIDs.contains(volumeID) }
  func isEjecting(_ diskID: String) -> Bool { busyEjectingDiskIDs.contains(diskID) }

  let driveExpansionSubject = PassthroughSubject<Bool, Never>()

  var refreshDebounceTimer: Timer?
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

  /// When `volume` first showed up in the disk list, nil if it is not listed.
  func firstSeen(of volume: Volume) -> Date? {
    volumeFirstSeenLock.withLock { volumeFirstSeen[volume.id] }
  }

  private(set) lazy var unlocker = EncryptedVolumeUnlocker(host: self)

  /// Network mount points as of the last mount event (main thread); an
  /// unmounted share is gone from the table, so this tells what it was.
  var knownNetworkMountPoints: Set<String> = []

  private init() {
    if let entries = MountTable.entries() {
      knownNetworkMountPoints = DiskEventFilter.networkMountPoints(in: entries)
    }
    setupDiskChangeObservers()
    refreshDrives()
    unlocker.loadSavedPasswordAccounts()
  }

  deinit {
    NSWorkspace.shared.notificationCenter.removeObserver(self)
    refreshDebounceTimer?.invalidate()
  }

  // MARK: - Busy State

  /// Main thread only (hops over otherwise). Calls made from one thread keep
  /// their order, so a start always lands before its own completion.
  func setBusy(_ volumeID: String, _ busy: Bool) {
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

  func setEjecting(_ diskID: String, _ busy: Bool) {
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
      NotificationManager.shared.disksRefreshed(disks)
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
    BulkVolumeActions.actionableDisks(physicalDisks, unverifiedDiskIDs: unverifiedDiskIDs)
  }

  /// The volumes "Unmount All" would unmount right now.
  var unmountAllCandidates: [Volume] {
    BulkVolumeActions.unmountCandidates(in: bulkActionDisks)
  }

  /// The disks "Eject All External Disks" would eject right now.
  var ejectAllCandidates: [PhysicalDisk] {
    BulkVolumeActions.ejectCandidates(
      in: physicalDisks ?? [], unverifiedDiskIDs: unverifiedDiskIDs)
  }

  /// Ejects every external disk (`diskutil eject`, never forced), in
  /// parallel, and reports the disks that could not be ejected in one alert.
  /// - Parameter reportFailures: show that alert. Off when the caller
  ///   reports the result itself (Shortcuts).
  /// - Parameter completion: Called on the main thread with the names of the
  ///   disks that could not be ejected, after the drive list refreshed
  ///   (immediately with `[]` when there is nothing to eject).
  func ejectAllDisks(reportFailures: Bool = true, completion: (([String]) -> Void)? = nil) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async {
        self.ejectAllDisks(reportFailures: reportFailures, completion: completion)
      }
      return
    }
    let disks = ejectAllCandidates
    guard !disks.isEmpty else {
      completion?([])
      return
    }
    let volumes = disks.flatMap(\.allVolumes)
    KeepAliveManager.shared.suppress(volumes: volumes)
    WakeRemountManager.shared.forget(volumes)
    for disk in disks { setEjecting(disk.id, true) }

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let failures = BulkVolumeActions.runConcurrently(
        disks, runner: BulkVolumeActions.diskutilEject)
      DispatchQueue.main.async {
        guard let self else { return }
        let names = failures.map { $0.name ?? $0.id }
        if reportFailures,
          let alert = BulkVolumeActions.failureAlert(
            forNames: names,
            title: NSLocalizedString("Eject Failed", comment: "Alert title"),
            format: NSLocalizedString(
              "Could not eject: %@", comment: "Bulk eject failure; list of disk names"))
        {
          self.userActionError = alert
        }
        self.refreshDrives(qos: .userInitiated) {
          for disk in disks { self.setEjecting(disk.id, false) }
          completion?(names)
        }
      }
    }
  }

  /// - Parameter suppressReconnect: `false` when the unmount is not a user
  ///   decision (e.g. the unmount-all-on-sleep action) so that keep-alive
  ///   targets are reconnected on the next wake or sweep.
  /// - Parameter reportFailures: show an alert naming volumes that could not
  ///   be unmounted. Off for automatic actions nobody is watching (sleep).
  /// - Parameter completion: Called on the main thread once every unmount
  ///   has finished (immediately when there is nothing to unmount). Call on
  ///   the main thread.
  /// - Parameter finished: Called on the main thread with the names of the
  ///   volumes that could not be unmounted, after the drive list refreshed.
  /// - Parameter unmountResult: Called on the main thread right before
  ///   `completion` with the volumes that could not be unmounted.
  func unmountAllDrives(
    suppressReconnect: Bool = true, reportFailures: Bool = true,
    completion: (() -> Void)? = nil, finished: (([String]) -> Void)? = nil,
    unmountResult: (([Volume]) -> Void)? = nil
  ) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async {
        self.unmountAllDrives(
          suppressReconnect: suppressReconnect, reportFailures: reportFailures,
          completion: completion, finished: finished, unmountResult: unmountResult)
      }
      return
    }
    let drivesToUnmount = unmountAllCandidates

    guard !drivesToUnmount.isEmpty else {
      completion?()
      finished?([])
      return
    }
    if suppressReconnect {
      KeepAliveManager.shared.suppress(volumes: drivesToUnmount)
      // The user chose this: the volumes stay unmounted after a wake.
      WakeRemountManager.shared.forget(drivesToUnmount)
    }
    unmountAllRunCount += 1
    isUnmountingAll = true

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let failures = BulkVolumeActions.runConcurrently(
        drivesToUnmount, runner: BulkVolumeActions.diskutilUnmount)
      DispatchQueue.main.async {
        unmountResult?(failures)
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
          finished?(failures.map(\.name))
        }
      }
    }
  }

  /// - Parameter reportFailures: show an alert naming volumes that could not
  ///   be mounted. Off when the caller reports the result itself.
  /// - Parameter completion: Called on the main thread with the names of the
  ///   volumes that could not be mounted, after the drive list refreshed.
  func mountAllVolumes(
    reportFailures: Bool = true, completion: (([String]) -> Void)? = nil
  ) {
    let volumesToMount = BulkVolumeActions.mountCandidates(in: bulkActionDisks) {
      PersistenceManager.shared.isVolumeBlocked($0)
    }

    guard !volumesToMount.isEmpty else {
      completion?([])
      return
    }

    for volume in volumesToMount {
      KeepAliveManager.shared.resume(volume: volume)
      // Lets the mount through MountMate's own auto-mount block.
      let userInfo = ["deviceIdentifier": volume.deviceIdentifier]
      NotificationCenter.default.post(name: .willManuallyMount, object: nil, userInfo: userInfo)
    }

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let failures = BulkVolumeActions.runConcurrently(
        volumesToMount, runner: BulkVolumeActions.diskutilMount)
      DispatchQueue.main.async {
        guard let self else { return }
        if reportFailures {
          self.reportBulkFailures(
            failures,
            title: NSLocalizedString("Mount Failed", comment: "Alert title"),
            format: NSLocalizedString(
              "Could not mount: %@", comment: "Bulk mount failure; list of volume names"))
        }
        self.refreshDrives(qos: .userInitiated) {
          completion?(failures.map(\.name))
        }
      }
    }
  }

  private func reportBulkFailures(_ failures: [Volume], title: String, format: String) {
    guard let alert = BulkVolumeActions.failureAlert(for: failures, title: title, format: format)
    else { return }
    userActionError = alert
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
        fileSystemUsage: { FileSystemUsage.read(atPath: $0) },
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
    return PlistDecoding.decode(result.stdout, context: "diskutil info")
  }
}
