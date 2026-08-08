//  Created by homielab.com

import SwiftUI

struct SnapshotRowView: View {
  let snapshot: APFSSnapshot

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "camera.fill")
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(snapshot.name)
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer()
    }
  }
}
