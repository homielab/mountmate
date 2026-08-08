//  Created by homielab.com

import AppKit
import SwiftUI

final class CustomMountPointEditorState: ObservableObject {
  static let shared = CustomMountPointEditorState()

  @Published var expandedVolumeID: String?
  @Published var mountPointPath = ""
  @Published var inlineError: String?
  @Published var pendingSavePath: String?
  @Published var selectedFolderURL: URL?
  @Published var showCreateDirectoryAlert = false
  @Published var showNonEmptyDirectoryAlert = false
  @Published var isChoosingFolder = false
  weak var hostWindow: NSWindow?

  func sync(from persistedPath: String?) {
    mountPointPath = persistedPath ?? ""
    inlineError = nil
    pendingSavePath = nil
    selectedFolderURL = nil
    showCreateDirectoryAlert = false
    showNonEmptyDirectoryAlert = false
    isChoosingFolder = false
  }

  func collapse() {
    expandedVolumeID = nil
    inlineError = nil
    pendingSavePath = nil
    selectedFolderURL = nil
    showCreateDirectoryAlert = false
    showNonEmptyDirectoryAlert = false
    isChoosingFolder = false
  }
}
