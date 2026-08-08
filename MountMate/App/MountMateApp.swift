//  Created by homielab.com

import Sparkle
import SwiftUI

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
