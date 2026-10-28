//  Created by homielab.com

import Foundation

/// Decides whether the mount point folder of a failed network mount may be
/// removed.
///
/// Removing the wrong folder deletes the contents of a live network share
/// (issue #71), so every condition must be clear: MountMate created the
/// folder, the mount table could be read, nothing is mounted there according
/// to that table, and the folder is not a mount point. `inMountTable` and
/// `isMountPoint` are only evaluated once the earlier conditions passed:
/// checking for a mount point calls stat(), which can hang on a live network
/// share.
enum MountPointCleanupRule {
  static func shouldRemove(
    created: Bool,
    tableReadable: Bool,
    inMountTable: @autoclosure () -> Bool,
    isMountPoint: @autoclosure () -> Bool
  ) -> Bool {
    guard created, tableReadable else { return false }
    guard !inMountTable() else { return false }
    return !isMountPoint()
  }
}
