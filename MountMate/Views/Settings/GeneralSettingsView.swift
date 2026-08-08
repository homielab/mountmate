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
        Toggle(isOn: $showCountInMenuBar) {
          Label("Show Count in Menu Bar", systemImage: "number.square")
        }
        Toggle(isOn: $showInternalDisks) {
          Label("Show Internal Disks", systemImage: "internaldrive")
        }
        Toggle(isOn: $showOnlyVolumes) {
          Label("Show Only Volumes", systemImage: "externaldrive")
        }
      } header: {
        Label("Display", systemImage: "macwindow")
      }

      Section {
        Toggle(isOn: $launchManager.isEnabled) {
          Label("Start MountMate at Login", systemImage: "arrow.right.circle")
        }
        Toggle(isOn: $diskMounter.blockUSBAutoMount) {
          Label("Block USB Auto-Mount", systemImage: "hand.raised.slash")
        }
        Toggle(isOn: $ejectOnSleepEnabled) {
          Label("Unmount All Disks on Sleep", systemImage: "moon.zzz")
        }
      } header: {
        Label("Behavior", systemImage: "gearshape")
      }

      Section {
        Toggle(isOn: $hotkeysEnabled) {
          Label("Enable Keyboard Shortcuts", systemImage: "keyboard")
        }
        .onChange(of: hotkeysEnabled) { enabled in
          if enabled {
            if !HotkeyManager.checkAccessibilityPermissions() {
              showAccessibilityAlert = true
            }
          }
        }

        if hotkeysEnabled {
          VStack(alignment: .leading, spacing: 6) {
            shortcutRow(key: "⌘ ⇧ U", description: "Unmount All Volumes")
            shortcutRow(key: "⌘ ⇧ M", description: "Mount All Volumes")
          }
          .padding(.vertical, 2)
        }

        Picker(selection: $selectedLanguage) {
          Text("English").tag("en")
          Text("Français").tag("fr")
          Text("Українська").tag("uk")
          Text("Русский").tag("ru")
          Text("Tiếng Việt").tag("vi")
          Text("中文（简体）").tag("zh-Hans")
          Text("中文（繁体）").tag("zh-Hant")
        } label: {
          Label("Language", systemImage: "globe")
        }
        .pickerStyle(.menu)
        .onChange(of: selectedLanguage) { _ in showRestartAlert = true }
      } header: {
        Label("Shortcuts & Language", systemImage: "slider.horizontal.below.rectangle")
      }

      Section {
        Link(destination: URL(string: "https://homielab.com/page/mountmate")!) {
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
        Button(action: { updaterViewModel.checkForUpdates() }) {
          Label("Check for Updates...", systemImage: "arrow.down.circle.fill")
        }
      } header: {
        Label("About & Updates", systemImage: "info.circle")
      }

      Text(appVersion)
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 4)
    }
    .formStyle(.grouped)
    .padding(.horizontal)

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

  private func shortcutRow(key: String, description: LocalizedStringKey) -> some View {
    HStack(spacing: 8) {
      Text(key)
        .font(.system(.caption, design: .monospaced))
        .bold()
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.primary.opacity(0.08))
        .clipShape(.rect(cornerRadius: 4))
      Text(description)
        .font(.caption)
        .foregroundStyle(.secondary)
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
