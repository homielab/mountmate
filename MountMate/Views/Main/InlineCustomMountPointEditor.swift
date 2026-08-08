//  Created by homielab.com

import SwiftUI

struct InlineCustomMountPointEditor: View {
  let volume: Volume
  @EnvironmentObject private var driveManager: DriveManager
  @ObservedObject private var persistence = PersistenceManager.shared
  @ObservedObject var editorState: CustomMountPointEditorState
  let onClose: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField(
        NSLocalizedString("Folder Path", comment: "Custom mount point path field"),
        text: $editorState.mountPointPath,
        prompt: Text(
          NSLocalizedString(
            "Custom Mount Point Path Prompt",
            comment: "Custom mount point path placeholder"))
      )
      .textFieldStyle(.roundedBorder)

      HStack(spacing: 8) {
        Button(NSLocalizedString("Choose Folder", comment: "Choose folder button")) {
          chooseFolder()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)

        Button(NSLocalizedString("Default Path", comment: "Default path button")) {
          editorState.mountPointPath = ""
          editorState.inlineError = nil
          editorState.pendingSavePath = nil
          editorState.selectedFolderURL = nil
        }
        .buttonStyle(.bordered)
        .controlSize(.small)

        Spacer()
      }

      Text(
        NSLocalizedString(
          "Custom Mount Point System Helper",
          comment: "Custom mount point helper text")
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .lineLimit(nil)
      .fixedSize(horizontal: false, vertical: true)

      if let inlineError = editorState.inlineError {
        Text(inlineError)
          .font(.caption)
          .foregroundStyle(.red)
          .lineLimit(nil)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack {
        Button(NSLocalizedString("Cancel", comment: "Cancel button")) {
          onClose()
        }
        .buttonStyle(.borderless)

        Spacer()

        Button(NSLocalizedString("Save", comment: "Save button")) {
          save()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
      }
    }
    .padding(12)
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(.rect(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
    )
    .alert(
      NSLocalizedString("Create Folder Title", comment: "Create folder alert title"),
      isPresented: $editorState.showCreateDirectoryAlert
    ) {
      Button(NSLocalizedString("Create", comment: "Create button")) {
        createPendingDirectoryAndSave()
      }
      Button(NSLocalizedString("Cancel", comment: "Cancel button"), role: .cancel) {}
    } message: {
      Text(
        NSLocalizedString(
          "Create Folder Message",
          comment: "Create folder alert message"))
    }
    .alert(
      NSLocalizedString("Folder Not Empty Title", comment: "Non-empty folder alert title"),
      isPresented: $editorState.showNonEmptyDirectoryAlert
    ) {
      Button(NSLocalizedString("Use Folder", comment: "Use folder button")) {
        commitPendingSave()
      }
      Button(NSLocalizedString("Cancel", comment: "Cancel button"), role: .cancel) {}
    } message: {
      Text(
        NSLocalizedString(
          "Folder Not Empty Message",
          comment: "Non-empty folder alert message"))
    }
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = NSLocalizedString("Choose", comment: "Choose button")
    editorState.isChoosingFolder = true

    let currentPath = driveManager.normalizedMountPointPath(editorState.mountPointPath)
    if !currentPath.isEmpty {
      panel.directoryURL = URL(fileURLWithPath: currentPath)
    }

    let completion: (NSApplication.ModalResponse) -> Void = { response in
      defer {
        editorState.isChoosingFolder = false
        NSApp.activate(ignoringOtherApps: true)
      }
      guard response == .OK else { return }
      editorState.mountPointPath = panel.url?.path ?? editorState.mountPointPath
      editorState.selectedFolderURL = panel.url
      editorState.inlineError = nil
    }

    if let hostWindow = editorState.hostWindow {
      panel.beginSheetModal(for: hostWindow, completionHandler: completion)
    } else {
      panel.begin(completionHandler: completion)
    }
  }

  private func save() {
    editorState.inlineError = nil

    let normalizedPath = driveManager.normalizedMountPointPath(editorState.mountPointPath)
    editorState.mountPointPath = normalizedPath

    guard !normalizedPath.isEmpty else {
      if let error = persistence.removeCustomMountPoint(for: volume) {
        editorState.inlineError = error
        return
      }
      if volume.isMounted {
        driveManager.remount(volume: volume)
      }
      onClose()
      return
    }

    if let validationError = driveManager.customMountPointValidationError(
      for: normalizedPath, excluding: volume)
    {
      editorState.inlineError = validationError
      return
    }

    do {
      let directoryState = try driveManager.inspectDirectory(at: normalizedPath)
      editorState.pendingSavePath = normalizedPath
      if editorState.selectedFolderURL?.path != normalizedPath {
        editorState.selectedFolderURL = nil
      }

      if !directoryState.exists {
        editorState.showCreateDirectoryAlert = true
        return
      }

      guard directoryState.isDirectory else {
        editorState.inlineError = NSLocalizedString(
          "Custom Mount Point Must Be Folder",
          comment: "Custom mount point validation")
        return
      }

      if !directoryState.isEmpty {
        editorState.showNonEmptyDirectoryAlert = true
        return
      }

      commitPendingSave()
    } catch {
      editorState.inlineError = String(
        format: NSLocalizedString(
          "Custom Mount Point Inspect Error",
          comment: "Custom mount point validation"), error.localizedDescription)
    }
  }

  private func createPendingDirectoryAndSave() {
    guard let path = editorState.pendingSavePath else { return }

    do {
      try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
      commitPendingSave()
    } catch {
      editorState.inlineError = String(
        format: NSLocalizedString(
          "Custom Mount Point Create Error",
          comment: "Custom mount point validation"), error.localizedDescription)
    }
  }

  private func commitPendingSave() {
    guard let path = editorState.pendingSavePath else { return }
    let selectedFolderURL =
      editorState.selectedFolderURL?.path == path ? editorState.selectedFolderURL : nil
    if let error = persistence.applyCustomMountPoint(
      path, selectedURL: selectedFolderURL, for: volume)
    {
      editorState.inlineError = error
      return
    }
    if volume.isMounted {
      driveManager.remount(volume: volume)
    }
    onClose()
  }
}
