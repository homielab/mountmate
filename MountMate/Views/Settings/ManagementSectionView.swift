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
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Image(systemName: iconName)
          .font(.headline)
          .foregroundStyle(.blue)
        Text(title)
          .font(.headline)
      }

      Divider()

      if items.isEmpty {
        HStack(spacing: 12) {
          Image(systemName: "checkmark.circle")
            .font(.title3)
            .foregroundStyle(.secondary.opacity(0.6))
          Text(emptyStateText)
            .font(.subheadline)
            .foregroundStyle(.secondary)
          Spacer()
        }
        .padding(.vertical, 8)
      } else {
        VStack(spacing: 8) {
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
        .foregroundStyle(.secondary)
    }
    .padding(14)
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(.rect(cornerRadius: 10))
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
    )
  }
}

struct ManagedVolumeRow: View {
  let info: ManagedVolumeInfo
  let onDelete: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "internaldrive")
        .font(.title2)
        .foregroundStyle(.secondary)

      VStack(alignment: .leading, spacing: 2) {
        Text(info.name)
          .font(.body)
          .bold()

        HStack(spacing: 8) {
          Text("Vol: \(info.volumeUUID)")
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)

          Text("Disk: \(info.diskUUID)")
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }

      Spacer()

      Button(role: .destructive) {
        onDelete()
        DriveManager.shared.refreshDrives(qos: .userInitiated)
      } label: {
        Image(systemName: "trash")
          .foregroundStyle(.red.opacity(0.8))
      }
      .buttonStyle(.borderless)
      .help("Remove")
    }
    .padding(.vertical, 4)
  }
}
