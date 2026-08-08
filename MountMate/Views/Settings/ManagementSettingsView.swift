//  Created by homielab.com

import SwiftUI

struct ManagementSettingsView: View {
  @ObservedObject private var persistence = PersistenceManager.shared

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        ManagementSectionView(
          title: "Ignored Volumes",
          iconName: "eye.slash.fill",
          items: persistence.ignoredVolumes,
          emptyStateText: "No Ignored Volumes",
          footer:
            "Right-click a volume to ignore it. Useful for system partitions like 'EFI' that you don't need to manage.",
          onDelete: { info in persistence.unignore(info: info) }
        )

        ManagementSectionView(
          title: "Protected Volumes",
          iconName: "lock.shield.fill",
          items: persistence.protectedVolumes,
          emptyStateText: "No Protected Volumes",
          footer: "Right-click a volume to protect it from 'Unmount All' and sleep actions.",
          onDelete: { info in persistence.unprotect(info: info) }
        )

        ManagementSectionView(
          title: "Blocked from Auto-Mounting",
          iconName: "hand.raised.fill",
          items: persistence.blockedVolumes,
          emptyStateText: "No Volumes Blocked from Auto-Mounting",
          footer: "Right-click a volume to prevent it from mounting automatically when connected.",
          onDelete: { info in persistence.unblock(info: info) }
        )

        Spacer()
      }
      .padding()
    }
  }
}
