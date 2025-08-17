//  Created by homielab.com

import SwiftUI

struct HeaderActionsView: View {
    @ObservedObject var driveManager: DriveManager
    var onShowSettings: () -> Void
    var onRefresh: () -> Void

    private var canUnmountAll: Bool {
        driveManager.physicalDisks.flatMap { $0.volumes }.contains { $0.isMounted && $0.category == .user }
    }

    var body: some View {
        HStack {
            Text("MountMate").font(.headline)
            Spacer()

            Button(action: { driveManager.unmountAllDrives() }) {
                Image(systemName: "eject.circle.fill").opacity(driveManager.isUnmountingAll ? 0 : 1)
            }
            .buttonStyle(.plain).help(NSLocalizedString("Unmount All", comment: "Unmount All button tooltip"))
            .disabled(!canUnmountAll || driveManager.isUnmountingAll)
            .overlay { if driveManager.isUnmountingAll { ProgressView().controlSize(.small) } }

            Button(action: onShowSettings) { Image(systemName: "gearshape.fill") }
                .buttonStyle(.plain).help("Settings")

            Button(action: onRefresh) {
                if driveManager.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.plain).help("Refresh Drives")
            .disabled(driveManager.isRefreshing)

            Button(action: { NSApplication.shared.terminate(nil) }) { Image(systemName: "power").foregroundColor(.red) }
                .buttonStyle(.plain).help(NSLocalizedString("Quit MountMate", comment: "Quit button tooltip"))
        }
        .padding()
    }
}
