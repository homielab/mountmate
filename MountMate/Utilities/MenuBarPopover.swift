//  Created by homielab.com

import AppKit

/// Opens MountMate's menu bar popover from code (a notification click).
/// `MenuBarExtra` has no API for this, so it clicks the status item's button.
enum MenuBarPopover {
  /// Main thread. Does nothing when the popover is already showing or the
  /// status item cannot be found.
  static func open() {
    for window in NSApp.windows where String(describing: type(of: window)).contains("StatusBar") {
      guard let button = statusButton(in: window.contentView) else { continue }
      button.performClick(nil)
      return
    }
    Log.app.error("Could not open the popover: menu bar button not found")
  }

  private static func statusButton(in view: NSView?) -> NSStatusBarButton? {
    guard let view else { return nil }
    if let button = view as? NSStatusBarButton { return button }
    for sub in view.subviews {
      if let found = statusButton(in: sub) { return found }
    }
    return nil
  }
}
