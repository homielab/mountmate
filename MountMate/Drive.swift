//
//  Created by homielab
//

import Foundation


enum DriveCategory: String {
    case user
    case system
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
    
    let category: DriveCategory
    let connectionType: String // e.g., "USB", "Disk Image", "Thunderbolt"
}
