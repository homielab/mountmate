//  Created by homielab.com

import SwiftUI

struct DiskHeaderRow: View {
  let disk: PhysicalDisk
  @Binding var isExpanded: Bool
  @EnvironmentObject var manager: DriveManager
  @State private var isHovering = false

  var body: some View {
    HStack(spacing: 0) {
      // Toggle Chevron & Icon
      HStack(spacing: 4) {
        Image(systemName: "chevron.right")
          .font(.caption2)
          .foregroundColor(.secondary)
          .rotationEffect(.degrees(isExpanded ? 90 : 0))
          .animation(.easeInOut(duration: 0.2), value: isExpanded)
          .frame(width: 12)

        ZStack {
          Image(systemName: "internaldrive.fill").font(.title2)
          if let error = disk.storageError {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange).help(error)
          } else if let percentage = disk.usagePercentage {
            CircularProgressRing(progress: percentage, color: .purple, lineWidth: 3.5).frame(
              width: 32, height: 32)
          }
        }
        .frame(width: 40, height: 40)

        VStack(alignment: .leading, spacing: 2) {
          Text(disk.name ?? disk.connectionType).font(.headline)
          if let error = disk.storageError {
            Text(error).font(.caption).foregroundColor(.orange).lineLimit(1).truncationMode(.tail)
          } else if let total = disk.totalSize, let used = disk.usedSpace, let free = disk.freeSpace
          {
            Text(
              String(
                format: NSLocalizedString(
                  "DiskUsageUsedFree", comment: "Disk usage format: used / total (free)"),
                used, total, free)
            )
            .font(.caption).foregroundColor(.secondary)
          } else {
            Text(disk.connectionType).font(.caption).foregroundColor(.secondary)
          }
        }
      }
      .contentShape(Rectangle())
      .onTapGesture {
        withAnimation(.easeInOut(duration: 0.2)) {
          isExpanded.toggle()
        }
      }
      .contextMenu {
        Button("Ignore This Disk") {
          for volume in disk.allVolumes { PersistenceManager.shared.ignore(volume: volume) }
          manager.refreshDrives(qos: .userInitiated)
        }
        if disk.type != .internalDisk {
          Button("Eject") { manager.eject(disk: disk) }
        }
      }

      Spacer()

      if disk.type != .internalDisk {
        let isEjecting = manager.busyEjectingIdentifier == disk.id
        Button(action: { manager.eject(disk: disk) }) {
          Image(systemName: "eject.fill").opacity(isEjecting ? 0 : 1)
        }
        .buttonStyle(.bordered).tint(.purple).disabled(isEjecting)
        .overlay { if isEjecting { ProgressView().controlSize(.small) } }.help("Eject")
      }
    }
    .listRowSeparator(.hidden).padding(.vertical, 8).padding(.horizontal, 4)
    .background(isHovering ? Color.primary.opacity(0.1) : Color.clear).cornerRadius(6)
    .onHover { hovering in self.isHovering = hovering }
  }
}
