//  Created by homielab.com

import Foundation

struct ManagedVolumeInfo: Codable, Hashable, Identifiable {
    let id: String // The persistent VolumeUUID
    let name: String // The last-known name of the volume
}
