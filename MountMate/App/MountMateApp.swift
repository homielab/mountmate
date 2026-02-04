//  Created by homielab.com

import Sparkle
import SwiftUI

// MARK: - Dynamic Menu Bar Icon

struct MenuBarIconView: View {
  @ObservedObject var driveManager: DriveManager

  /// Determines the appropriate icon based on current state
  var currentIcon: String {
    // Priority 1: Show busy state during operations
    if driveManager.isUnmountingAll
        || driveManager.busyVolumeIdentifier != nil
        || driveManager.busyEjectingIdentifier != nil {
      return "externaldrive.fill.badge.timemachine"
    }

    // Priority 2: Show error state if there's an error
    if driveManager.userActionError != nil {
      return "externaldrive.fill.trianglebadge.exclamationmark"
    }

    // Default: normal icon
    return "externaldrive.fill"
  }

  var body: some View {
    let icon = currentIcon
    #if DEBUG
    let _ = print("MenuBarIcon: \(icon)")
    #endif
    return Image(systemName: icon)
  }
}

// MARK: - App Entry Point

@main
struct MountMateApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  @StateObject private var driveManager = DriveManager.shared
  @StateObject private var launchManager = LaunchAtLoginManager()
  @StateObject private var diskMounter = DiskMounter()
  @StateObject private var updaterViewModel: UpdaterController

  init() {
    let updater = SPUStandardUpdaterController(
      startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    _updaterViewModel = StateObject(wrappedValue: UpdaterController(updater: updater.updater))
  }

  var body: some Scene {
    MenuBarExtra {
      PopoverContent {
        MainView()
      }
      .environmentObject(driveManager)
    } label: {
      MenuBarIconView(driveManager: driveManager)
    }
    .menuBarExtraStyle(.window)

    Settings {
      SettingsView()
        .environmentObject(launchManager)
        .environmentObject(diskMounter)
        .environmentObject(updaterViewModel)
    }
  }
}
