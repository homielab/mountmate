//  Created by homielab.com

import SwiftUI

struct SnapshotRowView: View {
  let snapshot: APFSSnapshot

  var body: some View {
    HStack {
      Image(systemName: "camera.fill")
        .foregroundColor(.secondary)
        .font(.caption)
      Text(snapshot.name)
        .font(.caption)
      Spacer()
    }
  }
}
