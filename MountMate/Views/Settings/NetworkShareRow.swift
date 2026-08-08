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
    HStack {
      VStack(alignment: .leading) {
        Text(share.name).fontWeight(.semibold)
        Text("\(share.username)@\(share.server)/\(share.sharePath)")
          .font(.caption).foregroundColor(.secondary)
      }

      Spacer()

      if share.mountAtLogin {
        Image(systemName: "bolt.fill").foregroundColor(.yellow).help("Auto-mounts at login")
      }

      // Open in file browser (only when mounted)
      if isMounted {
        Button(action: {
          let path = NetworkMountManager.shared.getMountPoint(for: share)
          NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }) {
          Image(systemName: "folder")
        }
        .buttonStyle(.borderless)
        .help("Open")
      }

      // Mount / Unmount toggle
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
          ProgressView().controlSize(.small)
        } else {
          Image(systemName: isMounted ? "stop.fill" : "play.fill")
            .foregroundColor(isMounted ? .red : .green)
        }
      }
      .disabled(isWorking)
      .buttonStyle(.borderless)
      .help(isMounted ? "Unmount" : "Mount")

      Button(action: onEdit) {
        Image(systemName: "pencil")
      }
      .buttonStyle(.borderless)
      .help("Edit")

      Button(
        role: .destructive,
        action: {
          PersistenceManager.shared.removeNetworkShare(share)
        }
      ) {
        Image(systemName: "trash")
      }
      .buttonStyle(.borderless)
      .help("Delete")
    }
    .padding(.vertical, 4)
  }
}
