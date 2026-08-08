//  Created by homielab.com

import SwiftUI

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
    !server.isEmpty && !sharePath.isEmpty
  }

  private var connectionStringPreview: String {
    let srv = server.isEmpty ? "server" : server
    let path = sharePath.isEmpty ? "share" : sharePath
    return "smb://\(srv)/\(path)"
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "externaldrive.connected.to.line.below")
          .font(.title2)
          .foregroundStyle(.blue)
        Text(shareToEdit == nil ? "Add Network Share" : "Edit Network Share")
          .font(.headline)
      }
      .padding(.top, 18)
      .padding(.bottom, 12)

      Divider()

      Form {
        Section {
          TextField("Display Name", text: $name, prompt: Text("Optional (Defaults to share name)"))
        } header: {
          Label("General", systemImage: "pencil")
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
          Label("Connection", systemImage: "network")
        } footer: {
          HStack(spacing: 6) {
            Image(systemName: "link")
              .font(.caption)
              .foregroundStyle(.blue)
            Text("Preview: \(connectionStringPreview)")
              .font(.system(.caption, design: .monospaced))
              .foregroundStyle(.secondary)
          }
          .padding(.top, 2)
        }

        Section {
          HStack {
            Image(systemName: "person").frame(width: 20)
            TextField("Username", text: $username, prompt: Text("Optional (Guest)"))
          }

          HStack {
            Image(systemName: "key").frame(width: 20)
            SecureField("Password", text: $password)
          }
        } header: {
          Label("Credentials", systemImage: "lock")
        }

        Section {
          Toggle(isOn: $mountAtLogin) {
            Label("Mount at Login", systemImage: "arrow.right.circle")
          }

          VStack(alignment: .leading, spacing: 6) {
            Text("Custom Mount Point")
              .font(.caption)
              .foregroundStyle(.secondary)

            HStack {
              TextField(
                "Custom Mount Point", text: $customMountPoint, prompt: Text("~/mountmate/MyShare"))

              Button("Choose...") {
                selectCustomMountFolder()
              }
              .buttonStyle(.bordered)
              .controlSize(.small)
            }

            Text("Leave empty to use default location")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        } header: {
          Label("Options", systemImage: "slider.horizontal.3")
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
    .frame(width: 460, height: 520)
    .onAppear {
      loadExistingData()
    }
  }

  // MARK: - Logic

  private func selectCustomMountFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Choose"
    panel.message = "Select custom mount directory"
    if panel.runModal() == .OK, let url = panel.url {
      customMountPoint = url.path
    }
  }

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
    let finalName = name.isEmpty ? sharePath : name

    let share = NetworkShare(
      id: id,
      name: finalName,
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
