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
      return
    }
    NSWorkspace.shared.open(
      [URL(fileURLWithPath: path, isDirectory: true)], withApplicationAt: terminal,
      configuration: NSWorkspace.OpenConfiguration()
    ) { _, error in
      if let error {
        Log.app.error("Open in Terminal failed: \(error.localizedDescription, privacy: .private)")
      }
    }
  }
}
