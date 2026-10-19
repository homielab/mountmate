//  Created by homielab.com

import Security
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
  @State private var keepMounted = true
  @State private var shareProtocol: ShareProtocol = .smb
  @State private var customMountPoint = ""
  /// The password read from the Keychain when editing, or nil when none was
  /// saved or it could not be read. Lets saving tell "the user cleared the
  /// field" apart from "there was nothing (readable) to show".
  @State private var loadedPassword: String?
  @State private var saveError: String?

  // Inputs as they will be saved: trimmed, pasted URL scheme removed.
  private var cleanedServer: String { NetworkShare.cleanedServerInput(server) }
  private var cleanedSharePath: String {
    sharePath.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  private var cleanedUsername: String {
    username.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The display name, defaulting to the last component of the share path
  /// (it names the default mount folder, so it must be a single component).
  private var finalName: String {
    if !name.isEmpty { return name }
    return cleanedSharePath.split(separator: "/").last.map(String.init) ?? cleanedSharePath
  }

  private var isValid: Bool {
    !cleanedServer.isEmpty && !cleanedSharePath.isEmpty && validationError == nil
  }

  /// Why the share cannot be saved as entered, or nil.
  private var validationError: String? {
    guard !cleanedServer.isEmpty, !cleanedSharePath.isEmpty else { return nil }

    // Existing names stay valid when editing other fields.
    if finalName != shareToEdit?.name,
      let nameError = NetworkShare.displayNameValidationError(finalName)
    {
      return nameError
    }

    let candidate = makeShare()
    let otherShares = PersistenceManager.shared.networkShares.filter { $0.id != candidate.id }

    if shareToEdit == nil,
      let duplicate = otherShares.first(where: { $0.hasSameEndpoint(as: candidate) })
    {
      return String(
        format: NSLocalizedString(
          "This share is already saved as “%@”.", comment: "Network share validation error"),
        duplicate.name)
    }

    // Two shares must never use the same mount folder: mounting one would
    // look like the other is mounted, and unmounting one would unmount both.
    let manager = NetworkMountManager.shared
    let mountPoint = manager.configuredMountPoint(for: candidate)
    if let clash = otherShares.first(where: {
      NetworkMountManager.samePath(manager.configuredMountPoint(for: $0), mountPoint)
    }) {
      return String(
        format: NSLocalizedString(
          "The mount point “%@” is already used by the share “%@”. Choose a different display name or custom mount point.",
          comment: "Network share validation error"),
        mountPoint, clash.name)
    }
    return nil
  }

  private var connectionStringPreview: String {
    let srv = cleanedServer.isEmpty ? "server" : cleanedServer
    let path = cleanedSharePath.isEmpty ? "share" : cleanedSharePath
    if shareProtocol == .nfs {
      return "nfs://\(srv)/\(path)"
    }
    return "\(shareProtocol.urlScheme)://\(srv)/\(path)"
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
          Picker(selection: $shareProtocol) {
            ForEach(ShareProtocol.allCases) { item in
              Text(item.displayName).tag(item)
            }
          } label: {
            Label("Protocol", systemImage: "network.badge.shield.half.filled")
          }
          .pickerStyle(.segmented)

          HStack {
            Image(systemName: "server.rack").frame(width: 20)
            TextField("Server Address", text: $server, prompt: Text("192.168.1.100"))
          }

          HStack {
            Image(systemName: "folder").frame(width: 20)
            TextField(
              "Share Name/Path", text: $sharePath,
              prompt: Text(
                shareProtocol == .nfs
                  ? NSLocalizedString("exports/public", comment: "NFS share path prompt")
                  : NSLocalizedString("public", comment: "Share path prompt")))
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
          if shareProtocol.supportsUserCredentials {
            HStack {
              Image(systemName: "person").frame(width: 20)
              TextField("Username", text: $username, prompt: Text("Optional (Guest)"))
            }

            HStack {
              Image(systemName: "key").frame(width: 20)
              SecureField("Password", text: $password)
            }
          } else {
            Text("NFS mounts use host-based access; no credentials are required.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        } header: {
          Label("Credentials", systemImage: "lock")
        }

        Section {
          Toggle(isOn: $mountAtLogin) {
            Label("Mount at Login", systemImage: "arrow.right.circle")
          }

          Toggle(isOn: $keepMounted) {
            Label("Keep Mounted", systemImage: "arrow.triangle.2.circlepath")
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

        if let validationError {
          Text(validationError)
            .font(.caption)
            .foregroundStyle(.red)
            .multilineTextAlignment(.trailing)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
        }

        Button("Save") {
          saveShare()
        }
        .buttonStyle(.borderedProminent)
        .disabled(!isValid)
        .keyboardShortcut(.defaultAction)
      }
      .padding()
    }
    .frame(width: 460, height: 580)
    .onAppear {
      loadExistingData()
    }
    .alert(
      "Could Not Save Share",
      isPresented: Binding(
        get: { saveError != nil },
        set: { if !$0 { saveError = nil } })
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(saveError ?? "")
    }
  }

  // MARK: - Logic

  private func selectCustomMountFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = NSLocalizedString("Choose", comment: "Choose button")
    panel.message = NSLocalizedString(
      "Select custom mount directory", comment: "Open panel message")
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
    keepMounted = share.keepMounted
    shareProtocol = share.shareProtocol
    customMountPoint = share.customMountPoint ?? ""

    // NFS has no password: don't touch the Keychain (avoids access prompts).
    guard share.shareProtocol.supportsUserCredentials else { return }
    if case .found(let savedPassword) = KeychainManager.shared.read(
      account: share.id.uuidString)
    {
      loadedPassword = savedPassword
      password = savedPassword
    }
  }

  /// The share as currently entered.
  private func makeShare() -> NetworkShare {
    let trimmedMountPoint = customMountPoint.trimmingCharacters(in: .whitespacesAndNewlines)
    return NetworkShare(
      id: shareToEdit?.id ?? UUID(),
      name: finalName,
      server: cleanedServer,
      sharePath: cleanedSharePath,
      username: cleanedUsername,
      mountAtLogin: mountAtLogin,
      keepMounted: keepMounted,
      shareProtocol: shareProtocol,
      customMountPoint: trimmedMountPoint.isEmpty ? nil : trimmedMountPoint
    )
  }

  /// Saves or removes the share's Keychain password. Returns a user-facing
  /// error message, or nil on success.
  private func updateKeychain(for share: NetworkShare) -> String? {
    let account = share.id.uuidString
    guard share.shareProtocol.supportsUserCredentials else {
      // Switched to NFS, which uses no password: don't keep an orphaned one.
      guard let original = shareToEdit, original.shareProtocol.supportsUserCredentials
      else { return nil }
      return deletePassword(account: account)
    }

    if !password.isEmpty {
      // Unchanged: skip the write (and any Keychain prompt it could cause).
      guard password != loadedPassword else { return nil }
      let status = KeychainManager.shared.save(password: password, for: account)
      guard status == errSecSuccess else {
        return String(
          format: NSLocalizedString(
            "MountMate could not save the password to the Keychain (error %d).",
            comment: "Network share save error"),
          status)
      }
      return nil
    }

    // The field was emptied on edit: forget the saved password. Only when
    // one was actually loaded; if reading it failed, the empty field does
    // not mean the user cleared it.
    guard loadedPassword != nil else { return nil }
    return deletePassword(account: account)
  }

  /// Deletes the saved password. Returns a user-facing error, or nil.
  private func deletePassword(account: String) -> String? {
    let status = KeychainManager.shared.delete(account: account)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      return String(
        format: NSLocalizedString(
          "MountMate could not remove the saved password from the Keychain (error %d).",
          comment: "Network share save error"),
        status)
    }
    return nil
  }

  private func saveShare() {
    guard isValid else { return }
    let share = makeShare()

    // Keep the sheet open on a Keychain failure so nothing is lost silently.
    if let keychainError = updateKeychain(for: share) {
      saveError = keychainError
      return
    }

    // A mount adopted for the old server/path/protocol is not this share's
    // any more.
    if let original = shareToEdit, !share.hasSameEndpoint(as: original) {
      NetworkMountManager.shared.forgetAdoption(forShareID: share.id)
    }

    if shareToEdit != nil {
      PersistenceManager.shared.updateNetworkShare(share)
    } else {
      PersistenceManager.shared.addNetworkShare(share)
    }
    isPresented = false
  }
}
