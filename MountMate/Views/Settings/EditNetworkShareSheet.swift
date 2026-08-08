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
          TextField("Display Name", text: $name, prompt: Text("Optional (Defaults to share name)"))
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
            .font(.subheadline)
            .foregroundStyle(.primary)
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
    // Default name to sharePath if empty
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
