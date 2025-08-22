//  Created by homielab.com

import SwiftUI

struct ErrorView: View {
  let alertInfo: AppAlert
  let onRetry: () -> Void

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 40))
        .foregroundColor(.red)

      Text(alertInfo.title)
        .font(.headline)

      Text(alertInfo.message)
        .font(.body)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal)

      Button(action: onRetry) {
        Label("Try Again", systemImage: "arrow.clockwise")
      }
      .padding(.top, 8)
    }
    .frame(width: 350)
    .padding(.vertical)
  }
}
