//  Created by homielab.com

import Foundation

/// The `diskutil` lookups a new /etc/fstab rule needs: whether a volume may
/// get a custom mount point or a startup-block rule, and its file-system type. The decisions
/// themselves are in `FstabRules`. Not thread-safe: `PersistenceManager`
/// only uses it on the startup-block queue.
final class FstabVolumeLookup {
  /// Runs `executable` with `arguments`; tests pass a fake.
  typealias Runner = (String, [String]) -> ProcessResult

  private let runner: Runner

  init(
    runner: @escaping Runner = { executable, arguments in
      runProcess(executable: executable, arguments: arguments)
    }
  ) {
    self.runner = runner
  }

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

  /// Whether `volume` may get a custom mount point rule, and the file-system
  /// type to write in it.
  func customMountPointFileSystem(for volume: Volume) -> FstabRules.CustomMountPointFileSystem {
    let plist = diskInfo(for: volume.deviceIdentifier)
    return FstabRules.customMountPointFileSystem(plist: plist, fallback: volume.fileSystemType)
  }

  /// APFS roles of a volume, or nil when they cannot be determined.
  private func apfsRoles(forVolumeUUID uuid: String, container: String) -> [String]? {
    let result = runner(
      "/usr/sbin/diskutil", ["apfs", "list", "-plist", container])
    guard result.succeeded,
      let plist = PlistDecoding.decode(result.stdout, context: "diskutil apfs list"),
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
    let result = runner(
      "/usr/sbin/diskutil", ["info", "-plist", deviceIdentifier])
    guard result.succeeded else { return nil }
    return PlistDecoding.decode(result.stdout, context: "diskutil info")
  }
}
