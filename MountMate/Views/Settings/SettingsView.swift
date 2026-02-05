//  Created by homielab.com

import SwiftUI

struct SettingsView: View {
  var body: some View {
    TabView {
      GeneralSettingsView()
        .tabItem { Label("General", systemImage: "gear") }

      ManagementSettingsView()
        .tabItem { Label("Management", systemImage: "slider.horizontal.3") }

      NetworkSharesSettingsView()
        .tabItem { Label("Network Shares", systemImage: "server.rack") }
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
  @AppStorage("hotkeysEnabled") private var hotkeysEnabled = false

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
        Toggle("Show Internal Disks", isOn: $showInternalDisks)
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
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
          NSWorkspace.shared.open(url)
        }
      }
      Button("Later", role: .cancel) {}
    } message: {
      Text("To use keyboard shortcuts, please grant MountMate Accessibility access in System Settings → Privacy & Security → Accessibility.")
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
// MARK: - Network Shares Settings Tab
struct NetworkSharesSettingsView: View {
  @ObservedObject private var persistence = PersistenceManager.shared
  @State private var showingAddSheet = false
  @State private var editingShare: NetworkShare?
  @State private var errorAlert: AppAlert?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("Network Shares").font(.headline)
        Spacer()
        Button(action: { showingAddSheet = true }) {
          Label("Add Share", systemImage: "plus")
        }
      }
      .padding(.top)

      if persistence.networkShares.isEmpty {
        VStack(spacing: 16) {
          Spacer()
          Image(systemName: "server.rack").font(.system(size: 40)).foregroundColor(.secondary)
          Text("No Network Shares Configured").foregroundColor(.secondary)
          Spacer()
        }
        .frame(maxWidth: .infinity)
      } else {
        List {
          ForEach(persistence.networkShares) { share in
            NetworkShareRow(
              share: share, onEdit: { editingShare = share },
              onError: { error in
                errorAlert = AppAlert(title: "Mount Failed", message: error, kind: .basic)
              })
          }
        }
        .listStyle(.inset)
      }

      Text("MountMate can automatically mount these SMB shares at login.")
        .font(.caption).foregroundColor(.secondary)
    }
    .padding()
    .sheet(isPresented: $showingAddSheet) {
      EditNetworkShareSheet(isPresented: $showingAddSheet, shareToEdit: nil)
    }
    .sheet(item: $editingShare) { share in
      EditNetworkShareSheet(
        isPresented: Binding(
          get: { editingShare != nil },
          set: { if !$0 { editingShare = nil } }
        ), shareToEdit: share)
    }
    .alert(item: $errorAlert) { alert in
      Alert(
        title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
    }
  }
}

struct NetworkShareRow: View {
  let share: NetworkShare
  let onEdit: () -> Void
  let onError: (String) -> Void
  @State private var isMounting = false

  var body: some View {
    HStack {
      VStack(alignment: .leading) {
        Text(share.name).fontWeight(.semibold)
        Text("\(share.username)@\(share.server)/\(share.sharePath)")
          .font(.caption).foregroundColor(.secondary)
      }

      Spacer()

      if share.mountAtLogin {
        Image(systemName: "bolt.fill").foregroundColor(.yellow).help("Auto-mounts at login")
      }

      Button(action: {
        isMounting = true
        NetworkMountManager.shared.mount(share: share) { success, error in
          isMounting = false
          if !success, let error = error {
            onError(error)
          }
        }
      }) {
        Image(systemName: "play.fill")
      }
      .disabled(isMounting)
      .buttonStyle(.borderless)
      .help("Mount Now")

      Button(action: onEdit) {
        Image(systemName: "pencil")
      }
      .buttonStyle(.borderless)
      .help("Edit")

      Button(
        role: .destructive,
        action: {
          PersistenceManager.shared.removeNetworkShare(share)
        }
      ) {
        Image(systemName: "trash")
      }
      .buttonStyle(.borderless)
      .help("Delete")
    }
    .padding(.vertical, 4)
  }
}

struct EditNetworkShareSheet: View {
  @Binding var isPresented: Bool
  let shareToEdit: NetworkShare?

  // MARK: - State
  @State private var name = ""
  @State private var server = ""
  @State private var sharePath = ""
  @State private var username = ""
  @State private var password = ""
  @State private var mountAtLogin = true
  @State private var customMountPoint = ""

  private var isValid: Bool {
    !name.isEmpty && !server.isEmpty && !sharePath.isEmpty && !username.isEmpty
  }

  private var connectionStringPreview: String {
    let srv = server.isEmpty ? "server" : server
    let path = sharePath.isEmpty ? "share" : sharePath
    return "smb://\(srv)/\(path)"
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Image(systemName: "externaldrive.connected.to.line.below")
          .font(.title2)
          .foregroundStyle(.blue)
        Text(shareToEdit == nil ? "Add Network Share" : "Edit Network Share")
          .font(.headline)
      }
      .padding(.top, 20)
      .padding(.bottom, 10)

      Divider()

      Form {
        Section {
          TextField("Display Name", text: $name, prompt: Text("e.g. My NAS"))
        } header: {
          Text("General")
        }

        Section {
          HStack {
            Image(systemName: "server.rack").frame(width: 20)
            TextField("Server Address", text: $server, prompt: Text("192.168.1.100"))
          }

          HStack {
            Image(systemName: "folder").frame(width: 20)
            TextField("Share Name/Path", text: $sharePath, prompt: Text("public"))
          }
        } header: {
          Text("Connection")
        } footer: {
          Text("Preview: \(connectionStringPreview)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Section {
          HStack {
            Image(systemName: "person").frame(width: 20)
            TextField("Username", text: $username)
          }

          HStack {
            Image(systemName: "key").frame(width: 20)
            SecureField("Password", text: $password)
          }
        } header: {
          Text("Credentials")
        }

        Section {
          Toggle(isOn: $mountAtLogin) {
            Label("Mount at Login", systemImage: "arrow.right.circle")
          }

          VStack(alignment: .leading) {
            TextField(
              "Custom Mount Point", text: $customMountPoint, prompt: Text("~/mountmate/MyShare"))
            Text("Leave empty to use default location")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        } header: {
          Text("Options")
        }
      }
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)

      Divider()
      HStack {
        Button("Cancel") {
          isPresented = false
        }
        .keyboardShortcut(.cancelAction)

        Spacer()

        Button("Save") {
          saveShare()
        }
        .buttonStyle(.borderedProminent)
        .disabled(!isValid)
        .keyboardShortcut(.defaultAction)
      }
      .padding()
    }
    .frame(width: 450, height: 500)
    .onAppear {
      loadExistingData()
    }
  }

  // MARK: - Logic

  private func loadExistingData() {
    guard let share = shareToEdit else { return }

    name = share.name
    server = share.server
    sharePath = share.sharePath
    username = share.username
    mountAtLogin = share.mountAtLogin
    customMountPoint = share.customMountPoint ?? ""

    if let loadedPassword = KeychainManager.shared.load(account: share.id.uuidString) {
      password = loadedPassword
    }
  }

  private func saveShare() {
    let id = shareToEdit?.id ?? UUID()
    let share = NetworkShare(
      id: id,
      name: name,
      server: server,
      sharePath: sharePath,
      username: username,
      mountAtLogin: mountAtLogin,
      customMountPoint: customMountPoint.isEmpty ? nil : customMountPoint
    )

    if !password.isEmpty {
      _ = KeychainManager.shared.save(password: password, for: share.id.uuidString)
    }

    if shareToEdit != nil {
      PersistenceManager.shared.updateNetworkShare(share)
    } else {
      PersistenceManager.shared.addNetworkShare(share)
    }
    isPresented = false
  }
}
