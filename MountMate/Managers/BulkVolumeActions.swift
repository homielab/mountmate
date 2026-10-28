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
  /// A volume with an operation in flight (`busyVolumeIDs`) is skipped: a
  /// second `diskutil` would race the first and end its spinner early.
  static func unmountCandidates(
    in disks: [PhysicalDisk], busyVolumeIDs: Set<String> = []
  ) -> [Volume] {
    disks
      .flatMap(\.allVolumes)
      .filter {
        $0.isMounted && $0.category == .user && !$0.isProtected && !busyVolumeIDs.contains($0.id)
      }
  }

  /// The volumes "Mount All" mounts. `.user` leaves out EFI partitions
  /// (category `.system`), which diskutil cannot mount. Volumes with an
  /// operation in flight (`busyVolumeIDs`) are skipped like in `unmountCandidates`.
  static func mountCandidates(
    in disks: [PhysicalDisk], busyVolumeIDs: Set<String> = [], isBlocked: (Volume) -> Bool
  ) -> [Volume] {
    disks
      .flatMap(\.allVolumes)
      .filter {
        !$0.isMounted && $0.category == .user && !busyVolumeIDs.contains($0.id) && !isBlocked($0)
      }
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

  /// Pause before the second eject attempt.
  static let ejectRetryDelay: TimeInterval = 2

  /// `diskutil eject` for a disk, with the longer `ejectTimeout`.
  static func diskutilEject(_ disk: PhysicalDisk) -> ProcessResult {
    runProcess(
      executable: "/usr/sbin/diskutil", arguments: ejectArguments(for: disk),
      timeout: ejectTimeout)
  }

  /// Ejects `disk` and returns the last attempt's result. A sleeping disk
  /// often unmounts its volumes but fails the eject while it spins up, so a
  /// failure is retried once after `ejectRetryDelay` (#70) - unless it timed
  /// out or says something is using the disk: waiting does not help then.
  /// Used by the single Eject and by "Eject All External Disks". `run` and
  /// `wait` are injectable for tests.
  static func ejectWithRetry(
    _ disk: PhysicalDisk,
    run: (PhysicalDisk) -> ProcessResult = diskutilEject,
    wait: () -> Void = { Thread.sleep(forTimeInterval: ejectRetryDelay) }
  ) -> ProcessResult {
    let first = run(disk)
    guard !first.succeeded, !first.timedOut,
      !DiskUtilErrorClassifier.isBusyFailure(stderr: first.stderr)
    else { return first }
    wait()
    return run(disk)
  }

  /// A disk "Eject All External Disks" could not eject: why (it names the
  /// disk) and whether Force Eject may help.
  struct DiskEjectFailure: Equatable {
    let disk: PhysicalDisk
    let reason: String
    let canForce: Bool

    var name: String { disk.name ?? disk.id }
  }

  /// The reason for a failed eject of a disk called `name`. Busy, in use and
  /// timed-out ejects can be forced; other errors cannot.
  static func ejectFailureReason(
    for result: ProcessResult, name: String
  ) -> (reason: String, canForce: Bool) {
    if result.timedOut {
      return (
        "“\(name)”: "
          + DiskUtilErrorClassifier.failureMessage(for: result, timeout: ejectTimeout), true
      )
    }
    switch DiskUtilErrorClassifier.classify(result.stderr, for: name, operation: .eject) {
    case .unmountBusyVolume:
      return (
        String(
          format: NSLocalizedString(
            "Failed to eject “%@” because one of its volumes is busy or in use.",
            comment: "Error message"), name), true
      )
    case .inUse(let process):
      let format =
        process == nil
        ? NSLocalizedString(
          "Failed to eject “%@” because it is currently in use by another application.",
          comment: "Error message")
        : NSLocalizedString(
          "Failed to eject “%@” because it is currently in use by “%@”.",
          comment: "Error message")
      return (
        process.map { String(format: format, name, $0) } ?? String(format: format, name), true
      )
    default:
      let detail = DiskUtilErrorClassifier.failureMessage(for: result, timeout: ejectTimeout)
      return ("“\(name)”: " + detail, false)
    }
  }

  /// Ejects every disk in parallel (each with `ejectWithRetry`) and returns
  /// the ones that failed, in the original order, with their reasons. Blocks
  /// until all are done; call off the main thread.
  static func ejectDisks(
    _ disks: [PhysicalDisk],
    run: (PhysicalDisk) -> ProcessResult = diskutilEject,
    wait: () -> Void = { Thread.sleep(forTimeInterval: ejectRetryDelay) }
  ) -> [DiskEjectFailure] {
    let results = mapConcurrently(disks) { ejectWithRetry($0, run: run, wait: wait) }
    return zip(disks, results).compactMap { disk, result in
      guard !result.succeeded else { return nil }
      let why = ejectFailureReason(for: result, name: disk.name ?? disk.id)
      return DiskEjectFailure(disk: disk, reason: why.reason, canForce: why.canForce)
    }
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
  /// Locked (encrypted) volumes are not a failure: `foundLocked` gets them
  /// with the final result, so the caller can try a saved password.
  static func mountWithRetry(
    _ volume: Volume,
    attempt: (Volume) -> ProcessResult,
    shouldRetry: (ProcessResult, Volume) -> Bool,
    wait: () -> Void,
    didFinish: (Volume) -> Void,
    foundLocked: (Volume, ProcessResult) -> Void = { _, _ in }
  ) -> Bool {
    defer { didFinish(volume) }
    var result = attempt(volume)
    if !result.succeeded, shouldRetry(result, volume) {
      wait()
      result = attempt(volume)
    }
    guard !result.succeeded else { return true }
    guard DiskUtilErrorClassifier.isLockedVolumeFailure(result) else { return false }
    foundLocked(volume, result)
    return true
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
