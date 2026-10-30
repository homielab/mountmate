//  Created by homielab.com

import Foundation

/// The folders the custom mount point editor creates for a new mount point,
/// and their removal when the save is cancelled at the password prompt or
/// fails, so no empty folder is left behind.
///
/// Only folders the editor created are ever removed, and only with rmdir(2),
/// which removes nothing but an empty folder and refuses a mount point. Never
/// `FileManager.removeItem`: it is recursive (see `MountPointCleanupRule`).
enum CreatedMountPointFolders {
  /// The folders `createDirectory(atPath:withIntermediateDirectories: true)`
  /// creates for `path`: `path` itself and each missing parent, deepest
  /// first. Empty when `path` already exists.
  static func missing(for path: String, exists: (String) -> Bool) -> [String] {
    var folders: [String] = []
    var current = path
    while current.hasPrefix("/"), current != "/", !exists(current) {
      folders.append(current)
      current = (current as NSString).deletingLastPathComponent
    }
    return folders
  }

  /// Removes `folders` (deepest first, as returned by `missing`). A folder
  /// that no longer exists is skipped. Stops at the first folder that may
  /// not or cannot be removed (something is in it or mounted on it), so a
  /// parent is only removed once its child is gone.
  ///
  /// - Returns: The removed folders.
  static func remove(
    _ folders: [String],
    mountTable: [MountEntry]?,
    exists: (String) -> Bool,
    isMountPoint: (String) -> Bool,
    removeEmptyFolder: (String) -> Bool
  ) -> [String] {
    var removed: [String] = []
    for folder in folders {
      guard exists(folder) else { continue }
      guard
        MountPointCleanupRule.shouldRemove(
          created: true,
          tableReadable: mountTable != nil,
          inMountTable: mountTable?.contains {
            NetworkMountTable.samePath($0.mountPoint, folder)
          } ?? false,
          isMountPoint: isMountPoint(folder)),
        removeEmptyFolder(folder)
      else { break }
      removed.append(folder)
    }
    return removed
  }

  /// `remove` on the real file system, off the main thread (the folder may
  /// sit on a network share that stops answering).
  static func removeInBackground(_ folders: [String]) {
    guard !folders.isEmpty else { return }
    DispatchQueue.global(qos: .utility).async {
      let removed = remove(
        folders,
        mountTable: MountTable.entries(),
        exists: { FileManager.default.fileExists(atPath: $0) },
        isMountPoint: isMountPoint(_:),
        removeEmptyFolder: { rmdir($0) == 0 })
      if removed.count < folders.count {
        Log.persistence.info(
          "Kept \(folders.count - removed.count, privacy: .public) folder(s) created for a custom mount point that was not saved: \(folders.first ?? "", privacy: .private)"
        )
      }
    }
  }

  /// True when another file system is mounted on `path` (its device differs
  /// from its parent's).
  private static func isMountPoint(_ path: String) -> Bool {
    var fileStat = stat()
    var parentStat = stat()
    guard stat(path, &fileStat) == 0,
      stat((path as NSString).deletingLastPathComponent, &parentStat) == 0
    else { return false }
    return fileStat.st_dev != parentStat.st_dev
  }
}
