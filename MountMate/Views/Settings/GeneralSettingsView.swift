//  Created by homielab.com

import SwiftUI

struct GeneralSettingsView: View {
  @EnvironmentObject var launchManager: LaunchAtLoginManager
  @EnvironmentObject var diskMounter: DiskMounter
  @EnvironmentObject var updaterViewModel: UpdaterController
  @ObservedObject private var keepAliveManager = KeepAliveManager.shared
  @ObservedObject private var hotkeyManager = HotkeyManager.shared
  @ObservedObject private var persistence = PersistenceManager.shared

  @AppStorage("ejectOnSleepEnabled") private var ejectOnSleepEnabled = false
  @AppStorage("showInternalDisks") private var showInternalDisks = false
  @AppStorage("showOnlyVolumes") private var showOnlyVolumes = false
  @AppStorage("hotkeysEnabled") private var hotkeysEnabled = false
  @AppStorage("showCountInMenuBar") private var showCountInMenuBar = false

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

  @State private var selectedLanguage: String = GeneralSettingsView.currentLanguageSelection()

  @State private var showRestartAlert = false
  @State private var recordingShortcut: HotkeyAction?
  @State private var showShortcutConflictAlert = false
  @State private var shortcutConflictMessage = ""

  private var appVersion: String {
    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "N/A"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "N/A"
    return String(
      format: NSLocalizedString("Version %@ (%@)", comment: "App version and build number"),
      version, build)
  }

  static func retryIntervalLabel(_ interval: Double) -> String {
    switch interval {
    case ..<60:
      return String(
        format: NSLocalizedString(
          "Every %d seconds", comment: "Keep-alive retry interval option"),
        Int(interval))
    default:
      return String(
        format: NSLocalizedString(
          "Every %d minutes", comment: "Keep-alive retry interval option"),
        Int(interval / 60))
    }
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
        if launchManager.requiresApproval {
          HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
              .accessibilityHidden(true)
            Text("Allow MountMate in Login Items to start it at login.")
              .font(.caption)
            Spacer()
            Button("Open Login Items") { launchManager.openLoginItemsSettings() }
              .controlSize(.small)
          }
        }
        Toggle(isOn: $diskMounter.blockUSBAutoMount) {
          Label("Block USB Auto-Mount", systemImage: "hand.raised.slash")
        }
        Toggle(isOn: $diskMounter.allowRequestedMounts) {
          Label("Allow Other Apps to Mount Blocked Disks", systemImage: "app.badge.checkmark")
        }
        .help(
          "Blocked disks are only stopped from mounting automatically when plugged in or at login. Apps such as backup tools can still mount them when needed."
        )
        Toggle(
          isOn: Binding(
            get: { persistence.blockAtStartup },
            set: { persistence.setBlockAtStartup($0) })
        ) {
          Label("Also Block at Startup (Requires Admin Password)", systemImage: "power")
        }
        .help(
          "Adds a system rule (/etc/fstab) for each blocked disk so macOS never mounts it at startup, even before MountMate opens. You can still mount it yourself. Rules are added while the disk is connected."
        )
        Toggle(isOn: $ejectOnSleepEnabled) {
          Label("Unmount All Disks on Sleep", systemImage: "moon.zzz")
        }
      } header: {
        Label("Behavior", systemImage: "gearshape")
      }

      Section {
        Toggle(isOn: $keepAliveManager.isEnabled) {
          Label("Keep Mounts Alive", systemImage: "arrow.triangle.2.circlepath")
        }

        if keepAliveManager.isEnabled {
          Picker(selection: $keepAliveManager.retryInterval) {
            ForEach(KeepAliveManager.allowedRetryIntervals, id: \.self) { interval in
              Text(Self.retryIntervalLabel(interval)).tag(interval)
            }
          } label: {
            Label("Retry Interval", systemImage: "clock.arrow.circlepath")
          }
          .pickerStyle(.menu)

          Toggle(isOn: $keepAliveManager.remountOnNetworkChange) {
            Label("Remount on Network Change", systemImage: "wifi")
          }
          Toggle(isOn: $keepAliveManager.remountOnWake) {
            Label("Reconnect After Sleep", systemImage: "sun.max")
          }
        }
      } header: {
        Label("Keep Alive", systemImage: "bolt.horizontal.circle")
      } footer: {
        Text(
          NSLocalizedString(
            "Keep Alive Footer",
            comment:
              "Keep Alive settings explanation: automatically remounts network shares marked Keep Mounted and volumes marked Keep Mounted when they drop, after network changes, on wake, and at login."
          )
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Section {
        Toggle(isOn: $hotkeysEnabled) {
          Label("Enable Keyboard Shortcuts", systemImage: "keyboard")
        }

        if hotkeysEnabled {
          VStack(alignment: .leading, spacing: 8) {
            shortcutRow(description: "Unmount All Volumes", action: .unmountAll)
            shortcutRow(description: "Mount All Volumes", action: .mountAll)
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
          Text("中文（繁体）").tag("zh-Hant")
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
    .formStyle(.grouped)
    .padding(.horizontal)
    // Pick up a Login Items approval made in System Settings.
    .onAppear { launchManager.refreshStatus() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) {
      _ in launchManager.refreshStatus()
    }

    .alert("Restart Required", isPresented: $showRestartAlert) {
      Button("Restart Now", role: .destructive) { relaunchApp() }
      Button("Later", role: .cancel) {}
    } message: {
      Text("Please restart MountMate for the language change to take effect.")
    }
    .alert("Shortcut Already Assigned", isPresented: $showShortcutConflictAlert) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(shortcutConflictMessage)
    }
  }

  private func shortcutRow(description: LocalizedStringKey, action: HotkeyAction) -> some View {
    VStack(alignment: .trailing, spacing: 4) {
      HStack(spacing: 8) {
        Text(description)
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer(minLength: 8)
        KeyboardShortcutRecorder(
          shortcut: Binding(
            get: { hotkeyManager.shortcut(for: action) },
            set: { updateShortcut($0, for: action) }
          ),
          isRecording: Binding(
            get: { recordingShortcut == action },
            set: { setRecording($0, for: action) }
          )
        )
        .frame(width: 150, height: 26)
      }
      if recordingShortcut == nil {
        if !hotkeyManager.shortcut(for: action).isSafeAsGlobalHotKey {
          // Saved by an older version; not registered (see HotkeyManager).
          shortcutWarning("This shortcut needs ⌘ or ⌃. Click it to record a new one.")
        } else if hotkeyManager.unavailableShortcuts.contains(action) {
          // Registration fails when another app already uses the combination.
          shortcutWarning("This shortcut is used by another app. Choose a different one.")
        }
      }
    }
  }

  private func shortcutWarning(_ message: LocalizedStringKey) -> some View {
    HStack(spacing: 4) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .accessibilityHidden(true)
      Text(message)
    }
    .font(.caption)
  }

  private func setRecording(_ recording: Bool, for action: HotkeyAction) {
    recordingShortcut = recording ? action : nil
    if recording {
      hotkeyManager.stopListening()
    } else if hotkeysEnabled {
      hotkeyManager.startListening()
    }
  }

  private func updateShortcut(_ shortcut: HotkeyShortcut, for action: HotkeyAction) {
    let otherAction: HotkeyAction = action == .unmountAll ? .mountAll : .unmountAll
    guard shortcut != hotkeyManager.shortcut(for: otherAction) else {
      shortcutConflictMessage = NSLocalizedString(
        "This shortcut is already assigned to the other action.",
        comment: "Duplicate keyboard shortcut warning")
      showShortcutConflictAlert = true
      recordingShortcut = nil
      return
    }

    hotkeyManager.setShortcut(shortcut, for: action)
    recordingShortcut = nil
  }

  /// The language is already saved (see the picker's onChange).
  private func relaunchApp() {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    task.arguments = ["-n", Bundle.main.bundlePath]
    do {
      try task.run()
    } catch {
      print("⚠️ Could not relaunch MountMate: \(error.localizedDescription)")
      return
    }
    NSApplication.shared.terminate(nil)
  }
}
