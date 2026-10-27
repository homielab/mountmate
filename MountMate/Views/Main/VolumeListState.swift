//  Created by homielab.com

import Foundation

/// Where a volume row is listed. A pinned volume appears twice (under
/// Pinned and under its disk); the context keeps the two rows apart.
enum VolumeRowContext: String {
  case pinned
  case disk
}

/// A volume's settings-derived row state.
struct VolumeRowState: Equatable {
  var isPinned = false
  var isKeepAlive = false
  var isReconnecting = false
  var customMountPoint: String?
  /// A password for this (APFS) volume is saved in the Keychain.
  var hasSavedPassword = false
  /// On an external physical disk, so "Unmount When Idle" applies.
  var canUnmountWhenIdle = false
  /// "Unmount When Idle" timeout in minutes; 0 = off.
  var idleUnmountMinutes = 0
  /// Set when the volume is almost full (see `LowSpaceRules`).
  var lowSpace: LowSpaceRules.Warning?
  /// On an external physical disk (not internal, not a disk image).
  var isExternalDisk = false
  /// Currently being verified by `diskutil verifyVolume`.
  var isVerifying = false
}

/// Row state for the whole list, computed once per list render by
/// `DriveListView`. Rows get plain values instead of each observing
/// PersistenceManager, KeepAliveManager, DriveManager and the editor, so a
/// change only redraws the rows whose values actually changed.
struct VolumeListState: Equatable {
  var rowStates: [String: VolumeRowState] = [:]
  /// `DriveManager.busyVolumeIDs`: volumes with a mount/unmount in flight.
  var busyVolumeIDs: Set<String> = []
  var expandedEditorRowID: String?

  func rowState(for volume: Volume) -> VolumeRowState {
    rowStates[volume.id] ?? VolumeRowState()
  }

  func isEditorExpanded(for volume: Volume, context: VolumeRowContext) -> Bool {
    expandedEditorRowID == VolumeRowView.editorRowID(for: volume, context: context)
  }
}
