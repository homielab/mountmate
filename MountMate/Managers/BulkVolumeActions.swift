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
  /// the protected volume too). Disks already being ejected and disks with
  /// a volume busy (mount, unmount or unlock in flight) are skipped, so a
  /// second run never overlaps the first. Network shares are not disks and
  /// never appear here.
  static func ejectCandidates(
    in disks: [PhysicalDisk], unverifiedDiskIDs: Set<String>,
    ejectingDiskIDs: Set<String> = [], busyVolumeIDs: Set<String> = []
  ) -> [PhysicalDisk] {
    disks.filter { disk in
      disk.type == .physical && !unverifiedDiskIDs.contains(disk.id)
        && !ejectingDiskIDs.contains(disk.id)
        && !disk.allVolumes.contains { $0.isProtected || busyVolumeIDs.contains($0.id) }
    }
  }

  /// Whether a single Eject or Force Eject of `disk` may start: not while
  /// another eject of the same disk is still running. The second call would
  /// read the first one's Keep Alive suppression as the user's own and keep
  /// it after a failure, and end the first one's spinner early.
  static func canStartEject(of disk: PhysicalDisk, ejectingDiskIDs: Set<String>) -> Bool {
    !ejectingDiskIDs.contains(disk.id)
  }

  /// The `diskutil` arguments that eject a disk, never forced. A RAID
  /// master is virtual: `eject` only accepts a physical device, so its
  /// volumes are unmounted instead.
  static func ejectArguments(for disk: PhysicalDisk) -> [String] {
    disk.isRAIDSet ? ["unmountDisk", disk.id] : ["eject", disk.id]
  }

  /// How long an eject may take. A sleeping (spun-down) disk has to wake
  /// before it can be ejected, which can take well over the default 15 s.
  /// Used by the single-disk Eject and by "Eject All External Disks".
  static let ejectTimeout: TimeInterval = 60

  /// `diskutil eject` for a disk, with the longer `ejectTimeout`.
  static func diskutilEject(_ disk: PhysicalDisk) -> Bool {
    runProcess(
      executable: "/usr/sbin/diskutil", arguments: ejectArguments(for: disk),
      timeout: ejectTimeout
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

  private final class Results<Output>: @unchecked Sendable {
    private let lock = NSLock()
    private var outputs: [Output?]
    init(count: Int) { outputs = Array(repeating: nil, count: count) }
    func set(_ index: Int, _ output: Output) { lock.withLock { outputs[index] = output } }
    var values: [Output] { lock.withLock { outputs.compactMap { $0 } } }
  }

  /// Runs `transform` for every item in parallel (at most one per CPU core)
  /// and returns its outputs in the original order. Blocks until all are
  /// done; call off the main thread.
  static func mapConcurrently<Item, Output>(
    _ items: [Item], transform: (Item) -> Output
  ) -> [Output] {
    let results = Results<Output>(count: items.count)
    DispatchQueue.concurrentPerform(iterations: items.count) { index in
      results.set(index, transform(items[index]))
    }
    return results.values
  }

  /// Runs `runner` for every item (volumes, disks or shares) in parallel and
  /// returns the items it failed for, in the original order. Blocks until all
  /// are done; call off the main thread.
  static func runConcurrently<Item>(_ items: [Item], runner: (Item) -> Bool) -> [Item] {
    let succeeded = mapConcurrently(items, transform: runner)
    return zip(items, succeeded).filter { !$0.1 }.map(\.0)
  }

  /// One alert naming every volume that failed; nil when none did.
  static func failureAlert(for failures: [Volume], title: String, format: String) -> AppAlert? {
    failureAlert(forNames: failures.map(\.name), title: title, format: format)
  }

  /// Same for any list of names (disks, volumes, shares). `reasons`, when
  /// given, are listed one per line under the names (each already says which
  /// item it is about); `kind` lets the alert offer a follow-up such as Force
  /// Unmount.
  static func failureAlert(
    forNames names: [String], title: String, format: String, reasons: [String] = [],
    kind: AppAlertKind = .basic
  ) -> AppAlert? {
    guard !names.isEmpty else { return nil }
    var message = String(format: format, names.joined(separator: ", "))
    if !reasons.isEmpty {
      message += "\n\n" + reasons.joined(separator: "\n")
    }
    return AppAlert(title: title, message: message, kind: kind)
  }
}
