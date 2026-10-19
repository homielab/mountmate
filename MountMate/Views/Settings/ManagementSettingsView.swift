//  Created by homielab.com

import SwiftUI

struct ManagementSettingsView: View {
  @ObservedObject private var persistence = PersistenceManager.shared
  /// Observed for the names of connected pinned volumes.
  @ObservedObject private var driveManager = DriveManager.shared
  /// Custom mount points whose /etc/fstab rule is being removed.
  @State private var removingCustomMountPointIDs: Set<String> = []
  @State private var removalErrorMessage: String?

  /// Pins are stored as bare composite IDs; wrapped for `ForEach`.
  private struct PinnedEntry: Identifiable, Equatable {
    let id: String
  }

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
          footer:
            "Right-click a volume to prevent it from mounting automatically while MountMate is running.",
          onDelete: { info in persistence.unblock(info: info) }
        )

        ManagementSectionView(
          title: "Kept Mounted Volumes",
          iconName: "arrow.triangle.2.circlepath",
          items: persistence.keepAliveVolumes,
          emptyStateText: "No Volumes Kept Mounted",
          footer:
            "Right-click a volume and choose “Keep Mounted (Auto-Reconnect)” to remount it automatically when it drops.",
          onDelete: { info in persistence.unkeepAlive(info: info) }
        )

        ManagementSectionView(
          title: "Pinned Volumes",
          iconName: "pin.fill",
          items: persistence.pinnedVolumeIDs.map(PinnedEntry.init(id:)),
          emptyStateText: "No Pinned Volumes",
          footer: "Right-click a volume and choose “Pin to Top” to list it first."
        ) { entry in
          ManagedEntryRow(
            name: pinnedVolumeName(for: entry.id),
            iconName: "pin",
            details: [entry.id],
            onDelete: { persistence.unpin(id: entry.id) })
        }

        ManagementSectionView(
          title: "Custom Mount Points",
          iconName: "folder.badge.gearshape",
          items: persistence.customMountPoints,
          emptyStateText: "No Custom Mount Points",
          footer:
            "Right-click a volume and choose “Custom Mount Point…” to mount it in a folder of your choice. Removing an entry also removes its system mount rule (/etc/fstab) and may ask for your admin password."
        ) { info in
          ManagedEntryRow(
            name: info.name,
            iconName: "folder.badge.gearshape",
            details: [
              info.mountPoint,
              String(
                format: NSLocalizedString("Vol: %@", comment: "Saved volume's volume UUID"),
                info.volumeUUID),
            ],
            isRemoving: removingCustomMountPointIDs.contains(info.id),
            onDelete: { removeCustomMountPoint(info) })
        }

        Spacer()
      }
      .padding()
    }
    .alert(
      NSLocalizedString("Custom Mount Point", comment: "Alert title"),
      isPresented: Binding(
        get: { removalErrorMessage != nil },
        set: { if !$0 { removalErrorMessage = nil } })
    ) {
      Button(NSLocalizedString("OK", comment: "OK button"), role: .cancel) {}
    } message: {
      Text(removalErrorMessage ?? "")
    }
  }

  /// The pinned volume's name while it is connected; pins store no name.
  private func pinnedVolumeName(for id: String) -> String {
    (driveManager.physicalDisks ?? []).flatMap(\.allVolumes)
      .first { $0.compositeId == id }?.name
      ?? NSLocalizedString("Volume Not Connected", comment: "Name shown for a disconnected volume")
  }

  private func removeCustomMountPoint(_ info: VolumeCustomMountPoint) {
    guard !removingCustomMountPointIDs.contains(info.id) else { return }
    removingCustomMountPointIDs.insert(info.id)
    persistence.removeCustomMountPoint(info: info) { result in
      removingCustomMountPointIDs.remove(info.id)
      switch result {
      case .success:
        // Like the editor: remount a connected, mounted volume so it moves
        // back to the default location now.
        if let volume = (DriveManager.shared.physicalDisks ?? []).flatMap(\.allVolumes)
          .first(where: { $0.id == info.volumeUUID }), volume.isMounted
        {
          DriveManager.shared.remount(volume: volume)
        }
      case .cancelled:
        break
      case .failure(let message):
        removalErrorMessage = message
      }
    }
  }
}
