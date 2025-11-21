//  Created by homielab.com

import SwiftUI

struct ErrorBannerView: View {
  let message: String
  @EnvironmentObject var driveManager: DriveManager

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundColor(.white)
        .font(.system(size: 14, weight: .bold))
        .padding(.top, 2)

      Text(message)
        .font(.caption)
        .foregroundColor(.white)
        .fixedSize(horizontal: false, vertical: true)

      Spacer()

      Button(action: {
        driveManager.refreshError = nil
        driveManager.refreshDrives(qos: .userInitiated)
      }) {
        Image(systemName: "arrow.clockwise")
          .foregroundColor(.white)
      }
      .buttonStyle(.plain)
      .help("Retry")
    }
    .padding(10)
    .background(Color.orange)
    .cornerRadius(8)
    .padding(.horizontal, 12)
    .padding(.bottom, 8)
  }
}
