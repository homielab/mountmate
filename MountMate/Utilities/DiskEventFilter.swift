//  Created by homielab.com

import Foundation

/// Decides whether a mount or unmount notification concerns a local disk.
/// Network shares (SMB, NFS, AFP, WebDAV) post the same notifications, but
/// they never change the disk list, so they must not start `diskutil list`.
enum DiskEventFilter {
  /// File system types of network mounts.
  static let networkFileSystemTypes: Set<String> = ["smbfs", "nfs", "afpfs", "webdav"]

  /// Mount points of the network mounts in the table.
  static func networkMountPoints(in entries: [MountEntry]) -> Set<String> {
    Set(
      entries.filter { networkFileSystemTypes.contains($0.fileSystemType.lowercased()) }
        .map(\.mountPoint))
  }

  /// False only when the event is for a network share. An unmounted share is
  /// no longer in the table, so `knownNetworkMountPoints` (from the previous
  /// table) identifies it. No volume URL, or no readable table → true, so a
  /// real disk is never missed.
  static func isLocalDiskEvent(
    volumeURL: URL?, entries: [MountEntry]?, knownNetworkMountPoints: Set<String>
  ) -> Bool {
    guard let path = volumeURL?.standardizedFileURL.path else { return true }
    if knownNetworkMountPoints.contains(path) { return false }
    guard let entries else { return true }
    return !networkMountPoints(in: entries).contains(path)
  }
}
