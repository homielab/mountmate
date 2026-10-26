//  Created by homielab.com

import AppKit
import SwiftUI

/// Animation that respects System Settings → Accessibility → Display → Reduce motion.
enum Motion {
  /// `withAnimation`, but the change is applied without animation when the
  /// user asked to reduce motion.
  static func perform(
    _ animation: Animation? = .default, _ body: () -> Void
  ) {
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      body()
    } else {
      withAnimation(animation, body)
    }
  }
}
