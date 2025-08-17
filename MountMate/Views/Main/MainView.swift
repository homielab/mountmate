//  Created by homielab.com

import SwiftUI

struct MainView: View {
    @StateObject private var driveManager = DriveManager.shared
    @Environment(\.openWindow) var openWindow

    var body: some View {
        VStack(spacing: 0) {
            HeaderActionsView(
                driveManager: driveManager,
                onShowSettings: openAndFocusSettingsWindow,
                onRefresh: { driveManager.refreshDrives() }
            )
            
            if driveManager.physicalDisks.isEmpty {
                noDrivesView
            } else {
                DriveListView(driveManager: driveManager)
            }
        }
        .frame(width: 370)
        .padding(.bottom, 8)
    }
    
    private func openAndFocusSettingsWindow() {
        let settingsWindowTitle = NSLocalizedString("MountMate Settings", comment: "")
        if let window = NSApp.windows.first(where: { $0.title == settingsWindowTitle }) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            openWindow(id: "settings-window")
        }
    }

    private var noDrivesView: some View {
        VStack(spacing: 8) {
            Image(systemName: "externaldrive.fill.badge.questionmark").font(.system(size: 40)).foregroundColor(.secondary)
            Text(NSLocalizedString("No Drives Found", comment: "Empty state title")).font(.headline)
            Text(NSLocalizedString("Connect a USB drive, SD card, or mount a disk image to see it here.", comment: "Empty state description"))
                .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal)
        }
        .frame(height: 150)
    }
}
