//  Created by homielab.com

import Foundation

/// The volume selection and the concurrent runner behind "Unmount All" and
/// "Mount All" (and unmount-on-sleep). `DriveManager` owns the state and the
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

  /// `diskutil unmount` for a volume.
  static func diskutilUnmount(_ volume: Volume) -> Bool {
    runProcess(
      executable: "/usr/sbin/diskutil", arguments: ["unmount", volume.deviceIdentifier],
      timeout: DriveManager.mountUnmountTimeout
    ).succeeded
  }

  /// `diskutil mount` for a volume. Locked (encrypted) volumes are expected
  /// to stay unmounted here; they are skipped rather than reported as
  /// failures.
  static func diskutilMount(_ volume: Volume) -> Bool {
    let result = runProcess(
      executable: "/usr/sbin/diskutil", arguments: ["mount", volume.deviceIdentifier],
      timeout: DriveManager.mountUnmountTimeout)
    return result.succeeded || DiskUtilErrorClassifier.isLockedVolumeFailure(result)
  }

  /// Runs `runner` for every volume in parallel (at most one per CPU core)
  /// and returns the volumes it failed for, in the original order. Blocks
  /// until all are done; call off the main thread.
  static func runConcurrently(_ volumes: [Volume], runner: Runner) -> [Volume] {
    final class Results: @unchecked Sendable {
      private let lock = NSLock()
      private var succeeded: [Bool]
      init(count: Int) { succeeded = Array(repeating: false, count: count) }
      func set(_ index: Int, _ ok: Bool) { lock.withLock { succeeded[index] = ok } }
      var values: [Bool] { lock.withLock { succeeded } }
    }
    let results = Results(count: volumes.count)
    DispatchQueue.concurrentPerform(iterations: volumes.count) { index in
      results.set(index, runner(volumes[index]))
    }
    return zip(volumes, results.values).filter { !$0.1 }.map(\.0)
  }

  /// One alert naming every volume that failed; nil when none did.
  static func failureAlert(for failures: [Volume], title: String, format: String) -> AppAlert? {
    guard !failures.isEmpty else { return nil }
    let names = failures.map(\.name).joined(separator: ", ")
    return AppAlert(title: title, message: String(format: format, names), kind: .basic)
  }
}
