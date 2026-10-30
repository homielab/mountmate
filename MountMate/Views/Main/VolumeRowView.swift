//  Created by homielab.com

import SwiftUI

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

  /// Tooltip and VoiceOver value for a volume whose UUID another listed
  /// volume shares (`Volume.isDuplicateUUID`), nil otherwise.
  static func duplicateUUIDNote(for volume: Volume) -> String? {
    guard volume.isDuplicateUUID else { return nil }
    return NSLocalizedString(
      "Same UUID as another volume. Use the disk or device name to tell them apart.",
      comment: "Tooltip and VoiceOver value: two volumes share one VolumeUUID")
  }

  private var editorRowID: String { Self.editorRowID(for: volume, context: context) }
  private var currentVolume: Volume { volume }
  private var customMountPoint: String? { state.customMountPoint }
  private var rules: VolumeMenuRules { VolumeMenuRules(volume: volume, state: state) }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 0) {

        HStack {
          ZStack {
            Image(systemName: "externaldrive")
              .font(.body)
              .foregroundStyle(
                currentVolume.isMounted ? Color.accentColor : Color.secondary.opacity(0.6))

            if state.isVerifying {
              ProgressView()
                .controlSize(.mini)
                .help(
                  NSLocalizedString(
                    "Verifying…", comment: "Volume status: verification in progress")
                )
                .accessibilityLabel(
                  Text(
                    NSLocalizedString(
                      "Verifying…", comment: "Volume status: verification in progress")))
            } else if let error = currentVolume.storageError {
              Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .help(error)
                .accessibilityLabel(Text(error))
            } else if currentVolume.isMounted, let percentage = currentVolume.usagePercentage {
              CircularProgressRing(
                progress: percentage,
                color: state.lowSpace == nil
                  ? CircularProgressRing.usageColor(for: percentage) : .orange,
                lineWidth: 3.0
              ).frame(width: 26, height: 26)
            } else if state.isReconnecting {
              ProgressView()
                .controlSize(.mini)
                .help(
                  NSLocalizedString(
                    "Reconnecting…", comment: "Keep-alive reconnect tooltip")
                )
                .accessibilityLabel(
                  Text(
                    NSLocalizedString(
                      "Reconnecting…", comment: "Keep-alive reconnect tooltip")))
            }
          }
          .frame(width: 24, alignment: .center)
          .padding(.trailing, 8)

          VStack(alignment: .leading, spacing: 2) {
            Text(currentVolume.name)
              .font(.body)
              .bold()
              .foregroundStyle(currentVolume.isMounted ? .primary : .secondary)
              .help(Self.duplicateUUIDNote(for: currentVolume) ?? "")

            if currentVolume.isMounted {
              if state.isVerifying {
                Text(
                  NSLocalizedString(
                    "Verifying…", comment: "Volume status: verification in progress")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
              } else if currentVolume.isReadOnly {
                Text("Read-only")
                  .font(.caption2).fontWeight(.semibold)
                  .foregroundStyle(.orange)
                  .padding(.horizontal, 6)
                  .padding(.vertical, 2)
                  .background(Color.orange.opacity(0.15))
                  .clipShape(.rect(cornerRadius: 4))
              }
              if let warning = state.lowSpace {
                let message = LowSpaceRules.message(for: warning)
                Text("Almost Full")
                  .font(.caption2).fontWeight(.semibold)
                  .foregroundStyle(.orange)
                  .padding(.horizontal, 6)
                  .padding(.vertical, 2)
                  .background(Color.orange.opacity(0.15))
                  .clipShape(.rect(cornerRadius: 4))
                  .help(message)
                  .accessibilityLabel(Text(message))
              }
              if let total = currentVolume.totalSize, let used = currentVolume.usedSpace,
                let free = currentVolume.freeSpace
              {
                // APFS volumes share their container's free space, so this is
                // the space actually available to write to this volume.
                Text(
                  String(
                    format: NSLocalizedString(
                      "DiskUsageUsedFree", comment: "Disk usage format: used / total (free)"),
                    used, total, free)
                )
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
                if let id = currentVolume.compositeId {
                  ReconnectStatusLine(
                    nextRetry: { KeepAliveManager.shared.nextRetryDate(forVolumeID: id) },
                    reconnectNow: { KeepAliveManager.shared.sweepNow(resetBackoff: true) })
                }
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
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(Self.duplicateUUIDNote(for: currentVolume) ?? ""))
        .contentShape(Rectangle())
        .onTapGesture {
          if currentVolume.isMounted, let mountPoint = currentVolume.mountPoint {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: mountPoint)])
          }
        }
        .rowKeyboardNavigation(primaryAction: toggleMount)
        .accessibilityAction(named: Text(currentVolume.isMounted ? "Unmount" : "Mount")) {
          toggleMount()
        }
        .accessibilityActions {
          if state.isReconnecting, !currentVolume.isMounted {
            Button("Reconnect Now") { KeepAliveManager.shared.sweepNow(resetBackoff: true) }
          }
          if currentVolume.isMounted, let path = currentVolume.mountPoint {
            Button("Open in Finder") {
              NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            Button("Copy Path") { MountPointActions.copyPath(path) }
            Button("Open in Terminal") { MountPointActions.openInTerminal(path) }
          }
          if rules.showsVerifyVolume {
            Button(
              rules.isVerifying
                ? NSLocalizedString(
                  "Verifying…", comment: "Volume context menu: verification in progress")
                : NSLocalizedString(
                  "Verify Volume", comment: "Volume context menu: verify volume action")
            ) {
              manager.verifyVolume(volume)
            }
            .disabled(rules.isVerifying)
          }
          if rules.showsRename, !rules.isVerifying {
            Button(
              NSLocalizedString(
                "Rename Volume…", comment: "Volume context menu: rename volume action")
            ) {
              manager.promptRenameVolume(volume)
            }
          }
        }

        Button(action: toggleMount) {
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
        VolumeContextMenu(
          volume: volume, state: state,
          toggleCustomMountPointEditor: toggleCustomMountPointEditor)
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

  /// Main action of the row: unmount a mounted volume, mount an unmounted one.
  private func toggleMount() {
    guard !isLoading, !state.isVerifying else { return }
    if currentVolume.isMounted {
      manager.unmountAskingAboutTimeMachine(currentVolume)
    } else {
      manager.mount(volume: currentVolume, trigger: .popover)
    }
  }

  private func toggleCustomMountPointEditor() {
    syncEditorStateFromPersistence()
    customMountPointEditor.expandedRowID = isCustomMountPointExpanded ? nil : editorRowID
  }

  private func syncEditorStateFromPersistence() {
    customMountPointEditor.sync(from: customMountPoint)
  }
}
