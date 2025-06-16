//
//  Created by homielab
//

import SwiftUI
import Sparkle

final class UpdaterController: NSObject, ObservableObject {
    private let updater: SPUUpdater
    
    init(updater: SPUUpdater) {
        self.updater = updater
        super.init()
    }
    
    @objc func checkForUpdates() {
        updater.checkForUpdates()
    }
}

@main
struct MountMateApp: App {
    @StateObject private var launchManager = LaunchAtLoginManager()
    @StateObject private var diskMounter = DiskMounter()
    @StateObject private var updaterViewModel: UpdaterController

    init() {
        let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        _updaterViewModel = StateObject(wrappedValue: UpdaterController(updater: updater.updater))
    }

    var body: some Scene {
        MenuBarExtra("MountMate", systemImage: "externaldrive.fill.badge.plus") {
            MainView()
                .environmentObject(launchManager)
                .environmentObject(updaterViewModel)
        }
        .menuBarExtraStyle(.window)
        
        Window(NSLocalizedString("MountMate Settings", comment: ""), id: "settings-window") {
            SettingsView()
                .environmentObject(launchManager)
                .environmentObject(diskMounter)
                .environmentObject(updaterViewModel)
        }
        .windowResizability(.contentSize)
    }
}
