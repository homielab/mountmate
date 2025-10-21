//  Created by homielab.com

import SwiftUI

struct SettingsView: View {
  var body: some View {
    TabView {
      GeneralSettingsView()
        .tabItem { Label("General", systemImage: "gear") }

      ManagementSettingsView()
        .tabItem { Label("Management", systemImage: "slider.horizontal.3") }
    }
    .frame(
      minWidth: 420, idealWidth: 420, maxWidth: 450, minHeight: 520, idealHeight: 650,
      maxHeight: 800)
  }
}

struct GeneralSettingsView: View {
  @EnvironmentObject var launchManager: LaunchAtLoginManager
  @EnvironmentObject var diskMounter: DiskMounter
  @EnvironmentObject var updaterViewModel: UpdaterController

  @AppStorage("ejectOnSleepEnabled") private var ejectOnSleepEnabled = false
  @AppStorage("showInternalDisks") private var showInternalDisks = false

  @State private var selectedLanguage: String = {
    guard
      let preferredLanguages = UserDefaults.standard.array(forKey: "AppleLanguages")
        as? [String],
      let firstLanguage = preferredLanguages.first
    else { return "en" }
    if firstLanguage.starts(with: "vi") { return "vi" }
    if firstLanguage.starts(with: "zh-Hant")
      || firstLanguage.starts(with: "zh-TW")
      || firstLanguage.starts(with: "zh-HK")
      || firstLanguage.starts(with: "zh-MO")
    {
      return "zh-Hant"
    }
    if firstLanguage.starts(with: "zh") {
      return "zh-Hans"
    }
    return "en"
  }()

  @State private var showRestartAlert = false

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
        Toggle("Show Internal Disks", isOn: $showInternalDisks)
        Toggle("Start MountMate at Login", isOn: $launchManager.isEnabled)
        Toggle("Block USB Auto-Mount", isOn: $diskMounter.blockUSBAutoMount)
        Toggle("Unmount All Disks on Sleep", isOn: $ejectOnSleepEnabled)
        Picker("Language", selection: $selectedLanguage) {
          Text("English").tag("en")
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

// MARK: - Management Settings Tab
struct ManagementSettingsView: View {
  @ObservedObject private var persistence = PersistenceManager.shared

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        ManagementSectionView(
          title: "Ignored Volumes",
          iconName: "eye.slash.fill",
          items: persistence.ignoredVolumes,
          emptyStateText: "No Ignored Volumes",
          footer:
            "Right-click a volume to ignore it. Useful for system partitions like 'EFI' that you don't need to manage.",
          onDelete: { info in persistence.unignore(info: info) }
        )

        ManagementSectionView(
          title: "Protected Volumes",
          iconName: "lock.shield.fill",
          items: persistence.protectedVolumes,
          emptyStateText: "No Protected Volumes",
          footer: "Right-click a volume to protect it from 'Unmount All' and sleep actions.",
          onDelete: { info in persistence.unprotect(info: info) }
        )

        ManagementSectionView(
          title: "Blocked from Auto-Mounting",
          iconName: "hand.raised.fill",
          items: persistence.blockedVolumes,
          emptyStateText: "No Volumes Blocked from Auto-Mounting",
          footer: "Right-click a volume to prevent it from mounting automatically when connected.",
          onDelete: { info in persistence.unblock(info: info) }
        )

        Spacer()
      }
      .padding()
    }
  }
}

// MARK: - Reusable Management Components
struct ManagementSectionView: View {
  let title: LocalizedStringKey
  let iconName: String
  let items: [ManagedVolumeInfo]
  let emptyStateText: LocalizedStringKey
  let footer: LocalizedStringKey
  let onDelete: (ManagedVolumeInfo) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Image(systemName: iconName)
          .font(.headline)
          .foregroundColor(.secondary)
        Text(title)
          .font(.headline)
      }

      Divider()

      if items.isEmpty {
        HStack {
          Spacer()
          Text(emptyStateText)
            .foregroundColor(.secondary)
          Spacer()
        }
        .padding(.vertical)
      } else {
        VStack {
          ForEach(items) { info in
            ManagedVolumeRow(info: info, onDelete: { onDelete(info) })
            if info != items.last {
              Divider()
            }
          }
        }
      }

      Text(footer)
        .font(.caption)
        .foregroundColor(.secondary)
    }
    .padding()
    .background(Color(nsColor: .windowBackgroundColor))
    .cornerRadius(10)
    .shadow(color: .black.opacity(0.1), radius: 3, y: 1)
  }
}

struct ManagedVolumeRow: View {
  let info: ManagedVolumeInfo
  let onDelete: () -> Void

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(info.name).fontWeight(.semibold)
        Text("Volume: \(info.volumeUUID)").font(.system(.caption, design: .monospaced))
          .foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
        Text("Disk: \(info.diskUUID)").font(.system(.caption, design: .monospaced)).foregroundColor(
          .secondary
        ).lineLimit(1).truncationMode(.middle)
      }
      Spacer()
      Button(role: .destructive) {
        onDelete()
        DriveManager.shared.refreshDrives(qos: .userInitiated)
      } label: {
        Image(systemName: "trash")
      }.buttonStyle(.borderless)
    }
    .padding(.vertical, 4)
  }
}
