//  Created by homielab.com

import SwiftUI

struct GeneralSettingsView: View {
  @EnvironmentObject var launchManager: LaunchAtLoginManager
  @EnvironmentObject var diskMounter: DiskMounter
  @EnvironmentObject var updaterViewModel: UpdaterController

  @AppStorage("ejectOnSleepEnabled") private var ejectOnSleepEnabled = false
  @AppStorage("showInternalDisks") private var showInternalDisks = false
  @AppStorage("showOnlyVolumes") private var showOnlyVolumes = false
  @AppStorage("hotkeysEnabled") private var hotkeysEnabled = false
  @AppStorage("showCountInMenuBar") private var showCountInMenuBar = false

  @State private var selectedLanguage: String = {
    guard
      let preferredLanguages = UserDefaults.standard.array(forKey: "AppleLanguages")
        as? [String],
      let firstLanguage = preferredLanguages.first
    else { return "en" }

    let languagePrefixes: [String: String] = [
      "fr": "fr",
      "uk": "uk",
      "vi": "vi",
      "ru": "ru",
      "zh-Hant": "zh-Hant",
      "zh-TW": "zh-Hant",
      "zh-HK": "zh-Hant",
      "zh-MO": "zh-Hant",
      "zh": "zh-Hans",
    ]

    for (prefix, code) in languagePrefixes {
      if firstLanguage.starts(with: prefix) {
        return code
      }
    }
    return "en"
  }()

  @State private var showRestartAlert = false
  @State private var showAccessibilityAlert = false

  private var appVersion: String {
    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "N/A"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "N/A"
    return "Version \(version) (\(build))"
  }

  var body: some View {
    Form {
      Section {
        Toggle("Show Count in Menu Bar", isOn: $showCountInMenuBar)
        Toggle("Show Internal Disks", isOn: $showInternalDisks)
        Toggle("Show Only Volumes", isOn: $showOnlyVolumes)
        Toggle("Start MountMate at Login", isOn: $launchManager.isEnabled)
        Toggle("Block USB Auto-Mount", isOn: $diskMounter.blockUSBAutoMount)
        Toggle("Unmount All Disks on Sleep", isOn: $ejectOnSleepEnabled)
        Toggle("Enable Keyboard Shortcuts", isOn: $hotkeysEnabled)
          .onChange(of: hotkeysEnabled) { enabled in
            if enabled {
              // Check if accessibility permission is granted
              if !HotkeyManager.checkAccessibilityPermissions() {
                showAccessibilityAlert = true
              }
            }
          }
        if hotkeysEnabled {
          VStack(alignment: .leading, spacing: 4) {
            Text("⌘⇧U - Unmount All Volumes")
            Text("⌘⇧M - Mount All Volumes")
          }
          .font(.caption)
          .foregroundColor(.secondary)
          .padding(.leading, 4)
        }
        Picker("Language", selection: $selectedLanguage) {
          Text("English").tag("en")
          Text("Français").tag("fr")
          Text("Українська").tag("uk")
          Text("Русский").tag("ru")
          Text("Tiếng Việt").tag("vi")
          Text("中文（简体）").tag("zh-Hans")
          Text("中文（繁体）").tag("zh-Hant")
        }
        .pickerStyle(.menu)
        .onChange(of: selectedLanguage) { _ in showRestartAlert = true }
      }

      Section("About & Updates") {
        Link(destination: URL(string: "https://homielab.com/page/mountmate")!) {
          Label("Homepage", systemImage: "house.fill")
        }
        Link(destination: URL(string: "mailto:contact@homielab.com")!) {
          Label("Support Email", systemImage: "envelope.fill")
        }
        Link(destination: URL(string: "https://ko-fi.com/homielab")!) {
          Label(
            title: { Text("Donate") },
            icon: { Image(systemName: "heart.fill").foregroundColor(.red) })
        }
        Button(action: { updaterViewModel.checkForUpdates() }) {
          Label("Check for Updates...", systemImage: "arrow.down.circle.fill")
        }
      }
      .foregroundColor(.primary)

      Text(appVersion).font(.caption).foregroundColor(.secondary).frame(
        maxWidth: .infinity, alignment: .center)
    }
    .formStyle(.grouped)
    .padding()
    .alert("Restart Required", isPresented: $showRestartAlert) {
      Button("Restart Now", role: .destructive) { relaunchApp() }
      Button("Later", role: .cancel) {}
    } message: {
      Text("Please restart MountMate for the language change to take effect.")
    }
    .alert("Accessibility Permission Required", isPresented: $showAccessibilityAlert) {
      Button("Open System Settings") {
        if let url = URL(
          string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        {
          NSWorkspace.shared.open(url)
        }
      }
      Button("Later", role: .cancel) {}
    } message: {
      Text(
        "To use keyboard shortcuts, please grant MountMate Accessibility access in System Settings → Privacy & Security → Accessibility."
      )
    }
  }

  private func relaunchApp() {
    UserDefaults.standard.set([selectedLanguage], forKey: "AppleLanguages")
    let url = URL(fileURLWithPath: Bundle.main.resourcePath!)
    let path = url.deletingLastPathComponent().deletingLastPathComponent().absoluteString
    let task = Process()
    task.launchPath = "/usr/bin/open"
    task.arguments = ["-n", path]
    task.launch()
    NSApplication.shared.terminate(self)
  }
}
