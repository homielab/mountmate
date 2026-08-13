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
          ZStack(alignment: .bottomTrailing) {
            Image(systemName: "server.rack")
              .font(.body)
              .foregroundStyle(isMounted ? Color.accentColor : Color.secondary.opacity(0.6))

            Circle()
              .fill(isMounted ? Color.green : Color.secondary.opacity(0.4))
              .frame(width: 6, height: 6)
              .offset(x: 2, y: 2)
          }
          .frame(width: 24, alignment: .center)
          .padding(.trailing, 8)

          VStack(alignment: .leading, spacing: 2) {
            Text(share.name)
              .font(.body)
              .bold()
              .foregroundStyle(isMounted ? .primary : .secondary)

            Text(isMounted ? NSLocalizedString("Mounted", comment: "Status") : NSLocalizedString("Not Mounted", comment: "Status"))
              .font(.caption)
              .foregroundStyle(.secondary)
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
              if !success, let error = error {
                DriveManager.shared.userActionError = AppAlert(
                  title: NSLocalizedString("Unmount Failed", comment: "Alert title"), message: error, kind: .basic)
              }
            }
          } else {
            NetworkMountManager.shared.mount(share: share) { success, error in
              isWorking = false
              if !success, let error = error {
                DriveManager.shared.userActionError = AppAlert(
                  title: NSLocalizedString("Mount Failed", comment: "Alert title"), message: error, kind: .basic)
              }
            }
          }
        }) {
          Label(
            isMounted ? NSLocalizedString("Eject", comment: "Action") : NSLocalizedString("Mount", comment: "Action"),
            systemImage: isMounted ? "eject.fill" : "play.fill"
          )
          .font(.caption)
          .bold()
          .opacity(isWorking ? 0 : 1)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(isMounted ? .red : .blue)
        .disabled(isWorking)
        .overlay {
          if isWorking {
            ProgressView().controlSize(.small)
          }
        }
        .help(isMounted ? NSLocalizedString("Eject", comment: "Tooltip") : NSLocalizedString("Mount", comment: "Tooltip"))
        .padding(.leading, 8)
      }
      .padding(.vertical, 4)
      .padding(.horizontal, 4)
      .background(isHovering ? Color.primary.opacity(0.08) : Color.clear)
      .clipShape(.rect(cornerRadius: 6))
      .onHover { hovering in
        self.isHovering = hovering
      }
    }
  }
}
