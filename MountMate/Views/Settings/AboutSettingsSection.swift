//  Created by homielab.com

import SwiftUI

struct AboutSettingsSection: View {
  @EnvironmentObject var updaterViewModel: UpdaterController

  private var appVersion: String {
    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "N/A"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "N/A"
    return String(
      format: NSLocalizedString("Version %@ (%@)", comment: "App version and build number"),
      version, build)
  }

  var body: some View {
    Section {
      Link(destination: URL(string: "https://homielab.com/en/page/mountmate")!) {
        Label("Homepage", systemImage: "house.fill")
      }
      Link(destination: URL(string: "mailto:contact@homielab.com")!) {
        Label("Support Email", systemImage: "envelope.fill")
      }
      Link(destination: URL(string: "https://ko-fi.com/homielab")!) {
        Label(
          title: { Text("Donate") },
          icon: { Image(systemName: "heart.fill").foregroundStyle(.red) })
      }
      Toggle(isOn: $updaterViewModel.automaticallyChecksForUpdates) {
        Label("Automatically check for updates", systemImage: "clock.arrow.circlepath")
      }
      Button(action: { updaterViewModel.checkForUpdates() }) {
        Label("Check for Updates...", systemImage: "arrow.down.circle.fill")
      }
      .disabled(!updaterViewModel.canCheckForUpdates)
    } header: {
      Label("About & Updates", systemImage: "info.circle")
    }

    Text(appVersion)
      .font(.caption)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .center)
      .padding(.vertical, 4)
  }
}
