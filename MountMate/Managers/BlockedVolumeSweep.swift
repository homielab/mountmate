//  Created by homielab.com

import Foundation

/// The startup sweep that unmounts blocked volumes the OS mounted before
/// MountMate's user-session callback was active. Pure decisions with the
/// process runner and the retry sleep injected, so every branch is tested
/// (`BlockedVolumeSweepTests`) without running diskutil or sleeping; the I/O
/// lives in `DiskMounter`.
enum BlockedVolumeSweep {
  /// A few retries absorb transient busyness (Spotlight indexing right after
  /// login). Never forces: a persistently busy volume is left mounted.
  static let maxAttempts = 3
  static let retryDelay: TimeInterval = 3.0

  /// What one unmount attempt means for the sweep.
  enum AttemptOutcome: Equatable {
    case success
    case alreadyUnmounted
    /// Busy (or otherwise failed) before the last attempt: sleep and try again.
    case retryAfterSleep
    case gaveUp
  }

  /// The `DeviceIdentifier` of a volume that is actually mounted, from a
  /// `diskutil info -plist` payload. A volume without a mount point (or with
  /// the literal "Not Mounted") is skipped.
  static func mountedDevice(in plist: [String: Any]) -> String? {
    guard let device = plist["DeviceIdentifier"] as? String,
      let mountPoint = plist["MountPoint"] as? String
    else { return nil }
    let trimmed = mountPoint.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
      trimmed.caseInsensitiveCompare("Not Mounted") != .orderedSame
    else { return nil }
    return device
  }

  /// Every partition and APFS volume entry of a `diskutil list -plist`
  /// payload.
  static func volumeEntries(in plist: [String: Any]) -> [[String: Any]] {
    let disks = plist["AllDisksAndPartitions"] as? [[String: Any]] ?? []
    return disks.flatMap { disk -> [[String: Any]] in
      (disk["Partitions"] as? [[String: Any]] ?? [])
        + (disk["APFSVolumes"] as? [[String: Any]] ?? [])
    }
  }

  /// The mounted device to unmount for a blocked volume, from one
  /// `diskutil list -plist` payload. Nil when no volume has its UUID, when
  /// two or more do (a cloned drive: the bare UUID cannot tell which one was
  /// blocked), when the one match lies on another disk (DiskUUID differs;
  /// "NONE" matches a volume without one) or when it is not mounted.
  static func targetDevice(in plist: [String: Any], for info: ManagedVolumeInfo) -> String? {
    guard let volumeUUID = PersistenceManager.normalizedSystemVolumeUUID(info.volumeUUID)
    else { return nil }
    let matches = volumeEntries(in: plist).filter {
      ($0["VolumeUUID"] as? String)?.caseInsensitiveCompare(volumeUUID) == .orderedSame
    }
    guard matches.count == 1, let entry = matches.first else {
      if matches.count > 1 {
        Log.mounter.notice(
          "Skipped blocked volume “\(info.name, privacy: .private)”: \(matches.count, privacy: .public) volumes share its UUID."
        )
      }
      return nil
    }
    let diskUUID = (entry["DiskUUID"] as? String) ?? "NONE"
    guard diskUUID.caseInsensitiveCompare(info.diskUUID) == .orderedSame else { return nil }
    return mountedDevice(in: entry)
  }

  /// True when diskutil says the volume was (or is) not mounted: nothing left
  /// to do for it.
  static func isAlreadyUnmounted(_ result: ProcessResult) -> Bool {
    let output = "\(result.stdout)\n\(result.stderr)".lowercased()
    return output.contains("already unmounted") || output.contains("not mounted")
  }

  /// How to read one unmount attempt. Success and "already unmounted" end the
  /// attempts for this volume; a busy volume is retried until the last
  /// attempt, whose failure hands over to the notification.
  static func classify(_ result: ProcessResult, attempt: Int) -> AttemptOutcome {
    if result.succeeded { return .success }
    if isAlreadyUnmounted(result) { return .alreadyUnmounted }
    return attempt < maxAttempts ? .retryAfterSleep : .gaveUp
  }

  /// Runs the sweep: read `diskutil list -plist` once, then for every blocked
  /// volume that `targetDevice` finds mounted, unmount the device up to `maxAttempts` times,
  /// sleeping `retryDelay` between attempts. `notify` runs once for a volume
  /// that stayed mounted after the last attempt.
  static func run(
    infos: [ManagedVolumeInfo],
    run executable: (String, [String]) -> ProcessResult,
    sleep: (TimeInterval) -> Void,
    notify: (String, String) -> Void
  ) {
    let listResult = executable("/usr/sbin/diskutil", ["list", "-plist"])
    guard listResult.succeeded,
      let plist = PlistDecoding.decode(listResult.stdout, context: "diskutil list")
    else { return }

    for info in infos {
      guard let volumeUUID = PersistenceManager.normalizedSystemVolumeUUID(info.volumeUUID),
        let device = targetDevice(in: plist, for: info)
      else { continue }

      for attempt in 1...maxAttempts {
        let result = executable("/usr/sbin/diskutil", ["unmount", device])
        switch classify(result, attempt: attempt) {
        case .success:
          Log.mounter.notice(
            "Unmounted blocked volume “\(info.name, privacy: .private)” after startup.")
        case .alreadyUnmounted:
          Log.mounter.info(
            "Blocked volume “\(info.name, privacy: .private)” was already unmounted.")
        case .retryAfterSleep:
          Log.mounter.error(
            "Could not unmount blocked volume “\(info.name, privacy: .private)” (attempt \(attempt, privacy: .public)/\(maxAttempts, privacy: .public)): \(result.stderr, privacy: .private)"
          )
          sleep(retryDelay)
          continue
        case .gaveUp:
          Log.mounter.error(
            "Could not unmount blocked volume “\(info.name, privacy: .private)” (attempt \(attempt, privacy: .public)/\(maxAttempts, privacy: .public)): \(result.stderr, privacy: .private)"
          )
          notify(info.name, volumeUUID)
        }
        break
      }
    }
  }
}
