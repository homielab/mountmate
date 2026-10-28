//  Created by homielab.com

import SwiftUI

struct ErrorView: View {
  let alertInfo: AppAlert
  let onRetry: () -> Void

  var body: some View {
    VStack(spacing: 12) {
      VStack(spacing: 12) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 40))
          .foregroundStyle(.red)
          .accessibilityHidden(true)

        Text(alertInfo.title)
          .font(.headline)

        Text(alertInfo.message)
          .font(.body)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal)
      }
      .accessibilityElement(children: .combine)

      Button(action: onRetry) {
        Label("Try Again", systemImage: "arrow.clockwise")
      }
      .padding(.top, 8)
    }
    .frame(width: 350)
    .padding(.vertical)
  }
}
