//  Created by homielab.com

import SwiftUI

struct VolumeRowView: View {
  let volume: Volume
  @ObservedObject var customMountPointEditor: CustomMountPointEditorState
  @EnvironmentObject var manager: DriveManager
  @ObservedObject private var persistence = PersistenceManager.shared
  @State private var isHovering = false
  private var currentVolume: Volume {
    (manager.physicalDisks ?? []).flatMap(\.allVolumes).first(where: { $0.id == volume.id }) ?? volume
  }

  private var isLoading: Bool { manager.busyVolumeIdentifier == volume.id }
  private var customMountPoint: String? { persistence.customMountPoint(for: currentVolume)?.mountPoint }
  private var isCustomMountPointExpanded: Bool {
    customMountPointEditor.expandedVolumeID == currentVolume.id
  }

  private func usageColor(for percentage: Double) -> Color {
    if percentage > 0.9 { return .red } else if percentage > 0.75 { return .orange }
    return .accentColor
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 0) {

        HStack {
          ZStack {
            Image(systemName: "externaldrive")
              .font(.body)
              .foregroundStyle(currentVolume.isMounted ? Color.accentColor : Color.secondary.opacity(0.6))

            if let error = currentVolume.storageError {
              Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .help(error)
            } else if currentVolume.isMounted, let percentage = currentVolume.usagePercentage {
              CircularProgressRing(
                progress: percentage, color: usageColor(for: percentage),
                lineWidth: 3.0
              ).frame(width: 26, height: 26)
            }
          }
          .frame(width: 24, alignment: .center)
          .padding(.trailing, 8)

          VStack(alignment: .leading, spacing: 2) {
            Text(currentVolume.name)
              .font(.body)
              .bold()
              .foregroundStyle(currentVolume.isMounted ? .primary : .secondary)

            if currentVolume.isMounted {
              if let total = currentVolume.totalSize, let used = currentVolume.usedSpace {
                Text(String(format: "%@ / %@", used, total))
                  .font(.caption)
                  .foregroundStyle(.secondary)
              } else if let fsType = currentVolume.fileSystemType {
                Text(fsType)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            } else {
              Text("Unmounted")
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let customMountPoint {
              HStack(spacing: 4) {
                Image(systemName: "folder.badge.gearshape")
                  .font(.caption2)

                Text(
                  String(
                    format: NSLocalizedString(
                      "Custom Mount Point Summary",
                      comment: "Volume row custom mount point summary"),
                    customMountPoint)
                )
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
              }
              .foregroundStyle(.blue)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Color.blue.opacity(0.1))
              .clipShape(.rect(cornerRadius: 4))
              .help(customMountPoint)
            }
          }
          Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
          if currentVolume.isMounted, let mountPoint = currentVolume.mountPoint {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: mountPoint)])
          }
        }

        Button(action: {
          if currentVolume.isMounted {
            manager.unmount(volume: currentVolume)
          } else {
            manager.mount(volume: currentVolume)
          }
        }) {
          Label(
            currentVolume.isMounted
              ? NSLocalizedString("Unmount", comment: "Unmount volume action")
              : NSLocalizedString("Mount", comment: "Mount volume action"),
            systemImage: currentVolume.isMounted ? "eject.fill" : "play.fill"
          )
          .font(.caption)
          .bold()
          .opacity(isLoading ? 0 : 1)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(currentVolume.isMounted ? .red : .blue)
        .disabled(isLoading)
        .overlay {
          if isLoading {
            ProgressView().controlSize(.small)
          }
        }
        .help(
          currentVolume.isMounted
            ? NSLocalizedString("Unmount", comment: "Unmount volume tooltip")
            : NSLocalizedString("Mount", comment: "Mount volume tooltip")
        )
        .padding(.leading, 8)
      }
      .padding(.vertical, 4)
      .padding(.horizontal, 4)
      .background(isHovering ? Color.primary.opacity(0.08) : Color.clear)
      .clipShape(.rect(cornerRadius: 6))
      .onHover { hovering in
        self.isHovering = hovering
      }
      .onAppear {
        if isCustomMountPointExpanded {
          syncEditorStateFromPersistence()
        }
      }
      .contextMenu {
        contextMenuItems
      }

      if isCustomMountPointExpanded {
        InlineCustomMountPointEditor(
          volume: volume,
          editorState: customMountPointEditor,
          onClose: {
            customMountPointEditor.collapse()
          }
        )
        .padding(.leading, 32)
      }

      if !volume.snapshots.isEmpty {
        DisclosureGroup {
          ForEach(volume.snapshots) { snapshot in
            SnapshotRowView(snapshot: snapshot)
          }
        } label: {
          Text(NSLocalizedString("Snapshots", comment: "Snapshots section label"))
            .font(.caption).fontWeight(.semibold).foregroundColor(.secondary)
        }
        .padding(.leading, 32)
      }
    }
  }

  @ViewBuilder
  private var contextMenuItems: some View {
    if volume.isMounted {
      Button {
        manager.unmount(volume: volume)
      } label: {
        Label("Unmount", systemImage: "minus.circle")
      }
      Button {
        if let path = volume.mountPoint {
          NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
      } label: {
        Label("Open in Finder", systemImage: "folder")
      }
      Divider()
      if volume.isProtected {
        Button {
          if let compositeId = volume.compositeId,
            let info = persistence.protectedVolumes.first(where: {
              $0.id == compositeId
            })
          {
            persistence.unprotect(info: info)
            DriveManager.shared.refreshDrives(qos: .userInitiated)
          }
        } label: {
          Label("Unprotect from 'Unmount All'", systemImage: "lock.open.fill")
        }
      } else {
        Button {
          if !persistence.protect(volume: volume) {
            showPersistenceError(for: volume)
          } else {
            DriveManager.shared.refreshDrives(qos: .userInitiated)
          }
        } label: {
          Label("Protect from 'Unmount All'", systemImage: "lock.fill")
        }
      }
    } else {
      Button {
        manager.mount(volume: volume)
      } label: {
        Label("Mount", systemImage: "plus.circle")
      }
      Divider()
    }

    Button {
      if !PersistenceManager.shared.block(volume: volume) {
        showPersistenceError(for: volume)
      }
    } label: {
      Label("Don't Auto-Mount This Volume", systemImage: "hand.raised")
    }
    Button {
      syncEditorStateFromPersistence()
      customMountPointEditor.expandedVolumeID = isCustomMountPointExpanded ? nil : volume.id
    } label: {
      Label(
        NSLocalizedString(
          "Custom Mount Point Menu",
          comment: "Volume context menu custom mount point action"),
        systemImage: "folder.badge.gearshape")
    }
    Divider()
    Button(role: .destructive) {
      if !PersistenceManager.shared.ignore(volume: volume) {
        showPersistenceError(for: volume)
      } else {
        DriveManager.shared.refreshDrives(qos: .userInitiated)
      }
    } label: {
      Label("Ignore This Volume", systemImage: "eye.slash")
    }
  }

  private func showPersistenceError(for volume: Volume) {
    let message = String(
      format: NSLocalizedString(
        "Could not save settings for “%@” because it does not have a unique identifier (UUID).",
        comment: "Persistence error message"), volume.name)
    DriveManager.shared.userActionError = AppAlert(
      title: NSLocalizedString("Action Failed", comment: "Alert title"),
      message: message,
      kind: .basic
    )
  }

  private func syncEditorStateFromPersistence() {
    customMountPointEditor.sync(from: customMountPoint)
  }
}
