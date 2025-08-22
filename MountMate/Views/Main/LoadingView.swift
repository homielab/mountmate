//  Created by homielab.com

import SwiftUI

struct LoadingView: View {
  var body: some View {
    VStack(spacing: 8) {
      ProgressView()
      Text(NSLocalizedString("Loading Disks...", comment: "Initial loading text"))
        .foregroundColor(.secondary)
    }
    .frame(width: 350, height: 200)
  }
}
