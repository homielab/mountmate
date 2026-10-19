//  Created by homielab.com

import SwiftUI

struct NetworkShareRow: View {
  let share: NetworkShare
  let onEdit: () -> Void
  /// Reports a failed action as (alert title, message).
  let onError: (_ title: String, _ message: String) -> Void
  @ObservedObject private var networkManager = NetworkMountManager.shared
  @State private var isWorking = false
  @State private var isConfirmingDelete = false
  /// Set when unmounting before a delete failed: offers "Remove Anyway".
  @State private var deleteUnmountError: String?

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

          if share.keepMounted {
            Label("Keep Alive", systemImage: "arrow.triangle.2.circlepath")
              .font(.caption2)
              .bold()
              .foregroundStyle(.blue)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Color.blue.opacity(0.12))
              .clipShape(.rect(cornerRadius: 4))
              .help("Reconnects automatically when the share drops")
          }
        }

        Text(
          "\(share.shareProtocol.urlScheme)://\(share.username.isEmpty ? "" : "\(share.username)@")\(share.server)/\(share.sharePath)"
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
          .accessibilityLabel(Text("Open in Finder"))
        }

        // Mount / Unmount action button
        Button(action: {
          isWorking = true
          if isMounted {
            NetworkMountManager.shared.unmount(share: share) { success, error in
              isWorking = false
              if !success, let error = error {
                onError(NSLocalizedString("Unmount Failed", comment: "Alert title"), error)
              }
            }
          } else {
            NetworkMountManager.shared.mount(share: share) { success, error in
              isWorking = false
              if !success, let error = error {
                onError(NSLocalizedString("Mount Failed", comment: "Alert title"), error)
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
        .accessibilityLabel(isMounted ? Text("Unmount Share") : Text("Mount Share"))

        Button(action: onEdit) {
          Image(systemName: "pencil")
        }
        .buttonStyle(.borderless)
        .help("Edit Share")
        .accessibilityLabel(Text("Edit Share"))

        Button(
          role: .destructive,
          action: {
            isConfirmingDelete = true
          }
        ) {
          Image(systemName: "trash")
            .foregroundStyle(.red.opacity(0.8))
        }
        .buttonStyle(.borderless)
        .disabled(isWorking)
        .help("Delete Share")
        .accessibilityLabel(Text("Delete Share"))
      }
    }
    .padding(.vertical, 4)
    .confirmationDialog(
      String(
        format: NSLocalizedString("Delete “%@”?", comment: "Delete network share confirmation"),
        share.name),
      isPresented: $isConfirmingDelete
    ) {
      Button("Delete Share", role: .destructive) {
        deleteShare()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      if isMounted {
        Text(
          NSLocalizedString(
            "The share will be unmounted and removed from MountMate, along with its saved password.",
            comment: "Delete network share confirmation"))
      } else {
        Text(
          NSLocalizedString(
            "The share will be removed from MountMate, along with its saved password.",
            comment: "Delete network share confirmation"))
      }
    }
    .alert(
      NSLocalizedString("Unmount Failed", comment: "Alert title"),
      isPresented: Binding(
        get: { deleteUnmountError != nil },
        set: { if !$0 { deleteUnmountError = nil } })
    ) {
      Button(
        NSLocalizedString("Remove Anyway", comment: "Remove a network share that could not be unmounted"),
        role: .destructive
      ) {
        // Only forgets the share in MountMate; never touches its files.
        removeShare()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        String(
          format: NSLocalizedString(
            "“%@” could not be unmounted, so it stays mounted. You can still remove it from MountMate; no files on the share are touched.\n\n%@",
            comment: "Remove Anyway alert message"),
          share.name, deleteUnmountError ?? ""))
    }
  }

  /// Removes the share from MountMate (never touches its files).
  private func removeShare() {
    NetworkMountManager.shared.forgetAdoption(forShareID: share.id)
    PersistenceManager.shared.removeNetworkShare(share)
  }

  /// Deletes the share, unmounting it first if it is mounted. If the unmount
  /// fails, the user can remove the share anyway (it then stays mounted).
  private func deleteShare() {
    guard isMounted else {
      removeShare()
      return
    }
    isWorking = true
    NetworkMountManager.shared.unmount(share: share) { success, error in
      isWorking = false
      if success {
        removeShare()
      } else {
        // E.g. the server is gone and umount fails: still let the user
        // remove the share from MountMate.
        deleteUnmountError = error ?? ""
      }
    }
  }
}
