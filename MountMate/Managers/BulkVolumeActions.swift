//  Created by homielab.com

import Foundation

/// The volume selection and the concurrent runner behind "Unmount All",
/// "Mount All" (and unmount-on-sleep) and "Eject All External Disks". `DriveManager` owns the state and the
/// alerts; this type only decides which volumes to act on and runs a
/// per-volume operation for all of them.
enum BulkVolumeActions {
  /// Runs one operation for a volume and says whether it succeeded.
  typealias Runner = (Volume) -> Bool

  /// Removable disks the bulk actions act on. Disks whose type could not be
  /// confirmed in the last refresh are left alone.
  static func actionableDisks(
    _ disks: [PhysicalDisk]?, unverifiedDiskIDs: Set<String>
  ) -> [PhysicalDisk] {
    (disks ?? []).filter { $0.isRemovable && !unverifiedDiskIDs.contains($0.id) }
  }

  /// The volumes "Unmount All" unmounts: mounted, ordinary, not protected.
  static func unmountCandidates(in disks: [PhysicalDisk]) -> [Volume] {
    disks
      .flatMap(\.allVolumes)
      .filter { $0.isMounted && $0.category == .user && !$0.isProtected }
  }

  /// The volumes "Mount All" mounts. `.user` leaves out EFI partitions
  /// (category `.system`), which diskutil cannot mount.
  static func mountCandidates(
    in disks: [PhysicalDisk], isBlocked: (Volume) -> Bool
  ) -> [Volume] {
    disks
      .flatMap(\.allVolumes)
      .filter { !$0.isMounted && $0.category == .user && !isBlocked($0) }
  }

  /// The disks "Eject All External Disks" ejects: physical external disks
  /// whose type was confirmed in the last refresh. Internal disks, disk
  /// images and disks with a protected volume stay (ejecting would unmount
  /// the protected volume too). Network shares are not disks and never
  /// appear here.
  static func ejectCandidates(
    in disks: [PhysicalDisk], unverifiedDiskIDs: Set<String>
  ) -> [PhysicalDisk] {
    disks.filter {
      $0.type == .physical && !unverifiedDiskIDs.contains($0.id)
        && !$0.allVolumes.contains(where: \.isProtected)
    }
  }

  /// The `diskutil` arguments that eject a disk, never forced. A RAID
  /// master is virtual: `eject` only accepts a physical device, so its
  /// volumes are unmounted instead.
  static func ejectArguments(for disk: PhysicalDisk) -> [String] {
    disk.isRAIDSet ? ["unmountDisk", disk.id] : ["eject", disk.id]
  }

  /// `diskutil eject` for a disk. A sleeping disk needs time to wake, hence
  /// the longer timeout (same as the single-disk Eject).
  static func diskutilEject(_ disk: PhysicalDisk) -> Bool {
    runProcess(
      executable: "/usr/sbin/diskutil", arguments: ejectArguments(for: disk), timeout: 60
    ).succeeded
  }

  /// `diskutil unmount` for a volume.
  static func diskutilUnmount(_ volume: Volume) -> Bool {
    runProcess(
      executable: "/usr/sbin/diskutil", arguments: ["unmount", volume.deviceIdentifier],
      timeout: DriveManager.mountUnmountTimeout
    ).succeeded
  }

  /// Mounts `volume` for "Mount All": one attempt, and a second one after
  /// `retryDelay` when `shouldRetry` says the failure looks like the race of a
  /// freshly plugged-in volume. `didFinish` runs exactly once, after the last
  /// attempt, whatever the outcome, so the mount approval is always withdrawn.
  /// Locked (encrypted) volumes are expected to stay unmounted: not a failure.
  static func mountWithRetry(
    _ volume: Volume,
    attempt: (Volume) -> ProcessResult,
    shouldRetry: (ProcessResult, Volume) -> Bool,
    wait: () -> Void,
    didFinish: (Volume) -> Void
  ) -> Bool {
    defer { didFinish(volume) }
    var result = attempt(volume)
    if !result.succeeded, shouldRetry(result, volume) {
      wait()
      result = attempt(volume)
    }
    return result.succeeded || DiskUtilErrorClassifier.isLockedVolumeFailure(result)
  }

  private final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var succeeded: [Bool]
    init(count: Int) { succeeded = Array(repeating: false, count: count) }
    func set(_ index: Int, _ ok: Bool) { lock.withLock { succeeded[index] = ok } }
    var values: [Bool] { lock.withLock { succeeded } }
  }

  /// Runs `runner` for every item (volumes, or disks) in parallel (at most
  /// one per CPU core) and returns the items it failed for, in the original
  /// order. Blocks until all are done; call off the main thread.
  static func runConcurrently<Item>(_ volumes: [Item], runner: (Item) -> Bool) -> [Item] {
    let results = Results(count: volumes.count)
    DispatchQueue.concurrentPerform(iterations: volumes.count) { index in
      results.set(index, runner(volumes[index]))
    }
    return zip(volumes, results.values).filter { !$0.1 }.map(\.0)
  }

  /// One alert naming every volume that failed; nil when none did.
  static func failureAlert(for failures: [Volume], title: String, format: String) -> AppAlert? {
    failureAlert(forNames: failures.map(\.name), title: title, format: format)
  }

  /// Same for any list of names (disks, volumes).
  static func failureAlert(forNames names: [String], title: String, format: String) -> AppAlert? {
    guard !names.isEmpty else { return nil }
    return AppAlert(
      title: title, message: String(format: format, names.joined(separator: ", ")), kind: .basic)
  }
}
