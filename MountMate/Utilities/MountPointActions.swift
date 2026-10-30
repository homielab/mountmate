//  Created by homielab.com

import AppKit

/// Actions on the folder a volume or network share is mounted at.
enum MountPointActions {
  static let terminalBundleIdentifier = "com.apple.Terminal"

  /// Puts the plain path on the general pasteboard.
  static func copyPath(_ path: String, to pasteboard: NSPasteboard = .general) {
    pasteboard.clearContents()
    pasteboard.setString(path, forType: .string)
  }

  /// Opens a Terminal window whose working directory is `path`.
  static func openInTerminal(_ path: String) {
    guard
      let terminal = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: terminalBundleIdentifier)
    else {
      Log.app.error("Terminal.app not found")
      reportTerminalFailure(path)
      return
    }
    NSWorkspace.shared.open(
      [URL(fileURLWithPath: path, isDirectory: true)], withApplicationAt: terminal,
      configuration: NSWorkspace.OpenConfiguration()
    ) { _, error in
      if let error {
        Log.app.error("Open in Terminal failed: \(error.localizedDescription, privacy: .private)")
        DispatchQueue.main.async { reportTerminalFailure(path) }
      }
    }
  }

  /// Main thread. Says the Terminal window could not be opened instead of
  /// doing nothing.
  private static func reportTerminalFailure(_ path: String) {
    DriveManager.shared.userActionError = AppAlert(
      title: NSLocalizedString(
        "Could Not Open Terminal", comment: "Alert title: Open in Terminal failed"),
      message: String(
        format: NSLocalizedString(
          "MountMate could not open a Terminal window at “%@”. Check that Terminal is installed and MountMate may control it.",
          comment: "Alert message: Open in Terminal failed; %@ is the folder path"), path),
      kind: .basic)
  }
}
