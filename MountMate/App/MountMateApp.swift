//  Created by homielab.com

import Sparkle
import SwiftUI

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
    MenuBarExtra("MountMate", systemImage: "externaldrive.fill") {
      PopoverContent {
        MainView()
      }
      .environmentObject(driveManager)
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
