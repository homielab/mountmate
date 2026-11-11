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
  /// Mount the share read-only (MNT_RDONLY / NFS `rdonly`), so nothing on
  /// it can be changed or deleted from this Mac, e.g. a backup share.
  var readOnly: Bool
  /// NFS only: mount `soft` with short timeouts, so a server that stops
  /// answering makes file calls fail instead of hanging Finder and apps
  /// (`NetworkMountPlan.nfsSoftMountOptions`). Ignored for SMB/AFP.
  var softMount: Bool

  init(
    id: UUID = UUID(), name: String, server: String, sharePath: String, username: String,
    mountAtLogin: Bool = true, keepMounted: Bool = true, shareProtocol: ShareProtocol = .smb,
    customMountPoint: String? = nil, readOnly: Bool = false, softMount: Bool = false
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
    self.readOnly = readOnly
    self.softMount = softMount
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, server, sharePath, username, mountAtLogin, keepMounted, shareProtocol,
      customMountPoint, readOnly, softMount
  }

  /// Keeps shares saved before 5.18 decodable: missing flags fall back to the
  /// historical behavior (login shares were the only auto-mounted ones,
  /// every share was SMB, and every share mounted writable and hard).
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
    readOnly = try container.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
    // Shares saved before soft mounts existed keep mounting hard, as before.
    softMount = try container.decodeIfPresent(Bool.self, forKey: .softMount) ?? false
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
  /// An IPv6 zone pasted URL-encoded (`fe80::1%25en0`) comes back as
  /// `fe80::1%en0`; the connection URL encodes it again.
  static func hostAndPort(fromServer raw: String) -> (host: String, port: Int?) {
    var address = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    if let at = address.lastIndex(of: "@") {
      address = address[address.index(after: at)...]
    }
    if address.hasPrefix("["), let close = address.firstIndex(of: "]") {
      let host = address[address.index(after: address.startIndex)..<close]
      let rest = address[address.index(after: close)...]
      let port = rest.hasPrefix(":") ? Int(rest.dropFirst()) : nil
      return (decodedZone(String(host)), port)
    }
    let colons = address.filter { $0 == ":" }.count
    if colons == 1, let colon = address.firstIndex(of: ":"),
      let port = Int(address[address.index(after: colon)...])
    {
      return (String(address[..<colon]), port)
    }
    return (colons > 1 ? decodedZone(String(address)) : String(address), nil)
  }

  /// `fe80::1%25en0` (a zone as written in a URL, RFC 6874) → `fe80::1%en0`.
  private static func decodedZone(_ ipv6: String) -> String {
    guard let range = ipv6.range(of: "%25") else { return ipv6 }
    return ipv6.replacingCharacters(in: range, with: "%")
  }

  /// What is wrong with a server address, see `serverValidationError`.
  enum ServerAddressProblem: Equatable, Sendable {
    /// Not a host name, IPv4 address or IPv6 address (spaces, `/`, `?`…).
    case invalidHost
    /// A `:port` that is not a number from 1 to 65535.
    case invalidPort
  }

  /// Checks a server field: a host name or IPv4 address, optionally with
  /// `:port`; a bare IPv6 address, or one in brackets with `[…]:port`. An
  /// IPv6 link-local zone (`fe80::1%en0`, or URL-encoded `%25en0`) is kept.
  /// A `user@` prefix left by an older version is ignored.
  static func serverAddressProblem(_ raw: String) -> ServerAddressProblem? {
    var address = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    if let at = address.lastIndex(of: "@") {
      address = address[address.index(after: at)...]
    }
    let portText: Substring?
    if address.hasPrefix("[") {
      guard let close = address.firstIndex(of: "]"),
        isIPv6Address(address[address.index(after: address.startIndex)..<close])
      else { return .invalidHost }
      let rest = address[address.index(after: close)...]
      guard rest.isEmpty || rest.hasPrefix(":") else { return .invalidHost }
      portText = rest.isEmpty ? nil : rest.dropFirst()
    } else {
      let colons = address.filter { $0 == ":" }.count
      if colons > 1 {
        return isIPv6Address(address) ? nil : .invalidHost
      }
      let colon = address.firstIndex(of: ":")
      guard isHostName(colon.map { address[..<$0] } ?? address) else { return .invalidHost }
      portText = colon.map { address[address.index(after: $0)...] }
    }
    if let portText {
      guard !portText.isEmpty, portText.allSatisfy({ $0.isASCII && $0.isNumber }),
        let port = Int(portText), (1...65_535).contains(port)
      else { return .invalidPort }
    }
    return nil
  }

  /// The user-facing reason a server field cannot be saved, or nil.
  static func serverValidationError(_ raw: String) -> String? {
    switch serverAddressProblem(raw) {
    case nil:
      return nil
    case .invalidHost:
      return NSLocalizedString(
        "The server address is not valid. Enter a host name or IP address, optionally followed by “:port”.",
        comment: "Network share validation error")
    case .invalidPort:
      return NSLocalizedString(
        "The server port must be a number from 1 to 65535.",
        comment: "Network share validation error")
    }
  }

  /// Letters, digits, "-", "_" and "." (host names, IPv4 addresses and
  /// internationalized names); no spaces or URL punctuation.
  private static func isHostName(_ host: Substring) -> Bool {
    guard host.contains(where: { $0.isLetter || $0.isNumber }) else { return false }
    return host.unicodeScalars.allSatisfy { scalar in
      if scalar.isASCII {
        return CharacterSet.alphanumerics.contains(scalar) || "-_.".unicodeScalars.contains(scalar)
      }
      return CharacterSet.alphanumerics.contains(scalar)
    }
  }

  /// An IPv6 address, with an optional zone (`%en0` or URL-encoded `%25en0`).
  private static func isIPv6Address(_ text: Substring) -> Bool {
    let parts = decodedZone(String(text)).split(
      separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
    if parts.count == 2 {
      let zone = parts[1]
      guard !zone.isEmpty,
        zone.unicodeScalars.allSatisfy({
          $0.isASCII
            && (CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0))
        })
      else { return false }
    }
    var address = in6_addr()
    return inet_pton(AF_INET6, String(parts[0]), &address) == 1
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

  /// Whether both shares connect to the same protocol, server, port (the
  /// protocol's default port = none) and share path.
  func hasSameEndpoint(as other: NetworkShare) -> Bool {
    shareProtocol == other.shareProtocol
      && MountedNetworkShare.endpoint(for: self) == MountedNetworkShare.endpoint(for: other)
  }
}
