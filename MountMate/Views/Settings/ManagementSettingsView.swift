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

  /// A row of the Custom Mount Points list: a saved entry, or a rule found
  /// in /etc/fstab that no saved entry describes.
  private enum CustomMountPointItem: Identifiable, Equatable {
    case saved(VolumeCustomMountPoint)
    case untracked(FstabRules.CustomMountRule)

    var id: String {
      switch self {
      case .saved(let info): return "saved:\(info.id)"
      case .untracked(let rule): return "fstab:\(rule.id)"
      }
    }
  }

  private var customMountPointItems: [CustomMountPointItem] {
    persistence.customMountPoints.map(CustomMountPointItem.saved)
      + persistence.untrackedCustomMountRules.map(CustomMountPointItem.untracked)
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
          title: "Unmount When Idle",
          iconName: "moon.zzz.fill",
          items: persistence.idleUnmountVolumes,
          emptyStateText: "No Volumes Unmounted When Idle",
          footer:
            "Right-click a volume on an external drive and choose “Unmount When Idle” to unmount it after some minutes without reads or writes. A volume still in use stays mounted and is tried again later. Time Machine disks stay mounted."
        ) { info in
          ManagedEntryRow(
            name: info.name,
            iconName: "moon.zzz",
            details: [
              VolumeMenuRules.idleUnmountChoiceTitle(info.minutes),
              String(
                format: NSLocalizedString("Vol: %@", comment: "Saved volume's volume UUID"),
                info.volumeUUID),
            ],
            onDelete: { persistence.removeIdleUnmount(info: info) })
        }

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

        if !persistence.unsupportedCustomMountRules.isEmpty {
          UnsupportedCustomMountRulesView(
            rules: persistence.unsupportedCustomMountRules,
            savedEntries: persistence.customMountPoints,
            removingIDs: removingCustomMountPointIDs,
            onRemove: removeRule)
        }

        ManagementSectionView(
          title: "Custom Mount Points",
          iconName: "folder.badge.gearshape",
          items: customMountPointItems,
          emptyStateText: "No Custom Mount Points",
          footer:
            "Right-click a volume and choose “Custom Mount Point…” to mount it in a folder of your choice. Removing an entry also removes its system mount rule (/etc/fstab) and may ask for your admin password."
        ) { item in
          switch item {
          case .saved(let info):
            ManagedEntryRow(
              name: info.name,
              iconName: "folder.badge.gearshape",
              details: [info.mountPoint, volumeDetail(info.volumeUUID)],
              isRemoving: removingCustomMountPointIDs.contains(info.id),
              onDelete: { removeCustomMountPoint(info) })
          case .untracked(let rule):
            ManagedEntryRow(
              name: connectedVolumeName(uuid: rule.volumeUUID),
              iconName: "folder.badge.questionmark",
              details: [rule.mountPoint, volumeDetail(rule.volumeUUID)],
              note: NSLocalizedString(
                "Not Tracked by MountMate",
                comment:
                  "A custom mount point rule in /etc/fstab that MountMate has no saved entry for"),
              isRemoving: removingCustomMountPointIDs.contains(rule.id),
              onDelete: { removeRule(rule) })
          }
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

  private func volumeDetail(_ volumeUUID: String) -> String {
    String(
      format: NSLocalizedString("Vol: %@", comment: "Saved volume's volume UUID"), volumeUUID)
  }

  /// The connected volume's name; an untracked rule stores none.
  private func connectedVolumeName(uuid: String) -> String {
    connectedVolume(uuid: uuid)?.name
      ?? NSLocalizedString("Volume Not Connected", comment: "Name shown for a disconnected volume")
  }

  private func connectedVolume(uuid: String) -> Volume? {
    (driveManager.physicalDisks ?? []).flatMap(\.allVolumes)
      .first { $0.id.caseInsensitiveCompare(uuid) == .orderedSame }
  }

  /// Like `removeCustomMountPoint`, for a rule found in /etc/fstab without
  /// a saved entry or of a file system that may no longer get one. The
  /// volume is remounted at its default location.
  private func removeRule(_ rule: FstabRules.CustomMountRule) {
    guard !removingCustomMountPointIDs.contains(rule.id) else { return }
    removingCustomMountPointIDs.insert(rule.id)
    persistence.removeCustomMountRule(rule) { result in
      removingCustomMountPointIDs.remove(rule.id)
      switch result {
      case .success:
        FeedbackHUD.show(
          NSLocalizedString("Custom mount rule removed.", comment: "Unsafe fstab rule removed"))
        if let volume = connectedVolume(uuid: rule.volumeUUID), volume.isMounted {
          DriveManager.shared.remount(volume: volume)
        }
      case .cancelled:
        break
      case .failure(let message):
        removalErrorMessage = message
      }
    }
  }

  private func removeCustomMountPoint(_ info: VolumeCustomMountPoint) {
    guard !removingCustomMountPointIDs.contains(info.id) else { return }
    removingCustomMountPointIDs.insert(info.id)
    persistence.removeCustomMountPoint(info: info) { result in
      removingCustomMountPointIDs.remove(info.id)
      switch result {
      case .success:
        FeedbackHUD.show(
          String(
            format: NSLocalizedString(
              "“%@” will mount at its default location again.",
              comment: "Custom mount point removed"), info.name))
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
