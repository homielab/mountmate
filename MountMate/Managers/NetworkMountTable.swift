//  Created by homielab.com

import Foundation

/// Reading the kernel's network mounts: which saved share each mount is,
/// which mounts MountMate did not make, and where a share lives right now.
/// Pure functions over `MountedNetworkShare` values (see `MountTable` for
/// the system call), so they are testable without a mounted share.
enum NetworkMountTable {
  /// The outcome of reading the mount table against the saved shares.
  struct Parsed: Equatable {
    var mountedShareIDs = Set<UUID>()
    /// Shares connected outside MountMate (Finder, Terminal…).
    var manualShares = [NetworkShare]()
    /// Where each saved and manually connected share is mounted.
    var mountPoints = [UUID: String]()
    /// Shares whose current mount is read-only.
    var readOnlyShareIDs = Set<UUID>()
  }

  /// Splits `mountedShares` into saved shares and manual connections.
  /// `manualShareCache` keeps the same `NetworkShare` (and ID) for a manual
  /// mount while it stays mounted at its path; entries of unmounted shares
  /// are dropped.
  static func parse(
    _ mountedShares: [MountedNetworkShare], savedShares: [NetworkShare],
    owners: [UUID?], manualShareCache: inout [String: NetworkShare],
    localize: (String) -> String = { NSLocalizedString($0, comment: "Imported network share") }
  ) -> Parsed {
    var parsed = Parsed()
    var currentManualMountPoints = Set<String>()

    for (index, mountedShare) in mountedShares.enumerated() {
      if let ownerID = owners[index],
        let savedShare = savedShares.first(where: { $0.id == ownerID })
      {
        parsed.mountedShareIDs.insert(savedShare.id)
        if parsed.mountPoints[savedShare.id] == nil {
          parsed.mountPoints[savedShare.id] = mountedShare.mountPoint
          if mountedShare.isReadOnly { parsed.readOnlyShareIDs.insert(savedShare.id) }
        }
        continue
      }
      currentManualMountPoints.insert(mountedShare.mountPoint)
      let manualShare =
        manualShareCache[mountedShare.mountPoint]
        ?? importedShare(from: mountedShare, localize: localize)
      manualShareCache[mountedShare.mountPoint] = manualShare
      parsed.manualShares.append(manualShare)
      parsed.mountPoints[manualShare.id] = mountedShare.mountPoint
      if mountedShare.isReadOnly { parsed.readOnlyShareIDs.insert(manualShare.id) }
    }

    manualShareCache = manualShareCache.filter { currentManualMountPoints.contains($0.key) }
    return parsed
  }

  /// Resolves a Finder URL dropped anywhere inside a mounted share back to
  /// its network share.
  static func manualShare(
    containing url: URL, in manualShares: [NetworkShare], mountPoints: [UUID: String]
  ) -> NetworkShare? {
    let droppedPath = url.standardizedFileURL.path
    return manualShares.first { share in
      guard let mountPoint = mountPoints[share.id] else { return false }
      let mountedPath = URL(fileURLWithPath: mountPoint).standardizedFileURL.path
      return droppedPath == mountedPath || droppedPath.hasPrefix(mountedPath + "/")
    }
  }

  /// The mounts in `mountTable` that are `share`, attributed against
  /// `savedShares` (with `share` itself up to date).
  static func mounts(
    of share: NetworkShare, in mountTable: [MountedNetworkShare],
    savedShares: [NetworkShare], adoptions: [UUID: ShareAdoption.Adoption]
  ) -> [MountedNetworkShare] {
    var shares = savedShares
    if let index = shares.firstIndex(where: { $0.id == share.id }) {
      shares[index] = share
    } else {
      shares.append(share)
    }
    let owners = ShareAdoption.attributeMounts(mountTable, to: shares, adoptions: adoptions).owners
    return mountTable.indices.filter { owners[$0] == share.id }.map { mountTable[$0] }
  }

  /// Where `share` is mounted according to `shareMounts` (its mounts from a
  /// fresh mount table), or nil if it is not mounted. Prefers `lastKnown`
  /// (from the last refresh) when the share is still mounted there.
  static func liveMountPoint(of shareMounts: [MountedNetworkShare], lastKnown: String?)
    -> String?
  {
    if let lastKnown,
      let mount = shareMounts.first(where: { samePath($0.mountPoint, lastKnown) })
    {
      return mount.mountPoint
    }
    return shareMounts.first?.mountPoint
  }

  /// `NetworkMountManager.configuredMountPoint(for:)` with the home folder passed in: a relative
  /// custom path is taken from `homeDirectory`.
  static func configuredMountPoint(for share: NetworkShare, homeDirectory homeDir: String)
    -> String
  {
    if let customPath = share.customMountPoint, !customPath.isEmpty {
      let expandedPath = (customPath as NSString).expandingTildeInPath
      if !expandedPath.hasPrefix("/") {
        return "\(homeDir)/\(expandedPath)"
      } else {
        return expandedPath
      }
    } else {
      let mountsDir = "\(homeDir)/mountmate"
      return "\(mountsDir)/\(share.name)"
    }
  }

  /// Whether two mount point paths name the same folder. Compared
  /// case-insensitively (the default APFS volume is case-insensitive), which
  /// errs on the side of treating paths as the same.
  static func samePath(_ lhs: String, _ rhs: String) -> Bool {
    normalizedMountPath(lhs) == normalizedMountPath(rhs)
  }

  private static func normalizedMountPath(_ path: String) -> String {
    var standardized = (path as NSString).standardizingPath
    while standardized.count > 1 && standardized.hasSuffix("/") {
      standardized.removeLast()
    }
    return standardized.lowercased()
  }

  /// Same protocol and share path, whatever the host is called.
  static func hasSameSharePath(_ mounted: MountedNetworkShare, _ share: NetworkShare) -> Bool {
    mounted.shareProtocol == share.shareProtocol
      && mounted.endpoint?.path == MountedNetworkShare.endpoint(for: share).path
  }

  /// The server field for a host and optional port, in the form
  /// `NetworkShare.hostAndPort(fromServer:)` reads back: `nas:8445`, and an
  /// IPv6 host in brackets when a port follows (`[fd00::2]:8445`).
  static func serverField(host rawHost: String, port: Int?) -> String {
    var host = rawHost
    if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
    guard let port, !host.isEmpty else { return host }
    return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
  }

  /// The share MountMate offers to import for a mount it did not make:
  /// server, share path and user from the mount source (`server:/export`
  /// for NFS, `//[user@]server[:port]/share` for SMB and AFP), named after the last
  /// path component. When the source cannot be read, the server is
  /// "Unknown Server" and the share path the mount folder's name (or
  /// "Shared Folder"). `localize` is replaceable so tests are independent of
  /// the system language.
  static func importedShare(
    from mountedShare: MountedNetworkShare,
    localize: (String) -> String = { NSLocalizedString($0, comment: "Imported network share") }
  ) -> NetworkShare {
    var username = ""
    var server = ""
    var sharePath = ""
    var secure = true

    switch mountedShare.shareProtocol {
    case .nfs:
      // NFS sources look like `server:/export/path` or `[v6addr]:/export`.
      var rest = Substring(mountedShare.source)
      if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
        server = String(rest[rest.index(after: rest.startIndex)..<close])
        rest = rest[rest.index(after: close)...]
      } else if let colon = rest.firstIndex(of: ":") {
        server = String(rest[..<colon])
        rest = rest[colon...]
      } else {
        server = String(rest)
        rest = ""
      }
      if rest.hasPrefix(":") { rest = rest.dropFirst() }
      sharePath = rest.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    case .webdav:
      if let url = URL(string: mountedShare.source) {
        username = url.user ?? ""
        server = Self.serverField(host: url.host ?? "", port: url.port)
        sharePath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        secure = url.scheme?.lowercased() != "http"
      }
    case .smb, .afp:
      let urlString = mountedShare.source.replacingOccurrences(
        of: "//", with: "\(mountedShare.shareProtocol.urlScheme)://")
      if let url = URL(string: urlString) {
        username = url.user ?? ""
        server = Self.serverField(host: url.host ?? "", port: url.port)
        sharePath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      }
    }

    if server.isEmpty {
      server = localize("Unknown Server")
    }
    if sharePath.isEmpty {
      let folder = (mountedShare.mountPoint as NSString).lastPathComponent
      sharePath = folder.isEmpty || folder == "/" ? localize("Shared Folder") : folder
    }

    // The last path component, so the name (the default mount folder if
    // imported) never contains "/" ("volume1/data" → "data").
    let name = sharePath.split(separator: "/").last.map(String.init) ?? sharePath
    return NetworkShare(
      name: name,
      server: server,
      sharePath: sharePath,
      username: username,
      mountAtLogin: false,
      keepMounted: false,
      shareProtocol: mountedShare.shareProtocol,
      // Not the current mount path: if this share is imported, its later
      // mounts must use MountMate's default user-owned location (e.g. not
      // /Volumes/public, which needs admin rights). The current location is
      // tracked in `mountPointsByShareID`.
      customMountPoint: nil,
      readOnly: mountedShare.isReadOnly,
      secure: secure
    )
  }
}
