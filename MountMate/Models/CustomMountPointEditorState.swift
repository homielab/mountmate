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
  weak var hostWindow: NSWindow?

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
