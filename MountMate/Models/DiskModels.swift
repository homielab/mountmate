//  Created by homielab.com

import Foundation

struct Volume: Identifiable, Hashable {
    let id: String
    let name: String
    let isMounted: Bool
    let mountPoint: String?
    let freeSpace: String?
    let totalSize: String?
    let fileSystemType: String?
    let usagePercentage: Double?
    let category: DriveCategory
}

enum PhysicalDiskType {
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
}

enum DriveCategory: String {
    case user
    case system
}