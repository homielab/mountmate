//  Created by homielab.com

import SwiftUI

struct HeaderActionsView: View {
  @EnvironmentObject var driveManager: DriveManager
  @EnvironmentObject var updaterViewModel: UpdaterController

  /// Matches exactly what unmountAllDrives() acts on (removable disks only).
  private var canUnmountAll: Bool {
    !driveManager.unmountAllCandidates.isEmpty
  }

  /// Matches what ejectAllDisks() acts on (external physical disks).
  private var canEjectAll: Bool {
    !driveManager.ejectAllCandidates.isEmpty
  }

  private var isEjectingAny: Bool {
    !driveManager.busyEjectingDiskIDs.isEmpty
  }

  var body: some View {
    HStack(spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: "externaldrive.connected.to.line.below")
          .font(.title3)
          .foregroundStyle(.blue)
          .accessibilityHidden(true)

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
        .accessibilityLabel(
          allCollapsed
            ? Text("Expand All") : Text("Collapse All"))

        // Unmount All Button
        Button(action: {
          guard !driveManager.isUnmountingAll else { return }
          driveManager.unmountAllAskingAboutTimeMachine()
        }) {
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
        .accessibilityLabel(Text("Unmount All"))
        .accessibilityValue(Text.busyValue(driveManager.isUnmountingAll))
        .disabled(!canUnmountAll || driveManager.isUnmountingAll)

        // Eject All External Disks Button
        Button(action: { driveManager.ejectAllAskingAboutTimeMachine() }) {
          Group {
            if isEjectingAny {
              ProgressView().controlSize(.small)
            } else {
              Image(systemName: "eject.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(canEjectAll ? Color.orange : Color.secondary.opacity(0.4))
            }
          }
          .frame(width: 28, height: 28)
          .background(Color.primary.opacity(0.06))
          .clipShape(.rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString("Eject All External Disks", comment: "Tooltip"))
        .accessibilityLabel(Text("Eject All External Disks"))
        .accessibilityValue(Text.busyValue(isEjectingAny))
        .disabled(!canEjectAll || isEjectingAny)

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
          .accessibilityLabel(Text("Settings"))
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
          .accessibilityLabel(Text("Settings"))
        }

        // Refresh Button
        Button(action: {
          driveManager.refreshDrives(qos: .userInitiated)
          NetworkMountManager.shared.refreshMountStatus()
        }) {
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
        .accessibilityLabel(Text("Refresh Drives"))
        .accessibilityValue(Text.busyValue(driveManager.isRefreshing))
        .disabled(driveManager.isRefreshing)

        // Check for Updates Button
        Button(action: { updaterViewModel.checkForUpdates() }) {
          Image(systemName: "arrow.down.circle")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(updaterViewModel.canCheckForUpdates ? Color.primary : Color.secondary)
            .frame(width: 28, height: 28)
            .background(Color.primary.opacity(0.06))
            .clipShape(.rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString("Check for Updates...", comment: "Tooltip"))
        .accessibilityLabel(Text("Check for Updates..."))
        .disabled(!updaterViewModel.canCheckForUpdates)

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
        .accessibilityLabel(Text("Quit MountMate"))
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
