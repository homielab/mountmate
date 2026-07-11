//  Created by homielab.com

import Sparkle
import SwiftUI

// MARK: - Dynamic Menu Bar Icon

struct MenuBarIconView: View {
  @ObservedObject var driveManager: DriveManager
  @ObservedObject var networkManager = NetworkMountManager.shared
  @AppStorage("showCountInMenuBar") private var showCountInMenuBar = false

  /// Determines the appropriate icon based on current state
  var currentIcon: String {
    // Priority 1: Show busy state during operations
    if driveManager.isUnmountingAll
      || driveManager.busyVolumeIdentifier != nil
      || driveManager.busyEjectingIdentifier != nil
    {
      return "externaldrive.fill.badge.timemachine"
    }

    // Priority 2: Show error state if there's an error
    if driveManager.userActionError != nil {
      return "externaldrive.fill.trianglebadge.exclamationmark"
    }

    // Default: normal icon
    return "externaldrive.fill"
  }
  
  var mountedCount: Int {
    let physicalCount = (driveManager.physicalDisks ?? [])
      .flatMap { $0.partitions + $0.containers.flatMap { $0.volumes } }
      .filter { $0.isMounted && $0.category == .user && !$0.isProtected }.count
    
    let networkCount = networkManager.mountedShareIDs.count
    let manualNetworkCount = networkManager.manuallyConnectedShares.count
    return physicalCount + networkCount + manualNetworkCount
  }

  var body: some View {
    let icon = currentIcon
    if showCountInMenuBar {
      HStack(spacing: 4) {
        Image(systemName: icon)
        Text("\(mountedCount)").font(.system(size: 13, weight: .medium, design: .rounded))
      }
    } else {
      Image(systemName: icon)
    }
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
  @StateObject private var hotkeyManager = HotkeyManager.shared

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
