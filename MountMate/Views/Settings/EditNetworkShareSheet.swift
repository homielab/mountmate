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
  @State private var keepMounted = true
  @State private var shareProtocol: ShareProtocol = .smb
  @State private var customMountPoint = ""
  /// The password read from the Keychain when editing, or nil when none was
  /// saved or it could not be read. Lets saving tell "the user cleared the
  /// field" apart from "there was nothing (readable) to show".
  @State private var loadedPassword: String?
  @State private var saveError: String?
  @State private var showBrowser = false

  // Inputs as they will be saved: trimmed, pasted URL scheme removed. A
  // pasted URL's path (smb://nas/Public) is the share path when that field
  // is empty.
  private var cleanedServer: String { NetworkShare.cleanedServerInput(server).server }
  private var cleanedSharePath: String {
    let typed = NetworkShare.cleanedSharePathInput(sharePath)
    return typed.isEmpty ? NetworkShare.cleanedServerInput(server).sharePath : typed
  }
  private var cleanedUsername: String {
    username.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var availableProtocols: [ShareProtocol] {
    if shareToEdit?.shareProtocol == .afp || shareProtocol == .afp {
      return ShareProtocol.allCases
    }
    return ShareProtocol.creationCases
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
    let candidate = makeShare()
    return NetworkShareValidation.error(
      candidate: candidate, original: shareToEdit,
      otherShares: PersistenceManager.shared.networkShares.filter { $0.id != candidate.id },
      mountPoint: NetworkMountManager.shared.configuredMountPoint(for:))
  }

  private var connectionStringPreview: String {
    let srv = cleanedServer.isEmpty ? "server" : cleanedServer
    let path = cleanedSharePath.isEmpty ? "share" : cleanedSharePath
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
            ForEach(availableProtocols) { item in
              Text(item.displayName).tag(item)
            }
          } label: {
            Label("Protocol", systemImage: "network.badge.shield.half.filled")
          }
          .pickerStyle(.segmented)

          if shareProtocol.isDeprecated {
            HStack(alignment: .top, spacing: 6) {
              Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
              Text(
                NSLocalizedString(
                  "Apple has removed support for AFP in modern macOS versions. Consider switching this share to SMB or NFS.",
                  comment: "Deprecated share protocol warning")
              )
              .font(.caption)
              .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
          }

          HStack {
            Image(systemName: "server.rack").frame(width: 20)
            TextField("Server Address", text: $server, prompt: Text("192.168.1.100"))
            Button("Browse Network…") {
              showBrowser = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(Text("Find servers on this network"))
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
    .sheet(isPresented: $showBrowser) {
      NetworkServicePickerSheet(isPresented: $showBrowser) { service in
        server = service.host
        shareProtocol = service.shareProtocol
      }
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

  private func saveShare() {
    guard isValid else { return }
    let share = makeShare()

    // Keep the sheet open on a Keychain failure so nothing is lost silently.
    if let keychainError = NetworkSharePasswordSync(store: KeychainManager.shared).sync(
      share: share, original: shareToEdit, password: password, loadedPassword: loadedPassword)
    {
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
