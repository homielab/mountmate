//  Created by homielab.com

import SwiftUI

/// Where a volume row is listed. A pinned volume appears twice (under
/// Pinned and under its disk); the context keeps the two rows apart.
enum VolumeRowContext: String {
  case pinned
  case disk
}

/// A volume's settings-derived row state.
struct VolumeRowState: Equatable {
  var isPinned = false
  var isKeepAlive = false
  var isReconnecting = false
  var customMountPoint: String?
}

/// Row state for the whole list, computed once per list render by
/// `DriveListView`. Rows get plain values instead of each observing
/// PersistenceManager, KeepAliveManager, DriveManager and the editor, so a
/// change only redraws the rows whose values actually changed.
struct VolumeListState: Equatable {
  var rowStates: [String: VolumeRowState] = [:]
  /// `DriveManager.busyVolumeIDs`: volumes with a mount/unmount in flight.
  var busyVolumeIDs: Set<String> = []
  var expandedEditorRowID: String?

  func rowState(for volume: Volume) -> VolumeRowState {
    rowStates[volume.id] ?? VolumeRowState()
  }

  func isEditorExpanded(for volume: Volume, context: VolumeRowContext) -> Bool {
    expandedEditorRowID == VolumeRowView.editorRowID(for: volume, context: context)
  }
}

struct VolumeRowView: View {
  /// The current volume: the parent builds rows from the latest disk list.
  let volume: Volume
  let context: VolumeRowContext
  let state: VolumeRowState
  let isLoading: Bool
  let isCustomMountPointExpanded: Bool
  /// Not observed: only the open editor needs to redraw while typing.
  let customMountPointEditor: CustomMountPointEditorState
  @State private var isHovering = false

  // Used for actions only.
  private var manager: DriveManager { DriveManager.shared }
  private var persistence: PersistenceManager { PersistenceManager.shared }

  init(
    volume: Volume, context: VolumeRowContext, listState: VolumeListState,
    customMountPointEditor: CustomMountPointEditorState
  ) {
    self.volume = volume
    self.context = context
    self.state = listState.rowState(for: volume)
    self.isLoading = listState.busyVolumeIDs.contains(volume.id)
    self.isCustomMountPointExpanded = listState.isEditorExpanded(for: volume, context: context)
    self.customMountPointEditor = customMountPointEditor
  }

  static func editorRowID(for volume: Volume, context: VolumeRowContext) -> String {
    "\(context.rawValue):\(volume.id)"
  }

  private var editorRowID: String { Self.editorRowID(for: volume, context: context) }
  private var currentVolume: Volume { volume }
  private var customMountPoint: String? { state.customMountPoint }
  private var isKeepAlive: Bool { state.isKeepAlive }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 0) {

        HStack {
          ZStack {
            Image(systemName: "externaldrive")
              .font(.body)
              .foregroundStyle(
                currentVolume.isMounted ? Color.accentColor : Color.secondary.opacity(0.6))

            if let error = currentVolume.storageError {
              Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .help(error)
            } else if currentVolume.isMounted, let percentage = currentVolume.usagePercentage {
              CircularProgressRing(
                progress: percentage, color: CircularProgressRing.usageColor(for: percentage),
                lineWidth: 3.0
              ).frame(width: 26, height: 26)
            } else if state.isReconnecting {
              ProgressView()
                .controlSize(.mini)
                .help(
                  NSLocalizedString(
                    "Reconnecting…", comment: "Keep-alive reconnect tooltip"))
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
              if let total = currentVolume.totalSize, let used = currentVolume.usedSpace,
                let free = currentVolume.freeSpace
              {
                // APFS volumes share their container's free space, so this is
                // the space actually available to write to this volume.
                Text(
                  String(
                    format: NSLocalizedString(
                      "DiskUsageUsedFree", comment: "Disk usage format: used / total (free)"),
                    used, total, free))
                  .font(.caption)
                  .foregroundStyle(.secondary)
              } else if let total = currentVolume.totalSize, let used = currentVolume.usedSpace {
                Text(String(format: "%@ / %@", used, total))
                  .font(.caption)
                  .foregroundStyle(.secondary)
              } else if let fsType = currentVolume.fileSystemType {
                Text(fsType)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            } else {
              if state.isReconnecting {
                Text("Reconnecting…")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              } else {
                Text("Unmounted")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
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
        .accessibilityLabel(
          currentVolume.isMounted
            ? String(
              format: NSLocalizedString(
                "Unmount “%@”", comment: "Accessibility label of a volume's unmount button"),
              currentVolume.name)
            : String(
              format: NSLocalizedString(
                "Mount “%@”", comment: "Accessibility label of a volume's mount button"),
              currentVolume.name)
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
          rowID: editorRowID,
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
    }

    Divider()
    if state.isPinned {
      Button {
        persistence.setPinned(false, volume: volume)
      } label: {
        Label("Unpin", systemImage: "pin.slash")
      }
    } else {
      Button {
        if !persistence.setPinned(true, volume: volume) {
          showPersistenceError(for: volume)
        }
      } label: {
        Label("Pin to Top", systemImage: "pin")
      }
    }
    if isKeepAlive {
      Button {
        if !persistence.setKeepAlive(false, volume: volume) {
          showPersistenceError(for: volume)
        }
      } label: {
        Label("Disable Keep Mounted", systemImage: "arrow.triangle.2.circlepath")
      }
    } else {
      Button {
        if !persistence.setKeepAlive(true, volume: volume) {
          showPersistenceError(for: volume)
        }
      } label: {
        Label("Keep Mounted (Auto-Reconnect)", systemImage: "arrow.triangle.2.circlepath")
      }
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
      customMountPointEditor.expandedRowID = isCustomMountPointExpanded ? nil : editorRowID
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
