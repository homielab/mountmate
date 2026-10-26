//  Created by homielab.com

import SwiftUI

/// Popover line shown while a scheduled check found an update the user has
/// not looked at yet. "View…" opens Sparkle's update window.
struct UpdateAvailableBanner: View {
  let version: String
  let onView: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "arrow.down.circle.fill")
        .foregroundStyle(.blue)
        .accessibilityHidden(true)
      Text(
        String(format: NSLocalizedString("MountMate %@ is available", comment: "Popover"), version)
      )
      .font(.callout)
      .lineLimit(1)
      .truncationMode(.middle)
      Spacer(minLength: 4)
      Button(NSLocalizedString("View…", comment: "Button: open the update window"), action: onView)
        .controlSize(.small)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 6)
    .background(Color.blue.opacity(0.08))
  }
}
