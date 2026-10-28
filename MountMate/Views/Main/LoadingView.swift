//  Created by homielab.com

import SwiftUI

struct LoadingView: View {
  var body: some View {
    VStack(spacing: 8) {
      ProgressView()
      Text(NSLocalizedString("Loading Disks...", comment: "Initial loading text"))
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
    .frame(width: 350, height: 200)
  }
}
