//  Created by homielab.com

import AppKit
import SwiftUI

/// A small confirmation that floats near the top of the screen for a few
/// seconds, like the system volume HUD. Used after actions that end with a
/// password prompt, so the user can see the change was made even when
/// MountMate's menu has already closed. Never takes focus or clicks.
enum FeedbackHUD {
  private static var panel: NSPanel?
  private static var hideWork: DispatchWorkItem?

  static func show(_ message: String, systemImage: String = "checkmark.circle.fill") {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { show(message, systemImage: systemImage) }
      return
    }

    let hosting = NSHostingView(rootView: HUDContent(message: message, systemImage: systemImage))
    let size = hosting.fittingSize
    let panel = panel ?? makePanel()
    self.panel = panel
    panel.contentView = hosting
    panel.setContentSize(size)

    let screen = NSScreen.main ?? NSScreen.screens.first
    if let frame = screen?.visibleFrame {
      panel.setFrameOrigin(
        NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 24))
    }

    hideWork?.cancel()
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().alphaValue = 1 }
    NSAccessibility.post(
      element: NSApp as Any, notification: .announcementRequested,
      userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])

    let work = DispatchWorkItem {
      NSAnimationContext.runAnimationGroup(
        { $0.duration = 0.3; panel.animator().alphaValue = 0 },
        completionHandler: { panel.orderOut(nil) })
    }
    hideWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
  }

  private static func makePanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: true)
    panel.isFloatingPanel = true
    panel.level = .statusBar
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    return panel
  }
}

private struct HUDContent: View {
  let message: String
  let systemImage: String

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: systemImage)
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(.green)
      Text(message)
        .font(.system(size: 13, weight: .medium))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 360, alignment: .leading)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }
}
