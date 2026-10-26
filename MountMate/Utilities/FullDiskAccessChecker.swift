//  Created by homielab.com

import AppKit
import Foundation

/// Decides whether MountMate has Full Disk Access by trying to list a folder
/// that macOS only lets such apps read.
enum FullDiskAccessChecker {
  /// The TCC folder is readable only with Full Disk Access.
  static let probePath = "/Library/Application Support/com.apple.TCC"

  static let settingsURL = URL(
    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")

  /// Pure decision: access is granted when listing the probe folder works.
  static func isGranted(probe: (String) throws -> Void) -> Bool {
    do {
      try probe(probePath)
      return true
    } catch {
      return false
    }
  }

  /// Checks the real file system. Blocking: call it off the main thread.
  static func currentlyGranted() -> Bool {
    isGranted { _ = try FileManager.default.contentsOfDirectory(atPath: $0) }
  }

  /// Sandboxed builds cannot hold Full Disk Access, so there is nothing to show.
  static var isApplicable: Bool { !SandboxChecker.isSandboxed }

  static func openSystemSettings() {
    if let settingsURL { NSWorkspace.shared.open(settingsURL) }
  }
}
