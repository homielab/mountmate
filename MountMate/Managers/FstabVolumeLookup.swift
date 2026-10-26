//  Created by homielab.com

import Foundation

/// The `diskutil` lookups a new /etc/fstab rule needs: the file-system type
/// of a volume and whether it may get a startup-block rule. The decisions
/// themselves are in `FstabRules`. Not thread-safe: `PersistenceManager`
/// only uses it on its fstab queue.
final class FstabVolumeLookup {
  /// Boot volume's APFS container (e.g. "disk3"), resolved once per launch.
  /// A failed lookup is not cached.
  private var cachedBootAPFSContainer: String?

  func startupBlockEligibility(forVolumeUUID uuid: String)
    -> FstabRules.StartupBlockEligibility
  {
    guard let plist = diskInfo(for: uuid) else { return .notConnected }

    if cachedBootAPFSContainer == nil {
      cachedBootAPFSContainer = diskInfo(for: "/")?["APFSContainerReference"] as? String
    }

    var roles: [String]?
    if let container = plist["APFSContainerReference"] as? String {
      roles = apfsRoles(forVolumeUUID: uuid, container: container)
    }

    return FstabRules.startupBlockEligibility(
      plist: plist, bootAPFSContainer: cachedBootAPFSContainer, apfsRoles: roles)
  }

  /// The file-system type to write in `volume`'s /etc/fstab rule, or nil
  /// when it cannot be determined.
  func fstabFileSystemType(for volume: Volume) -> String? {
    let plist = diskInfo(for: volume.deviceIdentifier)
    return FstabRules.fstabFileSystemType(plist: plist, fallback: volume.fileSystemType)
  }

  /// APFS roles of a volume, or nil when they cannot be determined.
  private func apfsRoles(forVolumeUUID uuid: String, container: String) -> [String]? {
    let result = runProcess(
      executable: "/usr/sbin/diskutil", arguments: ["apfs", "list", "-plist", container])
    guard result.succeeded, let data = result.stdout.data(using: .utf8),
      let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        as? [String: Any],
      let containers = plist["Containers"] as? [[String: Any]]
    else { return nil }

    for containerInfo in containers {
      for volume in containerInfo["Volumes"] as? [[String: Any]] ?? [] {
        if let volumeUUID = volume["APFSVolumeUUID"] as? String,
          volumeUUID.caseInsensitiveCompare(uuid) == .orderedSame
        {
          return volume["Roles"] as? [String] ?? []
        }
      }
    }
    return nil
  }

  private func diskInfo(for deviceIdentifier: String) -> [String: Any]? {
    guard !deviceIdentifier.isEmpty else { return nil }
    let result = runProcess(
      executable: "/usr/sbin/diskutil",
      arguments: ["info", "-plist", deviceIdentifier])
    guard result.succeeded, let data = result.stdout.data(using: .utf8) else { return nil }
    return try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
      as? [String: Any]
  }
}
