//  Created by homielab.com

import SwiftUI

struct VolumeRowView: View {
  let volume: Volume
  @ObservedObject var customMountPointEditor: CustomMountPointEditorState
  @EnvironmentObject var manager: DriveManager
  @ObservedObject private var persistence = PersistenceManager.shared
  @State private var isHovering = false
  private var isLoading: Bool { manager.busyVolumeIdentifier == volume.id }
  private var customMountPoint: String? { persistence.customMountPoint(for: volume)?.mountPoint }
  private var isCustomMountPointExpanded: Bool {
    customMountPointEditor.expandedVolumeID == volume.id
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
              .foregroundColor(
                volume.isMounted ? .accentColor : .secondary.opacity(0.6))
            if let error = volume.storageError {
              Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundColor(.orange)
                .help(error)
            } else if volume.isMounted, let percentage = volume.usagePercentage {
              CircularProgressRing(
                progress: percentage, color: usageColor(for: percentage),
                lineWidth: 3.0
              ).frame(width: 26, height: 26)
            }
          }
          .frame(width: 24, alignment: .center).padding(.trailing, 8)

          VStack(alignment: .leading, spacing: 2) {
            Text(volume.name).fontWeight(.semibold).foregroundColor(
              volume.isMounted ? .primary : .secondary)
            if volume.isMounted {
              if let total = volume.totalSize, let used = volume.usedSpace {
                // Keep simple used/total; localize only if desired separately
                Text(String(format: "%@ / %@", used, total)).font(.caption).foregroundColor(
                  .secondary)
              } else if let fsType = volume.fileSystemType {
                Text(fsType).font(.caption).foregroundColor(.secondary)
              }
            } else {
              Text("Unmounted").font(.caption).foregroundColor(.secondary)
            }
            if let customMountPoint {
              Text(
                String(
                  format: NSLocalizedString(
                    "Custom Mount Point Summary",
                    comment: "Volume row custom mount point summary"),
                  customMountPoint)
              )
              .font(.caption2)
              .foregroundColor(.secondary)
              .lineLimit(nil)
              .fixedSize(horizontal: false, vertical: true)
              .help(customMountPoint)
            }
          }
          Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
          if volume.isMounted, let mountPoint = volume.mountPoint {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: mountPoint)])
          }
        }

        Button(action: {
          if volume.isMounted {
            manager.unmount(volume: volume)
          } else {
            manager.mount(volume: volume)
          }
        }) {
          Image(
            systemName: volume.isMounted ? "minus.circle.fill" : "plus.circle.fill"
          )
          .opacity(isLoading ? 0 : 1)
        }
        .buttonStyle(.bordered).tint(volume.isMounted ? .red : .blue).disabled(isLoading)
        .overlay { if isLoading { ProgressView().controlSize(.small) } }
        .help(
          volume.isMounted
            ? NSLocalizedString("Unmount", comment: "...")
            : NSLocalizedString("Mount", comment: "...")
        )
        .padding(.leading, 8)
      }
      .padding(.vertical, 4)
      .padding(.horizontal, 4)
      .background(isHovering ? Color.primary.opacity(0.1) : Color.clear)
      .cornerRadius(5)
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
