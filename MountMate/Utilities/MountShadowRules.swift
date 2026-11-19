//  Created by homielab.com

import Foundation

/// Detects the "shadowed mount" failure mode for a registered (keep-alive)
/// volume: the volume should mount at `/Volumes/<Name>`, but an ordinary
/// folder already occupies that path, so macOS mounts it at `/Volumes/<Name>
/// 1` (or ` 2`, …) instead. Pure: it receives plain values and returns a
/// decision; the caller reads the kernel mount table and the file system.
enum MountShadowRules {
  /// One path under `/Volumes`: where it is, the volume UUID mounted there
  /// (nil for a plain folder), and whether it is a real mount point.
  struct MountRecord: Equatable, Sendable {
    let path: String
    let uuid: String?
    let isMountPoint: Bool
  }

  /// A volume mounted at a suffixed path while its expected path is blocked
  /// by a plain folder.
  struct Shadow: Equatable, Sendable {
    let name: String
    let volumeUUID: String
    let actualMountPath: String
    let suffix: Int

    /// The "once per occurrence" key: the same volume at the same suffixed
    /// path. A different path (or a recurrence after it cleared) counts again.
    var occurrenceKey: String { "\(volumeUUID)|\(actualMountPath)" }
  }

  /// `/Volumes/<Name>`.
  static func expectedMountPath(for name: String) -> String {
    "/Volumes/\(name)"
  }

  /// The numeric suffix when `path` is exactly `/Volumes/<name> <digits>`,
  /// else nil. `/Volumes/<name> 10` is 10; `/Volumes/<name> 1`, `/Volumes/
  /// <name> Backup` and `/Volumes/<name>1` are not suffixed mounts.
  static func numericSuffix(of name: String, at path: String) -> Int? {
    let prefix = "/Volumes/\(name) "
    guard path.hasPrefix(prefix) else { return nil }
    let digits = String(path.dropFirst(prefix.count))
    guard digits.range(of: "^[0-9]+$", options: .regularExpression) != nil else { return nil }
    return Int(digits)
  }

  /// A warning when (1) `/Volumes/<name>` is present but not a mount point
  /// and (2) the volume whose UUID matches `registeredUUID` is mounted at a
  /// suffixed path.
  static func shadow(
    expectedName name: String, registeredUUID: String, records: [MountRecord]
  ) -> Shadow? {
    let expectedPath = expectedMountPath(for: name)
    guard let expected = records.first(where: { $0.path == expectedPath }),
      !expected.isMountPoint
    else { return nil }
    let matching = records.first { record in
      guard numericSuffix(of: name, at: record.path) != nil, record.isMountPoint else {
        return false
      }
      return record.uuid?.caseInsensitiveCompare(registeredUUID) == .orderedSame
    }
    guard let record = matching, let suffix = numericSuffix(of: name, at: record.path) else {
      return nil
    }
    return Shadow(
      name: name, volumeUUID: registeredUUID, actualMountPath: record.path, suffix: suffix)
  }

  /// The shadows of `registeredVolumes`, in that order.
  static func shadows(
    for registeredVolumes: [ManagedVolumeInfo], records: [MountRecord]
  ) -> [Shadow] {
    registeredVolumes.compactMap { info in
      shadow(expectedName: info.name, registeredUUID: info.volumeUUID, records: records)
    }
  }
}

/// Remembers which shadowed mounts were already announced, so a volume that
/// stays shadowed is announced once per occurrence (UUID + actual mount
/// path). Not thread-safe: main queue only.
struct MountShadowAlertTracker: Sendable {
  private var announced: Set<String> = []

  /// The shadows not announced yet; they count as announced afterwards.
  /// A shadow that cleared is forgotten, so a recurrence is announced again.
  mutating func newlyShadowed(_ shadows: [MountShadowRules.Shadow]) -> [MountShadowRules.Shadow] {
    announced.formIntersection(Set(shadows.map(\.occurrenceKey)))
    return shadows.filter { announced.insert($0.occurrenceKey).inserted }
  }
}
