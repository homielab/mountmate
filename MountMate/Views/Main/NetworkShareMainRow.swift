//  Created by homielab.com

import SwiftUI

struct NetworkShareMainRow: View {
  let share: NetworkShare
  var isManual: Bool = false
  @ObservedObject var networkManager = NetworkMountManager.shared
  @State private var isWorking = false
  @State private var isHovering = false

  private var isMounted: Bool {
    isManual || networkManager.mountedShareIDs.contains(share.id)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 0) {
        HStack {
          ZStack {
            Image(systemName: "network")
              .font(.body)
              .foregroundColor(isMounted ? .accentColor : .secondary.opacity(0.6))
          }
          .frame(width: 24, alignment: .center).padding(.trailing, 8)

          VStack(alignment: .leading, spacing: 2) {
            Text(share.name).fontWeight(.semibold).foregroundColor(
              isMounted ? .primary : .secondary)
            Text(isMounted ? "Mounted" : "Not Mounted")
              .font(.caption).foregroundColor(.secondary)
          }
          Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
          if isMounted {
            let path = NetworkMountManager.shared.getMountPoint(for: share)
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
          }
        }

        Button(action: {
          isWorking = true
          if isMounted {
            NetworkMountManager.shared.unmount(share: share) { success, error in
              isWorking = false
              // Status update handled by manager
              if !success, let error = error {
                DriveManager.shared.userActionError = AppAlert(
                  title: "Unmount Failed", message: error, kind: .basic)
              }
            }
          } else {
            NetworkMountManager.shared.mount(share: share) { success, error in
              isWorking = false
              // Status update handled by manager
              if !success, let error = error {
                DriveManager.shared.userActionError = AppAlert(
                  title: "Mount Failed", message: error, kind: .basic)
              }
            }
          }
        }) {
          Image(
            systemName: isMounted ? "eject.circle.fill" : "plus.circle.fill"
          )
          .opacity(isWorking ? 0 : 1)
        }
        .buttonStyle(.bordered).tint(isMounted ? .red : .blue).disabled(isWorking)
        .overlay { if isWorking { ProgressView().controlSize(.small) } }
        .help(isMounted ? "Eject" : "Mount")
        .padding(.leading, 8)
      }
      .padding(.vertical, 4)
      .padding(.horizontal, 4)
      .background(isHovering ? Color.primary.opacity(0.1) : Color.clear)
      .cornerRadius(5)
      .onHover { hovering in
        self.isHovering = hovering
      }
    }
  }
}
