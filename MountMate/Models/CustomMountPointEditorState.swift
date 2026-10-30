//  Created by homielab.com

import AppKit
import SwiftUI

final class CustomMountPointEditorState: ObservableObject {
  static let shared = CustomMountPointEditorState()

  /// The list row whose editor is open: `VolumeRowView.editorRowID(...)`.
  /// A pinned volume is listed twice (Pinned and under its disk), so this
  /// names the row, not just the volume.
  @Published var expandedRowID: String?
  @Published var mountPointPath = ""
  @Published var inlineError: String?
  @Published var pendingSavePath: String?
  @Published var showCreateDirectoryAlert = false
  @Published var showNonEmptyDirectoryAlert = false
  @Published var isChoosingFolder = false
  /// Volumes (by `Volume.id`) whose custom mount point save or removal is
  /// still running. Keyed by volume, not row, so the pinned and the disk row
  /// of one volume cannot start a second update. It can finish after the
  /// editor was closed, so this is not reset by `sync` or `collapse`.
  @Published var savingVolumeIDs: Set<String> = []
  /// Folders the editor created for a save that is still running, by
  /// `Volume.id`, deepest first (`CreatedMountPointFolders.missing`). Like
  /// `savingVolumeIDs`, not reset by `sync` or `collapse`.
  private(set) var createdFolders: [String: [String]] = [:]
  weak var hostWindow: NSWindow?

  /// Remembers the folders created for the volume's save that starts now.
  func recordCreatedFolders(_ folders: [String], for volumeID: String) {
    guard !folders.isEmpty else { return }
    createdFolders[volumeID] = folders + (createdFolders[volumeID] ?? [])
  }

  /// The folders to remove once the volume's save finished with `result`:
  /// the ones the editor created, unless the rule was saved. Either way
  /// they are forgotten.
  func foldersToRemove(
    afterSaveOf volumeID: String, result: PersistenceManager.CustomMountPointUpdateResult
  ) -> [String] {
    let folders = createdFolders.removeValue(forKey: volumeID) ?? []
    return result == .success ? [] : folders
  }

  func sync(from persistedPath: String?) {
    mountPointPath = persistedPath ?? ""
    inlineError = nil
    pendingSavePath = nil
    showCreateDirectoryAlert = false
    showNonEmptyDirectoryAlert = false
    isChoosingFolder = false
  }

  func collapse() {
    expandedRowID = nil
    inlineError = nil
    pendingSavePath = nil
    showCreateDirectoryAlert = false
    showNonEmptyDirectoryAlert = false
    isChoosingFolder = false
  }
}
