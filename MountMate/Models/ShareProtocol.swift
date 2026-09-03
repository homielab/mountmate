//  Created by homielab.com

import Foundation

/// Network file-sharing protocols MountMate can mount and keep alive.
enum ShareProtocol: String, Codable, CaseIterable, Identifiable {
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

  /// Filesystem name reported by `/sbin/mount` for mounts of this protocol.
  var mountFilesystemName: String {
    switch self {
    case .smb: return "smbfs"
    case .nfs: return "nfs"
    case .afp: return "afpfs"
    }
  }

  /// Whether user credentials can be embedded in the mount URL.
  var supportsUserCredentials: Bool {
    switch self {
    case .smb, .afp: return true
    case .nfs: return false
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
