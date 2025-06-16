//
//  Created by homielab
//

import Foundation


enum DriveType {
    case userVolume
    case systemPartition
}

struct Drive: Identifiable, Hashable {
    let id: String
    let name: String
    let deviceIdentifier: String
    let isMounted: Bool
    let mountPoint: String?
    let freeSpace: String?
    let totalSize: String?
    let fileSystemType: String?
    let usagePercentage: Double?
    let type: DriveType
}
