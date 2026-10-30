//  Created by homielab.com

import SwiftUI

struct DiskHeaderRow: View {
  let disk: PhysicalDisk
  @Binding var isExpanded: Bool
  @EnvironmentObject var manager: DriveManager
  @State private var isHovering = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Internal disks offer no eject. A disk whose type could not be
  /// determined still shows Eject; DriveManager explains why it refuses.
  private var canEject: Bool {
    disk.type != .internalDisk || manager.unverifiedDiskIDs.contains(disk.id)
  }

  /// Ejecting would unmount a protected volume too (same rule as Eject All).
  private var hasProtectedVolume: Bool { disk.allVolumes.contains(where: \.isProtected) }

  var body: some View {
    HStack(spacing: 0) {
      // Toggle Chevron & Icon
      HStack(spacing: 6) {
        Image(systemName: "chevron.right")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .rotationEffect(.degrees(isExpanded ? 90 : 0))
          .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isExpanded)
          .frame(width: 12)
          .accessibilityHidden(true)

        ZStack {
          Image(systemName: "internaldrive.fill")
            .font(.title2)
            .foregroundStyle(.primary)

          if let error = disk.storageError {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
              .help(error)
              .accessibilityLabel(Text(error))
          } else if let percentage = disk.usagePercentage {
            CircularProgressRing(progress: percentage, color: .purple, lineWidth: 3.5)
              .frame(width: 32, height: 32)
          }
        }
        .frame(width: 40, height: 40)

        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 4) {
            Text(disk.name ?? disk.connectionType)
              .font(.headline)
              .bold()
            if disk.smartStatus == .failing {
              let warning = NSLocalizedString(
                "SMART status: failing — back up this disk",
                comment: "Warning badge on a disk whose SMART status is failing")
              Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .help(warning)
                .accessibilityLabel(Text(warning))
            }
          }

          if let error = disk.storageError {
            Text(error)
              .font(.caption)
              .foregroundStyle(.orange)
              .lineLimit(1)
              .truncationMode(.tail)
          } else if let total = disk.totalSize, let used = disk.usedSpace, let free = disk.freeSpace
          {
            Text(
              String(
                format: NSLocalizedString(
                  "DiskUsageUsedFree", comment: "Disk usage format: used / total (free)"),
                used, total, free)
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          } else {
            Text(disk.connectionType)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(.isButton)
      .accessibilityValue(Text(AccessibilityLabels.expansionValue(isExpanded: isExpanded)))
      .accessibilityAction { toggleExpanded() }
      .contentShape(Rectangle())
      .onTapGesture { toggleExpanded() }
      .rowKeyboardNavigation(primaryAction: toggleExpanded)
      .contextMenu {
        Button("Ignore This Disk") {
          for volume in disk.allVolumes { PersistenceManager.shared.ignore(volume: volume) }
          manager.refreshDrives(qos: .userInitiated)
        }
        if canEject {
          Button("Eject") { manager.eject(disk: disk) }
            .disabled(manager.isEjecting(disk.id) || hasProtectedVolume)
        }
      }

      Spacer()

      if canEject {
        let isEjecting = manager.isEjecting(disk.id)
        Button(action: { manager.eject(disk: disk) }) {
          Image(systemName: "eject.fill")
            .opacity(isEjecting ? 0 : 1)
        }
        .buttonStyle(.bordered)
        .tint(.purple)
        .disabled(isEjecting || hasProtectedVolume)
        .overlay {
          if isEjecting {
            ProgressView().controlSize(.small)
          }
        }
        .help(
          hasProtectedVolume
            ? NSLocalizedString(
              "A volume on this disk is protected. Turn off Protect to eject it.",
              comment: "Tooltip")
            : NSLocalizedString("Eject", comment: "Tooltip")
        )
        .accessibilityLabel(
          Text(AccessibilityLabels.action(.eject, name: disk.name ?? disk.id))
        )
        .accessibilityValue(Text.busyValue(isEjecting))
      }
    }
    .listRowSeparator(.hidden)
    .padding(.vertical, 8)
    .padding(.horizontal, 4)
    .background(isHovering ? Color.primary.opacity(0.08) : Color.clear)
    .clipShape(.rect(cornerRadius: 6))
    .onHover { hovering in self.isHovering = hovering }
  }

  /// Shows or hides the disk's volumes (click, Return/Space, VoiceOver).
  private func toggleExpanded() {
    Motion.perform(.easeInOut(duration: 0.2)) {
      isExpanded.toggle()
    }
  }
}
