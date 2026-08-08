//  Created by homielab.com

import AppKit
import SwiftUI

struct MainView: View {
  @EnvironmentObject var driveManager: DriveManager
  @ObservedObject var persistence = PersistenceManager.shared
  @ObservedObject var networkManager = NetworkMountManager.shared
  @ObservedObject private var customMountPointEditor = CustomMountPointEditorState.shared

  private var internalDisks: [PhysicalDisk] {
    (driveManager.physicalDisks ?? []).filter { $0.type == .internalDisk && $0.hasVisibleContent }
  }
  private var externalDisks: [PhysicalDisk] {
    (driveManager.physicalDisks ?? []).filter { $0.type == .physical && $0.hasVisibleContent }
  }
  private var diskImages: [PhysicalDisk] {
    (driveManager.physicalDisks ?? []).filter { $0.type == .diskImage && $0.hasVisibleContent }
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
      driveManager.refreshDrives()
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
