//  Created by homielab.com

import AppKit
import SwiftUI

/// Makes a list row reachable with the keyboard: it takes focus (Tab), Up and
/// Down move to the neighbouring control, and Return or Space (macOS 14+, where
/// SwiftUI can read key presses) runs the row's main action. The same action is
/// offered to VoiceOver through `rowAccessibilityActions`.
private struct RowKeyboardNavigation: ViewModifier {
  let primaryAction: () -> Void

  func body(content: Content) -> some View {
    let focusable =
      content
      .focusable()
      .onMoveCommand { direction in
        switch direction {
        case .down: NSApp.keyWindow?.selectNextKeyView(nil)
        case .up: NSApp.keyWindow?.selectPreviousKeyView(nil)
        default: break
        }
      }
    if #available(macOS 14.0, *) {
      focusable.onKeyPress(keys: [.return, .space]) { _ in
        primaryAction()
        return .handled
      }
    } else {
      focusable
    }
  }
}

extension View {
  /// Keyboard focus, Up/Down navigation and Return = main action for a row.
  func rowKeyboardNavigation(primaryAction: @escaping () -> Void) -> some View {
    modifier(RowKeyboardNavigation(primaryAction: primaryAction))
  }
}
