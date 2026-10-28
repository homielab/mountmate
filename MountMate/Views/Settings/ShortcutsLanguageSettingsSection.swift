//  Created by homielab.com

import SwiftUI

struct ShortcutsLanguageSettingsSection: View {
  @AppStorage("hotkeysEnabled") private var hotkeysEnabled = false

  @State private var selectedLanguage: String =
    ShortcutsLanguageSettingsSection
    .currentLanguageSelection()
  @State private var showRestartAlert = false
  @State private var showRelaunchFailedAlert = false
  @State private var recordingShortcut: HotkeyAction?
  @State private var showShortcutConflictAlert = false
  @State private var shortcutConflictMessage = ""

  /// Picker tag for "follow the system language" (no app-specific override).
  static let systemLanguageTag = "system"

  /// Language prefixes in match order. Ordered, so the specific Chinese
  /// variants are checked before the bare "zh" fallback.
  private static let languageMatchers: [(prefix: String, code: String)] = [
    ("zh-Hant", "zh-Hant"),
    ("zh-TW", "zh-Hant"),
    ("zh-HK", "zh-Hant"),
    ("zh-MO", "zh-Hant"),
    ("zh-Hans", "zh-Hans"),
    ("zh", "zh-Hans"),
    ("fr", "fr"),
    ("uk", "uk"),
    ("vi", "vi"),
    ("ru", "ru"),
    ("en", "en"),
  ]

  /// The language MountMate is set to: the app's own AppleLanguages
  /// override, or `systemLanguageTag` when it has none. (Reading
  /// UserDefaults.standard would also return the system-wide list.)
  private static func currentLanguageSelection() -> String {
    guard
      let bundleID = Bundle.main.bundleIdentifier,
      let languages = UserDefaults.standard.persistentDomain(forName: bundleID)?[
        "AppleLanguages"] as? [String],
      let firstLanguage = languages.first
    else { return systemLanguageTag }

    for matcher in languageMatchers
    where firstLanguage == matcher.prefix || firstLanguage.hasPrefix(matcher.prefix + "-") {
      return matcher.code
    }
    return "en"
  }

  var body: some View {
    Section {
      Toggle(isOn: $hotkeysEnabled) {
        Label("Enable Keyboard Shortcuts", systemImage: "keyboard")
      }
      .alert("Shortcut Already Assigned", isPresented: $showShortcutConflictAlert) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(shortcutConflictMessage)
      }

      if hotkeysEnabled {
        VStack(alignment: .leading, spacing: 8) {
          shortcutRow("Unmount All Volumes", action: .unmountAll)
          shortcutRow("Mount All Volumes", action: .mountAll)
          shortcutRow("Eject All External Disks", action: .ejectAll)
          Text(
            "Click a shortcut to record a new key combination. It must include ⌘ or ⌃. Some shortcuts may be reserved by macOS or another app."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
      }

      Picker(selection: $selectedLanguage) {
        Text("System Default").tag(Self.systemLanguageTag)
        Text("English").tag("en")
        Text("Français").tag("fr")
        Text("Українська").tag("uk")
        Text("Русский").tag("ru")
        Text("Tiếng Việt").tag("vi")
        Text("中文（简体）").tag("zh-Hans")
        Text("中文（繁體）").tag("zh-Hant")
      } label: {
        Label("Language", systemImage: "globe")
      }
      .pickerStyle(.menu)
      .onChange(of: selectedLanguage) { newLanguage in  // macOS 13-compatible form
        // Save right away, so the choice also applies when the user
        // restarts later instead of choosing "Restart Now".
        if newLanguage == Self.systemLanguageTag {
          UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
          UserDefaults.standard.set([newLanguage], forKey: "AppleLanguages")
        }
        showRestartAlert = true
      }
    } header: {
      Label("Shortcuts & Language", systemImage: "slider.horizontal.below.rectangle")
    }
    .alert("Restart Required", isPresented: $showRestartAlert) {
      Button("Restart Now", role: .destructive) { relaunchApp() }
      Button("Later", role: .cancel) {}
    } message: {
      Text("Please restart MountMate for the language change to take effect.")
    }
    .alert("Could Not Restart", isPresented: $showRelaunchFailedAlert) {
      Button("OK", role: .cancel) {}
    } message: {
      Text("MountMate could not restart itself. Open it again from Applications.")
    }
  }

  /// The language is already saved (see the picker's onChange).
  private func relaunchApp() {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    task.arguments = ["-n", Bundle.main.bundlePath]
    do {
      try task.run()
    } catch {
      Log.app.error("Could not relaunch MountMate: \(error.localizedDescription, privacy: .public)")
      showRelaunchFailedAlert = true
      return
    }
    NSApplication.shared.terminate(nil)
  }

  private func shortcutRow(_ description: LocalizedStringKey, action: HotkeyAction) -> some View {
    ShortcutRow(
      description: description, action: action, recordingShortcut: $recordingShortcut,
      hotkeysEnabled: hotkeysEnabled,
      onConflict: { message in
        shortcutConflictMessage = message
        showShortcutConflictAlert = true
      })
  }
}
