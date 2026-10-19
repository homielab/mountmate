//  Created by homielab.com

import AppKit
import SwiftUI

struct MainView: View {
  @EnvironmentObject var driveManager: DriveManager
  @ObservedObject var persistence = PersistenceManager.shared
  @ObservedObject var networkManager = NetworkMountManager.shared
  // Not observed: the list mirrors the editor state it needs, so typing in
  // the editor does not redraw this view.
  private let customMountPointEditor = CustomMountPointEditorState.shared

  private var internalDisks: [PhysicalDisk] {
    (driveManager.physicalDisks ?? []).filter { $0.type == .internalDisk && $0.hasVisibleContent }
  }
  private var externalDisks: [PhysicalDisk] {
    (driveManager.physicalDisks ?? []).filter { $0.type == .physical && $0.hasVisibleContent }
  }
  private var diskImages: [PhysicalDisk] {
    (driveManager.physicalDisks ?? []).filter { $0.type == .diskImage && $0.hasVisibleContent }
  }

  /// Pinned volumes from the visible disks, in pin order.
  private var pinnedVolumes: [Volume] {
    let pins = persistence.pinnedVolumeIDs
    guard !pins.isEmpty else { return [] }
    let volumes = (internalDisks + externalDisks + diskImages).flatMap(\.allVolumes)
    return pins.compactMap { id in volumes.first { $0.compositeId == id } }
  }

  private var hasVisibleDisks: Bool {
    !internalDisks.isEmpty || !externalDisks.isEmpty || !diskImages.isEmpty
      || !persistence.networkShares.isEmpty || !networkManager.manuallyConnectedShares.isEmpty
  }

  var body: some View {
    VStack(spacing: 0) {
      HeaderActionsView()

      if let error = driveManager.refreshError {
        ErrorBannerView(message: error)
      }

      if driveManager.physicalDisks == nil {
        LoadingView()
      } else if !hasVisibleDisks {
        noDrivesView
      } else {
        DriveListView(
          pinnedVolumes: pinnedVolumes,
          internalDisks: internalDisks,
          externalDisks: externalDisks,
          diskImages: diskImages,
          networkShares: persistence.networkShares,
          manualShares: networkManager.manuallyConnectedShares,
          customMountPointEditor: customMountPointEditor
        )
      }
    }
    .frame(width: 350)
    .padding(.bottom, 8)
    .background(
      HostingWindowReader { window in
        customMountPointEditor.hostWindow = window
      }
    )
    .onAppear {
      NSApp.activate(ignoringOtherApps: true)
      // The user is looking at the list right now, so don't refresh at
      // background priority.
      driveManager.refreshDrives(qos: .userInitiated)
      networkManager.refreshMountStatus()
    }
  }

  private var noDrivesView: some View {
    VStack(spacing: 8) {
      Image(systemName: "externaldrive.fill.badge.questionmark").font(.system(size: 40))
        .foregroundColor(.secondary)
      Text(NSLocalizedString("No Drives Found", comment: "Empty state title")).font(.headline)
      Text(
        NSLocalizedString(
          "Connect a USB drive, SD card, or mount a disk image to see it here.",
          comment: "Empty state description")
      )
      .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center).padding(
        .horizontal)
    }
    .padding(.vertical, 40)
  }
}
