//  Created by homielab.com

import SwiftUI

struct LoadingView: View {
    var body: some View {
        VStack {
            ProgressView()
            Text(NSLocalizedString("Loading Disks...", comment: "Initial loading text"))
                .padding(.top, 8)
                .foregroundColor(.secondary)
        }
        .frame(width: 370, height: 200)
    }
}
