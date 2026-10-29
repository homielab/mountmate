//  Created by homielab.com

import Foundation

struct NetworkShare: Identifiable, Codable, Hashable, Sendable {
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
  /// whitespace and drops a leading `smb://`, `afp://` or `nfs://`, or a bare
  /// `//` (as in `mount` output). A Windows UNC path (`\\nas\Public`) has its
  /// backslashes turned into slashes first. A pasted
  /// URL such as `smb://admin@nas.local:445/Public/sub` is split into the
  /// server (`nas.local:445`, a port is kept), the share path (`Public/sub`,
  /// percent-decoded and cleaned with `cleanedSharePathInput`) and the
  /// username (`admin`,
  /// percent-decoded; a password after ":" is dropped). The path and the
  /// username are empty when there are none.
  static func cleanedServerInput(_ raw: String) -> (
    server: String, sharePath: String, username: String
  ) {
    var server = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    // Only a UNC path is converted, so a backslash elsewhere (a
    // `DOMAIN\user` login) is left alone.
    if server.hasPrefix("\\\\") {
      server = server.replacingOccurrences(of: "\\", with: "/")
    }
    let prefixes = ShareProtocol.allCases.map { "\($0.urlScheme)://" } + ["//"]
    if let prefix = prefixes.first(where: { server.lowercased().hasPrefix($0) }) {
      server = String(server.dropFirst(prefix.count))
    }
    var sharePath = ""
    if let slash = server.firstIndex(of: "/") {
      // A path pasted from a URL is percent-encoded (`My%20Share` from
      // Finder's Connect to Server); the connection URL encodes it again.
      let pastedPath = String(server[slash...])
      sharePath = cleanedSharePathInput(pastedPath.removingPercentEncoding ?? pastedPath)
      server = String(server[..<slash])
    }
    var username = ""
    // The last "@" ends the user info, so "user@domain.com@nas" keeps its
    // whole login.
    if let at = server.lastIndex(of: "@") {
      let userInfo = server[..<at]
      let user = userInfo.firstIndex(of: ":").map { userInfo[..<$0] } ?? userInfo
      username = String(user).removingPercentEncoding ?? String(user)
      server = String(server[server.index(after: at)...])
    }
    return (
      server.trimmingCharacters(in: .whitespacesAndNewlines), sharePath,
      username.trimmingCharacters(in: .whitespacesAndNewlines)
    )
  }

  /// Splits a saved server field into the host and port to connect to:
  /// `nas:445` → (`nas`, 445), `[fe80::1]:445` → (`fe80::1`, 445). A bare
  /// IPv6 address (`fe80::1`, several colons) has no port, and a `user@`
  /// prefix left by an older version is dropped. The host has no brackets.
  static func hostAndPort(fromServer raw: String) -> (host: String, port: Int?) {
    var address = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    if let at = address.lastIndex(of: "@") {
      address = address[address.index(after: at)...]
    }
    if address.hasPrefix("["), let close = address.firstIndex(of: "]") {
      let host = address[address.index(after: address.startIndex)..<close]
      let rest = address[address.index(after: close)...]
      let port = rest.hasPrefix(":") ? Int(rest.dropFirst()) : nil
      return (String(host), port)
    }
    if address.filter({ $0 == ":" }).count == 1, let colon = address.firstIndex(of: ":"),
      let port = Int(address[address.index(after: colon)...])
    {
      return (String(address[..<colon]), port)
    }
    return (String(address), nil)
  }

  /// Cleans up a share path typed or pasted by the user: trims whitespace and
  /// the leading and trailing slashes (`/Public/` → `Public`), since the
  /// connection URL adds its own "/".
  static func cleanedSharePathInput(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The display name to save for `typed`: trimmed of surrounding
  /// whitespace, or, when nothing is left, the last component of the share
  /// path (the name is the default mount folder, so it must be a single
  /// component).
  static func resolvedDisplayName(_ typed: String, sharePath: String) -> String {
    let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { return trimmed }
    return sharePath.split(separator: "/").last.map(String.init) ?? sharePath
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
