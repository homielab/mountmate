//  Created by homielab.com

import Foundation

/// Network file-sharing protocols MountMate can mount and keep alive.
enum ShareProtocol: String, Codable, CaseIterable, Identifiable, Sendable {
  case smb
  case nfs
  case afp
  /// WebDAV over HTTP(S), mounted by NetFS through macOS's `webdavfs`.
  case webdav

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .smb: return "SMB"
    case .nfs: return "NFS"
    case .afp: return "AFP"
    case .webdav: return "WebDAV"
    }
  }

  /// URL scheme used when building connection strings for this protocol.
  var urlScheme: String {
    switch self {
    case .smb: return "smb"
    case .nfs: return "nfs"
    case .afp: return "afp"
    case .webdav: return "https"
    }
  }

  /// Filesystem type (`f_fstypename`, as `/sbin/mount` prints it) of mounts of this protocol.
  var mountFilesystemName: String {
    switch self {
    case .smb: return "smbfs"
    case .nfs: return "nfs"
    case .afp: return "afpfs"
    case .webdav: return "webdav"
    }
  }

  /// The port a server listens on when its address names none. WebDAV: the
  /// HTTPS port; the HTTP port 80 counts as a default too
  /// (`MountedNetworkShare.nonDefaultPort`).
  var defaultPort: Int {
    switch self {
    case .smb: return 445
    case .nfs: return 2049
    case .afp: return 548
    case .webdav: return 443
    }
  }

  /// Whether the protocol uses a username and password (passed to NetFS).
  var supportsUserCredentials: Bool {
    switch self {
    case .smb, .afp, .webdav: return true
    case .nfs: return false
    }
  }

  /// Protocols offered when creating a new share. AFP is omitted because Apple
  /// has removed AFP client support in modern macOS versions.
  static let creationCases: [ShareProtocol] = [.smb, .nfs, .webdav]

  /// Whether this protocol is deprecated on modern macOS versions.
  var isDeprecated: Bool {
    switch self {
    case .afp: return true
    case .smb, .nfs, .webdav: return false
    }
  }

  static func from(mountFilesystemName: String) -> ShareProtocol? {
    switch mountFilesystemName.lowercased() {
    case "smbfs": return .smb
    case "nfs": return .nfs
    case "afpfs": return .afp
    case "webdav": return .webdav
    default: return nil
    }
  }
}
