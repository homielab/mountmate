//  Created by homielab.com

import SwiftUI

struct HeaderActionsView: View {
  @EnvironmentObject var driveManager: DriveManager

  private var canUnmountAll: Bool {
    (driveManager.physicalDisks ?? []).flatMap(\.allVolumes)
      .contains { $0.isMounted && $0.category == .user && !$0.isProtected }
  }

  var body: some View {
    HStack(spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: "externaldrive.connected.to.line.below")
          .font(.title3)
          .foregroundStyle(.blue)

        Text("MountMate")
          .font(.headline)
          .bold()
      }

      Spacer()

      HStack(spacing: 4) {
        // Global Expand/Collapse Button
        Button(action: toggleExpansion) {
          Image(
            systemName: allCollapsed
              ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left"
          )
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.primary)
          .frame(width: 28, height: 28)
          .background(Color.primary.opacity(0.06))
          .clipShape(.rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(
          allCollapsed
            ? NSLocalizedString("Expand All", comment: "Tooltip")
            : NSLocalizedString("Collapse All", comment: "Tooltip")
        )

        // Unmount All Button
        Button(action: { driveManager.unmountAllDrives() }) {
          Group {
            if driveManager.isUnmountingAll {
              ProgressView().controlSize(.small)
            } else {
              Image(systemName: "eject.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(canUnmountAll ? Color.red : Color.secondary.opacity(0.4))
            }
          }
          .frame(width: 28, height: 28)
          .background(Color.primary.opacity(0.06))
          .clipShape(.rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString("Unmount All", comment: "Tooltip"))
        .disabled(!canUnmountAll || driveManager.isUnmountingAll)

        // Settings Button
        if #available(macOS 14.0, *) {
          SettingsLink {
            Image(systemName: "gearshape.fill")
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(.primary)
              .frame(width: 28, height: 28)
              .background(Color.primary.opacity(0.06))
              .clipShape(.rect(cornerRadius: 6))
          }
          .buttonStyle(.plain)
          .help(NSLocalizedString("Settings", comment: "Tooltip"))
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
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(.primary)
              .frame(width: 28, height: 28)
              .background(Color.primary.opacity(0.06))
              .clipShape(.rect(cornerRadius: 6))
          }
          .buttonStyle(.plain)
          .help(NSLocalizedString("Settings", comment: "Tooltip"))
        }

        // Refresh Button
        Button(action: { driveManager.refreshDrives(qos: .userInitiated) }) {
          Group {
            if driveManager.isRefreshing {
              ProgressView().controlSize(.small)
            } else {
              Image(systemName: "arrow.clockwise")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            }
          }
          .frame(width: 28, height: 28)
          .background(Color.primary.opacity(0.06))
          .clipShape(.rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString("Refresh Drives", comment: "Tooltip"))
        .disabled(driveManager.isRefreshing)

        // Quit Button
        Button(action: { NSApplication.shared.terminate(nil) }) {
          Image(systemName: "power")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.red)
            .frame(width: 28, height: 28)
            .background(Color.red.opacity(0.1))
            .clipShape(.rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString("Quit MountMate", comment: "Tooltip"))
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)

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
