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
  /// No longer written or read (security-scoped bookmarks were never used).
  /// Kept so entries saved by older versions still decode.
  var bookmarkData: Data? = nil

  var id: String {
    "\(backingDiskIdentifier)-\(volumeUUID)"
  }
}

/// "Unmount When Idle" setting of one volume (see `IdleUnmountManager`).
struct IdleUnmountVolume: Codable, Hashable, Identifiable {
  let volumeUUID: String
  let diskUUID: String
  let name: String  // The last-known name of the volume
  /// Minutes without disk activity before the volume is unmounted; 0 = off.
  var minutes: Int

  var id: String {
    "\(diskUUID)-\(volumeUUID)"
  }

  init(volumeUUID: String, diskUUID: String, name: String, minutes: Int) {
    self.volumeUUID = volumeUUID
    self.diskUUID = diskUUID
    self.name = name
    self.minutes = minutes
  }

  init(info: ManagedVolumeInfo, minutes: Int) {
    self.init(
      volumeUUID: info.volumeUUID, diskUUID: info.diskUUID, name: info.name, minutes: minutes)
  }

  /// An entry without `minutes` decodes as off instead of failing.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    volumeUUID = try container.decode(String.self, forKey: .volumeUUID)
    diskUUID = try container.decode(String.self, forKey: .diskUUID)
    name = try container.decode(String.self, forKey: .name)
    minutes = max(0, try container.decodeIfPresent(Int.self, forKey: .minutes) ?? 0)
  }
}
