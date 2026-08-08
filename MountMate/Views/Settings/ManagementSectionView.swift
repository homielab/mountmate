//  Created by homielab.com

import SwiftUI

struct ManagementSectionView: View {
  let title: LocalizedStringKey
  let iconName: String
  let items: [ManagedVolumeInfo]
  let emptyStateText: LocalizedStringKey
  let footer: LocalizedStringKey
  let onDelete: (ManagedVolumeInfo) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Image(systemName: iconName)
          .font(.headline)
          .foregroundColor(.secondary)
        Text(title)
          .font(.headline)
      }

      Divider()

      if items.isEmpty {
        HStack {
          Spacer()
          Text(emptyStateText)
            .foregroundColor(.secondary)
          Spacer()
        }
        .padding(.vertical)
      } else {
        VStack {
          ForEach(items) { info in
            ManagedVolumeRow(info: info, onDelete: { onDelete(info) })
            if info != items.last {
              Divider()
            }
          }
        }
      }

      Text(footer)
        .font(.caption)
        .foregroundColor(.secondary)
    }
    .padding()
    .background(Color(nsColor: .windowBackgroundColor))
    .cornerRadius(10)
    .shadow(color: .black.opacity(0.1), radius: 3, y: 1)
  }
}

struct ManagedVolumeRow: View {
  let info: ManagedVolumeInfo
  let onDelete: () -> Void

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(info.name).fontWeight(.semibold)
        Text("Volume: \(info.volumeUUID)").font(.system(.caption, design: .monospaced))
          .foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
        Text("Disk: \(info.diskUUID)").font(.system(.caption, design: .monospaced)).foregroundColor(
          .secondary
        ).lineLimit(1).truncationMode(.middle)
      }
      Spacer()
      Button(role: .destructive) {
        onDelete()
        DriveManager.shared.refreshDrives(qos: .userInitiated)
      } label: {
        Image(systemName: "trash")
      }.buttonStyle(.borderless)
    }
    .padding(.vertical, 4)
  }
}
