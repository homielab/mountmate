//  Created by homielab.com

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var launchManager: LaunchAtLoginManager
    @EnvironmentObject var diskMounter: DiskMounter
    @EnvironmentObject var updaterViewModel: UpdaterController
    
    @StateObject private var persistence = PersistenceManager.shared
    @AppStorage("ejectOnSleepEnabled") private var ejectOnSleepEnabled = false
    
    @State private var selectedLanguage: String = {
        guard let preferredLanguages = UserDefaults.standard.array(forKey: "AppleLanguages") as? [String],
              let firstLanguage = preferredLanguages.first else { return "en" }
        if firstLanguage.starts(with: "vi") { return "vi" }
        return "en"
    }()
    
    @State private var showRestartAlert = false
    
    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "N/A"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "N/A"
        return "Version \(version) (\(build))"
    }

    var body: some View {
        TabView {
            generalSettings.tabItem { Label("General", systemImage: "gear") }
            managementSettings.tabItem { Label("Management", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 450, height: 350)
        .alert("Restart Required", isPresented: $showRestartAlert) {
            Button("Restart Now", role: .destructive) {
                UserDefaults.standard.set([selectedLanguage], forKey: "AppleLanguages")
                relaunchApp()
            }
            Button("Later", role: .cancel) {}
        } message: {
            Text("Please restart MountMate for the language change to take effect.")
        }
    }
    
    private var generalSettings: some View {
        Form {
            Section {
                Toggle("Start MountMate at Login", isOn: $launchManager.isEnabled)
                Toggle("Block USB Auto-Mount", isOn: $diskMounter.blockUSBAutoMount)
                Toggle("Unmount All Disks on Sleep", isOn: $ejectOnSleepEnabled)
                Picker("Language", selection: $selectedLanguage) {
                    Text("English").tag("en")
                    Text("Tiếng Việt").tag("vi")
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
                    Label(title: { Text("Donate") }, icon: { Image(systemName: "heart.fill").foregroundColor(.red) })
                }
                Button(action: { updaterViewModel.checkForUpdates() }) {
                    Label("Check for Updates...", systemImage: "arrow.down.circle.fill")
                }
            }
            .foregroundColor(.primary)

            Spacer()
            Text(appVersion).font(.caption).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .center)
        }
        .formStyle(.grouped).padding()
    }
    
    private var managementSettings: some View {
        Form {
            Section(header: Text("Ignored Disks"), footer: Text("Right-click a disk to ignore it. Useful for disk readers or hubs that appear as empty devices.")) {
                if persistence.ignoredDisks.isEmpty {
                    CenteredContent {
                        Image(systemName: "eye.slash.circle").font(.title).foregroundColor(.secondary)
                        Text("No Ignored Disks").fontWeight(.semibold)
                    }
                } else {
                    List {
                        ForEach(persistence.ignoredDisks, id: \.self) { id in
                            HStack {
                                Text(id); Spacer()
                                Button(role: .destructive) {
                                    persistence.unignore(diskID: id)
                                    DriveManager.shared.refreshDrives(qos: .userInitiated)
                                } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
            
            Section(header: Text("Protected Volumes"), footer: Text("Right-click a volume to protect it from 'Unmount All' and sleep actions.")) {
                if persistence.protectedVolumes.isEmpty {
                    CenteredContent {
                        Image(systemName: "lock.shield").font(.title).foregroundColor(.secondary)
                        Text("No Protected Volumes").fontWeight(.semibold)
                    }
                } else {
                    List {
                        ForEach(persistence.protectedVolumes, id: \.self) { id in
                            HStack {
                                Text(id); Spacer()
                                Button(role: .destructive) {
                                    persistence.unprotect(volumeID: id)
                                    DriveManager.shared.refreshDrives(qos: .userInitiated)
                                } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
        }
        .padding()
    }

    private func relaunchApp() {
        let url = URL(fileURLWithPath: Bundle.main.resourcePath!)
        let path = url.deletingLastPathComponent().deletingLastPathComponent().absoluteString
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-n", path]
        task.launch()
        NSApplication.shared.terminate(self)
    }
}

struct CenteredContent<Content: View>: View {
    let content: Content
    
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    
    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                VStack(spacing: 8) {
                    content
                }
                Spacer()
            }
            Spacer()
        }
    }
}