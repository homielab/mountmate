//  Created by homielab.com

import SwiftUI

struct NetworkSharesSettingsView: View {
  @ObservedObject private var persistence = PersistenceManager.shared
  @ObservedObject private var networkManager = NetworkMountManager.shared
  @State private var showingAddSheet = false
  @State private var editingShare: NetworkShare?
  @State private var errorAlert: AppAlert?
  @State private var isImporting = false
  @State private var importMessage: String?
  @State private var isDropTargeted = false

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Label("Network Shares", systemImage: "server.rack")
          .font(.headline)
        Spacer()
        Button(action: importMountedShares) {
          if isImporting {
            ProgressView().controlSize(.small)
          } else {
            Label("Import Mounted", systemImage: "square.and.arrow.down")
          }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isImporting)
        .help("Import SMB shares that are currently mounted in Finder")

        Button(action: { showingAddSheet = true }) {
          Label("Add Share", systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
      }

      if let importMessage {
        Text(importMessage)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if persistence.networkShares.isEmpty {
        emptyStateView
      } else {
        List {
          ForEach(persistence.networkShares) { share in
            NetworkShareRow(
              share: share, onEdit: { editingShare = share },
              onError: { error in
                errorAlert = AppAlert(title: NSLocalizedString("Mount Failed", comment: "Alert title"), message: error, kind: .basic)
              })
          }
        }
        .listStyle(.inset)
        .clipShape(.rect(cornerRadius: 10))
        .overlay(
          RoundedRectangle(cornerRadius: 10)
            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
      }

      Text("MountMate can automatically mount these SMB shares at login.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding()
    .background {
      RoundedRectangle(cornerRadius: 12)
        .strokeBorder(
          isDropTargeted ? Color.accentColor : Color.clear,
          style: StrokeStyle(lineWidth: 2, dash: [6])
        )
        .background(isDropTargeted ? Color.accentColor.opacity(0.06) : Color.clear)
    }
    .dropDestination(for: URL.self) { urls, _ in
      importDroppedURLs(urls)
    } isTargeted: { targeted in
      isDropTargeted = targeted
    }
    .onAppear {
      networkManager.refreshMountStatus()
    }
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

  private func importMountedShares() {
    isImporting = true
    importMessage = nil
    networkManager.discoverManuallyMountedShares { shares in
      let count = persistence.addNetworkSharesIfNeeded(shares)
      isImporting = false
      importMessage = importResultMessage(added: count, discovered: shares.count)
      networkManager.refreshMountStatus()
    }
  }

  private func importDroppedURLs(_ urls: [URL]) -> Bool {
    let shares = urls.compactMap { networkManager.manuallyMountedShare(containing: $0) }
    let uniqueShares = Array(Set(shares))
    let count = persistence.addNetworkSharesIfNeeded(uniqueShares)
    importMessage = importResultMessage(added: count, discovered: uniqueShares.count)
    networkManager.refreshMountStatus()
    return !uniqueShares.isEmpty
  }

  private func importResultMessage(added: Int, discovered: Int) -> String {
    if added > 0 {
      return String(
        format: NSLocalizedString("Imported %d mounted share(s). Add credentials by editing each share.", comment: "Mounted share import result"),
        added)
    }
    if discovered > 0 {
      return NSLocalizedString("Those mounted shares are already in MountMate.", comment: "Mounted share import result")
    }
    return NSLocalizedString("No mounted SMB shares were found.", comment: "Mounted share import result")
  }

  private var emptyStateView: some View {
    VStack(spacing: 16) {
      Spacer()

      ZStack {
        Circle()
          .fill(Color.blue.opacity(0.1))
          .frame(width: 72, height: 72)

        Image(systemName: "server.rack")
          .font(.system(size: 32))
          .foregroundStyle(.blue)
      }

      VStack(spacing: 4) {
        Text("No Network Shares Configured")
          .font(.headline)

        Text("Add your SMB or NAS network shares here to mount them automatically or on demand.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 320)
      }

      Button(action: { showingAddSheet = true }) {
        Label("Add Network Share", systemImage: "plus")
      }
      .buttonStyle(.bordered)
      .controlSize(.regular)

      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(.rect(cornerRadius: 10))
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
    )
  }
}
