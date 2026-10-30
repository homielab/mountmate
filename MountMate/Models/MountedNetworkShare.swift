//  Created by homielab.com

import Foundation

/// A network mount in the kernel mount table (see `MountTable`), independent
/// of protocol.
struct MountedNetworkShare: Equatable, Sendable {
  let source: String
  let mountPoint: String
  let shareProtocol: ShareProtocol
  /// Mounted read-only (`MNT_RDONLY`), whatever the saved share asks for.
  let isReadOnly: Bool

  init?(source: String, mountPoint: String, fileSystemType: String, isReadOnly: Bool = false) {
    // The filesystem type decides the protocol; a mount point that merely
    // contains "smbfs" in its name is never mistaken for one.
    guard let shareProtocol = ShareProtocol.from(mountFilesystemName: fileSystemType),
      !source.isEmpty, !mountPoint.isEmpty
    else { return nil }
    self.source = source
    self.mountPoint = mountPoint
    self.shareProtocol = shareProtocol
    self.isReadOnly = isReadOnly
  }

  /// A mount table entry, or nil if it is not a network share.
  init?(entry: MountEntry) {
    self.init(
      source: entry.source, mountPoint: entry.mountPoint, fileSystemType: entry.fileSystemType,
      isReadOnly: entry.isReadOnly)
  }

  /// Normalized server + path of a network share, compared exactly (never by
  /// substring, so "nas" does not match "nas2" or "nas.backup.lan").
  struct Endpoint: Equatable, Sendable {
    let host: String
    let path: String
  }

  /// The endpoint this mount is connected to, parsed from its mount source.
  var endpoint: Endpoint? {
    Self.endpoint(fromMountSource: source, shareProtocol: shareProtocol)
  }

  /// True when this mount is the given saved share (same host and share path).
  func matches(_ share: NetworkShare) -> Bool {
    guard let mounted = endpoint, !mounted.host.isEmpty else { return false }
    return mounted == Self.endpoint(for: share)
  }

  /// Parses a mount source (`f_mntfromname`, as `/sbin/mount` prints it):
  /// - SMB/AFP: `//[user[;domain]@]host[:port]/share[/sub]` (percent-encoded)
  /// - NFS: `host:/export/path` or `[v6addr]:/export/path`
  static func endpoint(fromMountSource source: String, shareProtocol: ShareProtocol)
    -> Endpoint?
  {
    switch shareProtocol {
    case .nfs:
      var rest = Substring(source)
      let host: Substring
      if rest.hasPrefix("[") {
        guard let close = rest.firstIndex(of: "]") else { return nil }
        host = rest[rest.index(after: rest.startIndex)..<close]
        rest = rest[rest.index(after: close)...]
        guard rest.hasPrefix(":") else { return nil }
        rest = rest.dropFirst()
      } else {
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        host = rest[..<colon]
        rest = rest[rest.index(after: colon)...]
      }
      return Endpoint(
        host: normalizedHost(String(host)), path: normalizedPath(String(rest), shareProtocol: .nfs))
    case .smb, .afp:
      var rest = Substring(source)
      while rest.hasPrefix("/") { rest = rest.dropFirst() }
      let authority: Substring
      let path: Substring
      if let slash = rest.firstIndex(of: "/") {
        authority = rest[..<slash]
        path = rest[slash...]
      } else {
        authority = rest
        path = ""
      }
      return Endpoint(
        host: normalizedHost(String(authority)),
        path: normalizedPath(String(path), shareProtocol: shareProtocol))
    }
  }

  /// The endpoint a saved share points at, normalized like a mount source.
  static func endpoint(for share: NetworkShare) -> Endpoint {
    Endpoint(
      host: normalizedHost(share.server),
      path: normalizedPath(share.sharePath, shareProtocol: share.shareProtocol))
  }

  /// Reduces a host (as typed by the user or printed in a mount source) to a
  /// comparable form: drops any scheme, path, `user@` and `:port`, removes
  /// IPv6 brackets, percent-decodes, drops a trailing dot and lowercases.
  static func normalizedHost(_ raw: String) -> String {
    var host = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    if let schemeEnd = host.range(of: "://") {
      host = host[schemeEnd.upperBound...]
    }
    while host.hasPrefix("/") { host = host.dropFirst() }
    if let slash = host.firstIndex(of: "/") {
      host = host[..<slash]
    }
    // Usernames are percent-encoded in mount sources, so the last literal
    // "@" always separates user info from the host.
    if let at = host.lastIndex(of: "@") {
      host = host[host.index(after: at)...]
    }

    var result: String
    if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
      result = String(host[host.index(after: host.startIndex)..<close])
    } else if host.filter({ $0 == ":" }).count == 1, let colon = host.firstIndex(of: ":") {
      // `host:port`. A bare IPv6 address has several colons and is kept.
      result = String(host[..<colon])
    } else {
      result = String(host)
    }
    result = result.removingPercentEncoding ?? result
    while result.hasSuffix(".") { result.removeLast() }
    result = result.lowercased()
    // Finder mounts found via Bonjour use the service name
    // ("NAS._smb._tcp.local"): treat it, "nas.local" and "nas" as one host.
    for suffix in ["._smb._tcp.local", "._afpovertcp._tcp.local", ".local"]
    where result.hasSuffix(suffix) {
      result.removeLast(suffix.count)
      break
    }
    return result
  }

  /// Percent-decodes a share path and strips surrounding slashes. SMB/AFP
  /// share names are case-insensitive, so those are lowercased; NFS export
  /// paths are case-sensitive and keep their case.
  static func normalizedPath(_ raw: String, shareProtocol: ShareProtocol) -> String {
    let decoded = raw.removingPercentEncoding ?? raw
    let trimmed = decoded.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    switch shareProtocol {
    case .smb, .afp: return trimmed.lowercased()
    case .nfs: return trimmed
    }
  }
}
