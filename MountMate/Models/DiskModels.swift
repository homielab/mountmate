//  Created by homielab.com

import Foundation

enum PhysicalDiskType: Equatable {
  case internalDisk
  case physical
  case diskImage
}

enum DriveCategory: Equatable {
  case user
  case system
}

enum DiskTopology {
  static func isRAIDMaster(_ info: [String: Any]?) -> Bool {
    guard let info else { return false }
    if let value = info["RAIDMaster"] as? Bool { return value }
    if let value = info["RAIDMaster"] as? String {
      return ["yes", "true"].contains(value.lowercased())
    }
    return false
  }

  static func isRAIDMember(_ info: [String: Any]?) -> Bool {
    guard let info, !isRAIDMaster(info) else { return false }
    if let value = info["RAIDMember"] as? Bool { return value }
    if let value = info["RAIDMember"] as? String {
      return ["yes", "true"].contains(value.lowercased())
    }
    // On some macOS releases a member identifies its master by BSD name.
    if let master = info["RAIDMaster"] as? String, master.hasPrefix("disk") { return true }
    return false
  }

  static func isTimeMachineVolume(_ volume: [String: Any]) -> Bool {
    if let role = volume["APFSVolumeRole"] as? String,
      role.localizedCaseInsensitiveContains("backup")
    {
      return true
    }
    return (volume["VolumeName"] as? String) == "Backups.backupdb"
  }
}

struct APFSSnapshot: Identifiable, Hashable {
  let id: String  // UUID
  let name: String
}

struct Volume: Identifiable, Hashable {
  let id: String  // UUID
  let deviceIdentifier: String
  let diskUUID: String?
  let name: String
  let isMounted: Bool
  let mountPoint: String?
  let freeSpace: String?
  let totalSize: String?
  let usedSpace: String?
  let usedBytes: Int64?
  let fileSystemType: String?
  let usagePercentage: Double?
  let category: DriveCategory
  var isProtected: Bool
  var snapshots: [APFSSnapshot]

  var storageError: String?

  var compositeId: String? {
    let dUUID = diskUUID ?? "NONE"
    return "\(dUUID)-\(id)"
  }

  var managedVolumeInfo: ManagedVolumeInfo? {
    guard compositeId != nil else { return nil }
    return ManagedVolumeInfo(
      volumeUUID: id,
      diskUUID: diskUUID ?? "NONE",
      name: name
    )
  }
}

struct APFSContainer: Identifiable, Hashable {
  let id: String  // deviceIdentifier
  var volumes: [Volume]
}

struct PhysicalDisk: Identifiable {
  let id: String  // deviceIdentifier
  let diskUUID: String?
  let connectionType: String
  let name: String?
  let totalSize: String?
  let freeSpace: String?
  let usedSpace: String?
  let usagePercentage: Double?
  let type: PhysicalDiskType
  let isRAIDSet: Bool

  var partitions: [Volume]
  var containers: [APFSContainer]

  var storageError: String?

  var hasVisibleContent: Bool {
    !partitions.isEmpty || containers.contains { !$0.volumes.isEmpty }
  }

  var allVolumes: [Volume] {
    partitions + containers.flatMap(\.volumes)
  }

  var isRemovable: Bool {
    type == .physical || type == .diskImage
  }
}
