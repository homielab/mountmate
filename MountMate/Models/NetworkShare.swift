//  Created by homielab.com

import Foundation

struct NetworkShare: Identifiable, Codable, Hashable {
  let id: UUID
  var name: String
  var server: String
  var sharePath: String
  var username: String
  var mountAtLogin: Bool
  /// Automatically remount this share whenever it drops unexpectedly, after
  /// network changes, on wake, and at login.
  var keepMounted: Bool
  var shareProtocol: ShareProtocol
  var customMountPoint: String?

  init(
    id: UUID = UUID(), name: String, server: String, sharePath: String, username: String,
    mountAtLogin: Bool = true, keepMounted: Bool = true, shareProtocol: ShareProtocol = .smb,
    customMountPoint: String? = nil
  ) {
    self.id = id
    self.name = name
    self.server = server
    self.sharePath = sharePath
    self.username = username
    self.mountAtLogin = mountAtLogin
    self.keepMounted = keepMounted
    self.shareProtocol = shareProtocol
    self.customMountPoint = customMountPoint
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, server, sharePath, username, mountAtLogin, keepMounted, shareProtocol,
      customMountPoint
  }

  /// Keeps shares saved before 5.18 decodable: missing flags fall back to the
  /// historical behavior (login shares were the only auto-mounted ones, and
  /// every share was SMB).
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    server = try container.decode(String.self, forKey: .server)
    sharePath = try container.decode(String.self, forKey: .sharePath)
    username = try container.decode(String.self, forKey: .username)
    mountAtLogin = try container.decode(Bool.self, forKey: .mountAtLogin)
    keepMounted = try container.decodeIfPresent(Bool.self, forKey: .keepMounted) ?? mountAtLogin
    shareProtocol =
      try container.decodeIfPresent(ShareProtocol.self, forKey: .shareProtocol)
      ?? .smb
    customMountPoint = try container.decodeIfPresent(String.self, forKey: .customMountPoint)
  }
}

// MARK: - Input Cleanup & Validation

extension NetworkShare {
  /// Cleans up a server address typed or pasted by the user: trims
  /// whitespace and drops a leading `smb://`, `afp://` or `nfs://` and any
  /// trailing slashes.
  static func cleanedServerInput(_ raw: String) -> String {
    var server = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    for scheme in ShareProtocol.allCases.map({ "\($0.urlScheme)://" }) {
      if server.lowercased().hasPrefix(scheme) {
        server = String(server.dropFirst(scheme.count))
        break
      }
    }
    while server.hasSuffix("/") { server.removeLast() }
    return server.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Why `name` cannot be used as a display name, or nil if it can. Without
  /// a custom mount point the name is the mount folder under ~/mountmate, so
  /// it must be a single path component.
  static func displayNameValidationError(_ name: String) -> String? {
    if name.contains("/") {
      return NSLocalizedString(
        "The display name cannot contain “/”.", comment: "Network share validation error")
    }
    if name == "." || name == ".." {
      return NSLocalizedString(
        "The display name cannot be “.” or “..”.", comment: "Network share validation error")
    }
    return nil
  }

  /// Whether both shares connect to the same protocol, server and share path.
  func hasSameEndpoint(as other: NetworkShare) -> Bool {
    shareProtocol == other.shareProtocol
      && MountedNetworkShare.endpoint(for: self) == MountedNetworkShare.endpoint(for: other)
  }
}
