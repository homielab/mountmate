//  Created by homielab.com

import Foundation

struct Volume: Identifiable, Hashable {
    /// The ID of the disk.
    ///
    /// This differs from ``deviceIdentifier`` in that it persists across restarts.
    let diskID: String
    let deviceIdentifier: String // e.g., disk4s1
    let name: String
    let isMounted: Bool
    let mountPoint: String?
    let freeSpace: String?
    let totalSize: String?
    let fileSystemType: String?
    let usagePercentage: Double?
    let category: DriveCategory
    var isProtected: Bool
    let usedSpace: String?

    var id: String {
        diskID
    }
}

enum PhysicalDiskType {
    case internalDisk
    case physical
    case diskImage
}

struct PhysicalDisk: Identifiable {
    let id: String
    let connectionType: String
    var volumes: [Volume]
    let name: String?
    let totalSize: String?
    let freeSpace: String?
    let usagePercentage: Double?
    let type: PhysicalDiskType
    let usedSpace: String?
}

enum DriveCategory: String {
    case user
    case system
}
