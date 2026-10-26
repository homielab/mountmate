//  Created by homielab.com

import SwiftUI

/// The General tab: one view per section, each owning its own state.
struct GeneralSettingsView: View {
  @EnvironmentObject var launchManager: LaunchAtLoginManager
  @StateObject private var fullDiskAccess = FullDiskAccessStatus()

  var body: some View {
    Form {
      DisplaySettingsSection()
      PermissionsSettingsSection(status: fullDiskAccess)
      BehaviorSettingsSection()
      KeepAliveSettingsSection()
      ShortcutsLanguageSettingsSection()
      LogsSettingsSection()
      AboutSettingsSection()
    }
    .formStyle(.grouped)
    .padding(.horizontal)
    // Pick up a Login Items approval or Full Disk Access granted in System Settings.
    .onAppear(perform: refreshStatus)
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    {
      _ in refreshStatus()
    }
  }

  private func refreshStatus() {
    launchManager.refreshStatus()
    fullDiskAccess.refresh()
  }
}
