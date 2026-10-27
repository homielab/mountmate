//  Created by homielab.com

import Foundation

/// Network file-sharing protocols MountMate can mount and keep alive.
enum ShareProtocol: String, Codable, CaseIterable, Identifiable, Sendable {
  case smb
  case nfs
  case afp

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .smb: return "SMB"
    case .nfs: return "NFS"
    case .afp: return "AFP"
    }
  }

  /// URL scheme used when building connection strings for this protocol.
  var urlScheme: String {
    switch self {
    case .smb: return "smb"
    case .nfs: return "nfs"
    case .afp: return "afp"
    }
  }

  /// Filesystem type (`f_fstypename`, as `/sbin/mount` prints it) of mounts of this protocol.
  var mountFilesystemName: String {
    switch self {
    case .smb: return "smbfs"
    case .nfs: return "nfs"
    case .afp: return "afpfs"
    }
  }

  /// Whether the protocol uses a username and password (passed to NetFS).
  var supportsUserCredentials: Bool {
    switch self {
    case .smb, .afp: return true
    case .nfs: return false
    }
  }

  /// Protocols offered when creating a new share. AFP is omitted because Apple
  /// has removed AFP client support in modern macOS versions.
  static let creationCases: [ShareProtocol] = [.smb, .nfs]

  /// Whether this protocol is deprecated on modern macOS versions.
  var isDeprecated: Bool {
    switch self {
    case .afp: return true
    case .smb, .nfs: return false
    }
  }

  static func from(mountFilesystemName: String) -> ShareProtocol? {
    switch mountFilesystemName.lowercased() {
    case "smbfs": return .smb
    case "nfs": return .nfs
    case "afpfs": return .afp
    default: return nil
    }
  }
}
