//  Created by homielab.com

import SwiftUI

/// A titled list of saved entries with an empty state and a footer.
struct ManagementSectionView<Item: Identifiable & Equatable, Row: View>: View {
  let title: LocalizedStringKey
  let iconName: String
  let items: [Item]
  let emptyStateText: LocalizedStringKey
  let footer: LocalizedStringKey
  @ViewBuilder let row: (Item) -> Row

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Image(systemName: iconName)
          .font(.headline)
          .foregroundStyle(.blue)
          .accessibilityHidden(true)
        Text(title)
          .font(.headline)
      }

      Divider()

      if items.isEmpty {
        HStack(spacing: 12) {
          Image(systemName: "checkmark.circle")
            .font(.title3)
            .foregroundStyle(.secondary.opacity(0.6))
            .accessibilityHidden(true)
          Text(emptyStateText)
            .font(.subheadline)
            .foregroundStyle(.secondary)
          Spacer()
        }
        .padding(.vertical, 8)
      } else {
        VStack(spacing: 8) {
          ForEach(items) { item in
            row(item)
            if item != items.last {
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

extension ManagementSectionView where Item == ManagedVolumeInfo, Row == ManagedVolumeRow {
  /// A section of `ManagedVolumeInfo` entries with a remove button each.
  init(
    title: LocalizedStringKey, iconName: String, items: [ManagedVolumeInfo],
    emptyStateText: LocalizedStringKey, footer: LocalizedStringKey,
    onDelete: @escaping (ManagedVolumeInfo) -> Void
  ) {
    self.init(
      title: title, iconName: iconName, items: items, emptyStateText: emptyStateText,
      footer: footer,
      row: { info in ManagedVolumeRow(info: info, onDelete: { onDelete(info) }) })
  }
}

/// One saved entry: an icon, a name, monospaced details and a remove button.
struct ManagedEntryRow: View {
  let name: String
  var iconName = "internaldrive"
  let details: [String]
  var isRemoving = false
  let onDelete: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: iconName)
        .font(.title2)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(name)
          .font(.body)
          .bold()

        HStack(spacing: 8) {
          ForEach(details, id: \.self) { detail in
            Text(detail)
              .font(.system(.caption2, design: .monospaced))
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }
      }

      Spacer()

      if isRemoving {
        ProgressView()
          .controlSize(.small)
      } else {
        Button(role: .destructive) {
          onDelete()
        } label: {
          Image(systemName: "trash")
            .foregroundStyle(.red.opacity(0.8))
        }
        .buttonStyle(.borderless)
        .help(NSLocalizedString("Remove", comment: "Remove saved entry button"))
        .accessibilityLabel(
          String(
            format: NSLocalizedString(
              "Remove “%@”", comment: "Accessibility label of a saved entry's remove button"),
            name))
      }
    }
    .padding(.vertical, 4)
  }
}

struct ManagedVolumeRow: View {
  let info: ManagedVolumeInfo
  let onDelete: () -> Void

  var body: some View {
    ManagedEntryRow(
      name: info.name,
      details: [
        String(
          format: NSLocalizedString("Vol: %@", comment: "Saved volume's volume UUID"),
          info.volumeUUID),
        String(
          format: NSLocalizedString("Disk: %@", comment: "Saved volume's disk UUID"),
          info.diskUUID),
      ],
      onDelete: {
        onDelete()
        DriveManager.shared.refreshDrives(qos: .userInitiated)
      })
  }
}
