//  Created by homielab.com

import Foundation

struct ManagedVolumeInfo: Codable, Hashable, Identifiable {
  let volumeUUID: String
  let diskUUID: String
  let name: String  // The last-known name of the volume

  var id: String {
    "\(diskUUID)-\(volumeUUID)"
  }
}

struct VolumeCustomMountPoint: Codable, Hashable, Identifiable {
  let volumeUUID: String
  let backingDiskIdentifier: String
  let name: String
  var mountPoint: String
  var bookmarkData: Data?

  var id: String {
    "\(backingDiskIdentifier)-\(volumeUUID)"
  }
}
