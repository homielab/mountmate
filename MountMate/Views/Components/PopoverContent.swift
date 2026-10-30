//  Created by homielab.com

import AppKit
import SwiftUI

/// The tallest the drive list may grow: 70% of the screen's visible height,
/// so a long list scrolls inside the popover instead of running off a small
/// screen. Pure for tests.
enum PopoverHeightRules {
  static let screenFraction = 0.7
  static let fallbackScreenHeight: CGFloat = 800

  static func maxListHeight(visibleFrameHeight: CGFloat?) -> CGFloat {
    (visibleFrameHeight ?? fallbackScreenHeight) * screenFraction
  }

  @MainActor static var maxListHeight: CGFloat {
    maxListHeight(visibleFrameHeight: NSScreen.main?.visibleFrame.height)
  }
}

struct PopoverContent<Content: View>: View {
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(spacing: 0) {
      content()
    }
    .fixedSize(horizontal: false, vertical: true)
  }
}
