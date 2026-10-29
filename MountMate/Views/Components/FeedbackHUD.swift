//  Created by homielab.com

import AppKit
import SwiftUI

/// Colour of the HUD icon, so a failure never looks like a success.
enum HUDTint: Equatable {
  case success
  case warning
  case neutral

  var color: Color {
    switch self {
    case .success: return .green
    case .warning: return .orange
    case .neutral: return .secondary
    }
  }
}

/// A small confirmation that floats near the top of the screen for a few
/// seconds, like the system volume HUD. Used after actions that end with a
/// password prompt, so the user can see the change was made even when
/// MountMate's menu has already closed. Never takes focus or clicks.
enum FeedbackHUD {
  private static var panel: NSPanel?
  private static var hideWork: DispatchWorkItem?
  private static var visibility = HUDVisibility()

  static func show(
    _ message: String, systemImage: String = "checkmark.circle.fill", tint: HUDTint = .success
  ) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { show(message, systemImage: systemImage, tint: tint) }
      return
    }

    let hosting = NSHostingView(
      rootView: HUDContent(message: message, systemImage: systemImage, tint: tint))
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
    let generation = visibility.show()
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup {
      $0.duration = 0.18
      panel.animator().alphaValue = 1
    }
    NSAccessibility.post(
      element: NSApp as Any, notification: .announcementRequested,
      userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])

    // A later show() may come while this one is fading out; only the
    // current generation hides the shared panel.
    let work = DispatchWorkItem {
      guard visibility.isCurrent(generation) else { return }
      NSAnimationContext.runAnimationGroup(
        {
          $0.duration = 0.3
          panel.animator().alphaValue = 0
        },
        completionHandler: {
          guard visibility.isCurrent(generation) else { return }
          panel.orderOut(nil)
        })
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
  let tint: HUDTint

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: systemImage)
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(tint.color)
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
