//  Created by homielab.com

import Combine
import SwiftUI

struct DriveListView: View {
  let pinnedVolumes: [Volume]
  let internalDisks: [PhysicalDisk]
  let externalDisks: [PhysicalDisk]
  let diskImages: [PhysicalDisk]
  let networkShares: [NetworkShare]
  let manualShares: [NetworkShare]
  /// Not observed: typing in the editor must not redraw the whole list.
  /// Only `expandedRowID` is mirrored below.
  let customMountPointEditor: CustomMountPointEditorState
  @EnvironmentObject private var manager: DriveManager
  @ObservedObject private var persistence = PersistenceManager.shared
  @ObservedObject private var keepAliveManager = KeepAliveManager.shared
  @State private var expandedEditorRowID: String?
  // Read here so the rows redraw when the warning setting changes.
  @AppStorage(LowSpaceRules.enabledKey) private var lowSpaceEnabled = true
  @AppStorage(LowSpaceRules.thresholdKey) private var lowSpacePercent = LowSpaceRules.defaultPercent

  init(
    pinnedVolumes: [Volume], internalDisks: [PhysicalDisk], externalDisks: [PhysicalDisk],
    diskImages: [PhysicalDisk], networkShares: [NetworkShare], manualShares: [NetworkShare],
    customMountPointEditor: CustomMountPointEditorState
  ) {
    self.pinnedVolumes = pinnedVolumes
    self.internalDisks = internalDisks
    self.externalDisks = externalDisks
    self.diskImages = diskImages
    self.networkShares = networkShares
    self.manualShares = manualShares
    self.customMountPointEditor = customMountPointEditor
    // Start from the current value so rows know on their first appearance
    // whether their editor is open (onReceive only updates it afterwards).
    _expandedEditorRowID = State(initialValue: customMountPointEditor.expandedRowID)
  }

  private var pinnedEditorRowIDs: [String] {
    pinnedVolumes.map { VolumeRowView.editorRowID(for: $0, context: .pinned) }
  }

  /// Row state of every listed volume, computed once per render.
  private var listState: VolumeListState {
    let reconnecting = keepAliveManager.reconnectingVolumeIDs
    let savedPasswords = manager.volumeIDsWithSavedPassword
    let lowSpaceThreshold = LowSpaceRules.threshold()
    let verifying = manager.verifyingVolumeIDs
    var rowStates: [String: VolumeRowState] = [:]
    // Pinned volumes come from these disks too.
    for disk in internalDisks + externalDisks + diskImages {
      for volume in disk.allVolumes {
        rowStates[volume.id] = VolumeRowState(
          isPinned: persistence.isPinned(volume),
          isKeepAlive: persistence.isVolumeKeepAlive(volume),
          isReconnecting: volume.compositeId.map { reconnecting.contains($0) } ?? false,
          customMountPoint: persistence.customMountPoint(for: volume)?.mountPoint,
          hasSavedPassword: savedPasswords.contains(volume.id),
          canUnmountWhenIdle: disk.type == .physical && volume.category == .user
            && volume.compositeId != nil,
          idleUnmountMinutes: persistence.idleUnmountMinutes(for: volume),
          lowSpace: LowSpaceRules.warning(
            for: volume, on: disk.type, threshold: lowSpaceThreshold),
          isExternalDisk: disk.type == .physical,
          isVerifying: verifying.contains(volume.id))
      }
    }
    return VolumeListState(
      rowStates: rowStates,
      busyVolumeIDs: manager.busyVolumeIDs,
      expandedEditorRowID: expandedEditorRowID)
  }

  var body: some View {
    let listState = self.listState
    List {
      if !pinnedVolumes.isEmpty {
        Section(header: Label("Pinned", systemImage: "pin.fill")) {
          ForEach(pinnedVolumes) { volume in
            VolumeRowView(
              volume: volume,
              context: .pinned,
              listState: listState,
              customMountPointEditor: customMountPointEditor)
          }
        }
      }
      if !internalDisks.isEmpty {
        Section(header: Label("Internal Disks", systemImage: "internaldrive")) {
          ForEach(internalDisks) { disk in
            DiskAndVolumesView(
              disk: disk,
              listState: listState,
              customMountPointEditor: customMountPointEditor)
          }
        }
      }
      if !externalDisks.isEmpty {
        Section(header: Label("External Disks", systemImage: "externaldrive.fill")) {
          ForEach(externalDisks) { disk in
            DiskAndVolumesView(
              disk: disk,
              listState: listState,
              customMountPointEditor: customMountPointEditor)
          }
        }
      }
      if !diskImages.isEmpty {
        Section(header: Label("Disk Images", systemImage: "opticaldisc")) {
          ForEach(diskImages) { disk in
            DiskAndVolumesView(
              disk: disk,
              listState: listState,
              customMountPointEditor: customMountPointEditor)
          }
        }
      }
      if !networkShares.isEmpty {
        Section(header: Label("Saved Network Shares", systemImage: "server.rack")) {
          ForEach(networkShares) { share in NetworkShareMainRow(share: share) }
        }
      }
      if !manualShares.isEmpty {
        Section(header: ManualSharesSectionHeader()) {
          ForEach(manualShares) { share in NetworkShareMainRow(share: share, isManual: true) }
        }
      }
    }
    .listStyle(.sidebar)
    .frame(minHeight: 50)
    .onReceive(customMountPointEditor.$expandedRowID.removeDuplicates()) { rowID in
      expandedEditorRowID = rowID
    }
    // Close an editor opened in the Pinned section once its row is gone
    // (unpinned here or in Settings, or the disk was disconnected).
    // macOS 13-compatible onChange form.
    .onChange(of: pinnedEditorRowIDs) { rowIDs in closeStalePinnedEditor(rowIDs) }
    .onAppear { closeStalePinnedEditor(pinnedEditorRowIDs) }
  }

  private func closeStalePinnedEditor(_ pinnedRowIDs: [String]) {
    if let rowID = customMountPointEditor.expandedRowID,
      rowID.hasPrefix(VolumeRowContext.pinned.rawValue + ":"), !pinnedRowIDs.contains(rowID)
    {
      customMountPointEditor.collapse()
    }
  }
}
