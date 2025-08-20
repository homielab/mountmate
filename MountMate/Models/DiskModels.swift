//  Created by homielab.com

import Foundation

struct APFSSnapshot: Identifiable, Hashable {
  let id: String  // UUID of the snapshot
  let name: String
}

struct Volume: Identifiable, Hashable {
  let id: String  // VolumeUUID
  let deviceIdentifier: String  // e.g., disk4s1
  let diskUUID: String?
  let name: String
  let isMounted: Bool
  let mountPoint: String?
  let freeSpace: String?
  let totalSize: String?
  let usedSpace: String?
  let usedBytes: Int64?
  let usagePercentage: Double?
  var storageError: String?
  let fileSystemType: String?
  let category: DriveCategory
  var isProtected: Bool

  var snapshots: [APFSSnapshot]

  var compositeId: String? {
    guard let diskUUID = diskUUID else { return nil }
    return "\(diskUUID)-\(id)"
  }
}

struct APFSContainer: Identifiable, Hashable {
  let id: String  // // e.g., disk1
  var volumes: [Volume]
}

struct PhysicalDisk: Identifiable {
  let id: String  // e.g., disk4
  let diskUUID: String?
  let connectionType: String
  let name: String?
  let totalSize: String?
  let freeSpace: String?
  let usedSpace: String?
  var storageError: String?
  let usagePercentage: Double?
  let type: PhysicalDiskType

  var partitions: [Volume]
  var containers: [APFSContainer]
}

enum PhysicalDiskType { case internalDisk, physical, diskImage }
enum DriveCategory { case user, system }
