//  Created by homielab.com

import SwiftUI

/// Whether Full Disk Access is granted; `nil` until the first check finishes.
final class FullDiskAccessStatus: ObservableObject {
  @Published var granted: Bool?

  /// Re-reads the permission, e.g. after it was granted in System Settings.
  func refresh() {
    guard FullDiskAccessChecker.isApplicable else { return }
    DispatchQueue.global(qos: .userInitiated).async {
      let granted = FullDiskAccessChecker.currentlyGranted()
      DispatchQueue.main.async { self.granted = granted }
    }
  }
}

struct PermissionsSettingsSection: View {
  @ObservedObject var status: FullDiskAccessStatus

  var body: some View {
    if FullDiskAccessChecker.isApplicable, let granted = status.granted {
      Section {
        LabeledContent {
          HStack(spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
              .foregroundStyle(granted ? Color.green : Color.orange)
              .accessibilityHidden(true)
            Text(granted ? "Granted" : "Not Granted")
            if !granted {
              Button("Open System Settings") { FullDiskAccessChecker.openSystemSettings() }
                .controlSize(.small)
            }
          }
        } label: {
          Label("Full Disk Access", systemImage: "lock.shield")
        }
        .help(
          "Full Disk Access lets MountMate see every disk type and read storage details. Turn it on for MountMate in System Settings > Privacy & Security."
        )
      } header: {
        Label("Permissions", systemImage: "hand.raised")
      }
    }
  }
}
