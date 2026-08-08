//  Created by homielab.com

import SwiftUI

struct HeaderActionsView: View {
  @EnvironmentObject var driveManager: DriveManager

  private var canUnmountAll: Bool {
    (driveManager.physicalDisks ?? []).flatMap(\.allVolumes)
      .contains { $0.isMounted && $0.category == .user && !$0.isProtected }
  }

  var body: some View {
    HStack {
      Text("MountMate").font(.headline)
      Spacer()

      // Global Expand/Collapse Button
      Button(action: toggleExpansion) {
        Image(
          systemName: allCollapsed
            ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
      }
      .buttonStyle(.plain)
      .help(
        allCollapsed
          ? NSLocalizedString("Expand All", comment: "Tooltip")
          : NSLocalizedString("Collapse All", comment: "Tooltip")
      )
      .accessibilityLabel(
        allCollapsed
          ? NSLocalizedString("Expand All", comment: "Accessibility label")
          : NSLocalizedString("Collapse All", comment: "Accessibility label"))

      // Unmount All Button
      Button(action: { driveManager.unmountAllDrives() }) {
        if driveManager.isUnmountingAll {
          ProgressView().controlSize(.small)
        } else {
          Image(systemName: "eject.circle.fill")
        }
      }
      .buttonStyle(.plain)
      .help(NSLocalizedString("Unmount All", comment: "Tooltip"))
      .accessibilityLabel(NSLocalizedString("Unmount All", comment: "Accessibility label"))
      .disabled(!canUnmountAll || driveManager.isUnmountingAll)

      // Settings Button
      if #available(macOS 14.0, *) {
        SettingsLink {
          Image(systemName: "gearshape.fill")
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString("Settings", comment: "Tooltip"))
        .accessibilityLabel(NSLocalizedString("Settings", comment: "Accessibility label"))
        .simultaneousGesture(
          TapGesture().onEnded {
            focusSettingsWindow()
          })
      } else {
        Button(action: {
          NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
          NSApp.activate(ignoringOtherApps: true)
        }) {
          Image(systemName: "gearshape.fill")
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString("Settings", comment: "Tooltip"))
        .accessibilityLabel(NSLocalizedString("Settings", comment: "Accessibility label"))
      }

      // Refresh Button
      Button(action: { driveManager.refreshDrives(qos: .userInitiated) }) {
        if driveManager.isRefreshing {
          ProgressView().controlSize(.small)
        } else {
          Image(systemName: "arrow.clockwise")
        }
      }
      .buttonStyle(.plain)
      .help(NSLocalizedString("Refresh Drives", comment: "Tooltip"))
      .accessibilityLabel(NSLocalizedString("Refresh Drives", comment: "Accessibility label"))
      .disabled(driveManager.isRefreshing)

      // Quit Button
      Button(action: { NSApplication.shared.terminate(nil) }) {
        Image(systemName: "power").foregroundColor(.red)
      }
      .buttonStyle(.plain)
      .help(NSLocalizedString("Quit MountMate", comment: "Tooltip"))
      .accessibilityLabel(NSLocalizedString("Quit MountMate", comment: "Accessibility label"))
    }

    .frame(width: 320)
    .padding()
  }

  @State private var allCollapsed = false

  private func toggleExpansion() {
    allCollapsed.toggle()
    driveManager.driveExpansionSubject.send(!allCollapsed)
  }

  private func focusSettingsWindow() {
    let settingsID = "com_apple_SwiftUI_Settings_window"

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      if let settingsWindow = NSApp.windows.first(where: { $0.identifier?.rawValue == settingsID })
      {
        settingsWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
      }
    }
  }
}
