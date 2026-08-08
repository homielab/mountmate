//  Created by homielab.com

import SwiftUI

struct NetworkShareRow: View {
  let share: NetworkShare
  let onEdit: () -> Void
  let onError: (String) -> Void
  @ObservedObject private var networkManager = NetworkMountManager.shared
  @State private var isWorking = false

  private var isMounted: Bool {
    networkManager.mountedShareIDs.contains(share.id)
  }

  var body: some View {
    HStack(spacing: 12) {
      ZStack(alignment: .bottomTrailing) {
        Image(systemName: "server.rack")
          .font(.title2)
          .foregroundStyle(.blue)

        Circle()
          .fill(isMounted ? Color.green : Color.secondary.opacity(0.4))
          .frame(width: 8, height: 8)
          .offset(x: 2, y: 2)
      }

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(share.name)
            .font(.body)
            .bold()

          if share.mountAtLogin {
            Label("Auto-mount", systemImage: "bolt.fill")
              .font(.caption2)
              .bold()
              .foregroundStyle(.orange)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Color.orange.opacity(0.12))
              .clipShape(.rect(cornerRadius: 4))
              .help("Auto-mounts at login")
          }
        }

        Text(
          "smb://\(share.username.isEmpty ? "" : "\(share.username)@")\(share.server)/\(share.sharePath)"
        )
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
      }

      Spacer()

      HStack(spacing: 8) {
        // Open in Finder (when mounted)
        if isMounted {
          Button(action: {
            let path = NetworkMountManager.shared.getMountPoint(for: share)
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
          }) {
            Image(systemName: "folder")
          }
          .buttonStyle(.borderless)
          .help("Open in Finder")
        }

        // Mount / Unmount action button
        Button(action: {
          isWorking = true
          if isMounted {
            NetworkMountManager.shared.unmount(share: share) { success, error in
              isWorking = false
              if !success, let error = error {
                onError(error)
              }
            }
          } else {
            NetworkMountManager.shared.mount(share: share) { success, error in
              isWorking = false
              if !success, let error = error {
                onError(error)
              }
            }
          }
        }) {
          if isWorking {
            ProgressView()
              .controlSize(.small)
          } else {
            Image(systemName: isMounted ? "eject.fill" : "play.fill")
              .foregroundStyle(isMounted ? .orange : .green)
          }
        }
        .disabled(isWorking)
        .buttonStyle(.borderless)
        .help(isMounted ? "Unmount Share" : "Mount Share")

        Button(action: onEdit) {
          Image(systemName: "pencil")
        }
        .buttonStyle(.borderless)
        .help("Edit Share")

        Button(
          role: .destructive,
          action: {
            PersistenceManager.shared.removeNetworkShare(share)
          }
        ) {
          Image(systemName: "trash")
            .foregroundStyle(.red.opacity(0.8))
        }
        .buttonStyle(.borderless)
        .help("Delete Share")
      }
    }
    .padding(.vertical, 4)
  }
}
