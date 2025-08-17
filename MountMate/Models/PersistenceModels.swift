//  Created by homielab.com

import Foundation

struct ManagedVolumeInfo: Codable, Hashable, Identifiable {
    let id: String // The persistent DiskUUID
    let name: String // The last-known name of the volume
}
