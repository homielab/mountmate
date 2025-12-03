//  Created by homielab.com

import Foundation

struct NetworkShare: Identifiable, Codable, Hashable {
  let id: UUID
  var name: String
  var server: String
  var sharePath: String
  var username: String
  var mountAtLogin: Bool
  var customMountPoint: String?

  init(
    id: UUID = UUID(), name: String, server: String, sharePath: String, username: String,
    mountAtLogin: Bool = true, customMountPoint: String? = nil
  ) {
    self.id = id
    self.name = name
    self.server = server
    self.sharePath = sharePath
    self.username = username
    self.mountAtLogin = mountAtLogin
    self.customMountPoint = customMountPoint
  }
}
