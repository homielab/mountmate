//  Created by homielab.com

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var launchManager: LaunchAtLoginManager
    @EnvironmentObject var diskMounter: DiskMounter
    @EnvironmentObject var updaterViewModel: UpdaterController
    
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
        VStack(alignment: .leading, spacing: 18) {
            
            Section {
                Toggle("Start MountMate at Login", isOn: $launchManager.isEnabled)
                Toggle("Block USB Auto-Mount", isOn: $diskMounter.blockUSBAutoMount)
                
                HStack {
                    Text("Language")
                    Spacer()
                    Picker("Language", selection: $selectedLanguage) {
                        Text("English").tag("en")
                        Text("Tiếng Việt").tag("vi")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 120)
                    .onChange(of: selectedLanguage) { _ in
                        showRestartAlert = true
                    }
                }
                
            } header: {
                Text("General")
                    .font(.headline)
            }
            
            Divider()
            
            Section {
                SettingsButton(title: "Homepage", icon: "house.fill") {
                    if let url = URL(string: "https://homielab.com/page/mountmate") { NSWorkspace.shared.open(url) }
                }
                
                SettingsButton(title: "Support Email", icon: "envelope.fill") {
                    if let url = URL(string: "mailto:contact@homielab.com") { NSWorkspace.shared.open(url) }
                }
                
                SettingsButton(title: "Donate", icon: "heart.fill", iconColor: .red) {
                    if let url = URL(string: "https://ko-fi.com/homielab") { NSWorkspace.shared.open(url) }
                }

                SettingsButton(title: "Check for Updates...", icon: "arrow.up.circle.fill") {
                    updaterViewModel.checkForUpdates()
                }

            } header: {
                Text("About")
                    .font(.headline)
            }
            
            Spacer()
            Text(appVersion)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding()
        .frame(width: 320)
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


struct SettingsButton: View {
    let title: LocalizedStringKey
    let icon: String
    var iconColor: Color = .accentColor
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundColor(iconColor)
                    .frame(width: 20)
                Text(title)
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }
}
