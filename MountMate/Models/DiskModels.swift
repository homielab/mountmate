//  Created by homielab.com

import Foundation

enum PhysicalDiskType {
  case internalDisk
  case physical
  case diskImage
}

enum DriveCategory {
  case user
  case system
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
    guard let diskUUID = diskUUID else { return nil }
    return "\(diskUUID)-\(id)"
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

  var partitions: [Volume]
  var containers: [APFSContainer]

  var storageError: String?

  var hasVisibleContent: Bool {
    !partitions.isEmpty || containers.contains { !$0.volumes.isEmpty }
  }
}
