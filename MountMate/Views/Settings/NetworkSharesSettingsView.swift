//  Created by homielab.com

import SwiftUI

struct NetworkSharesSettingsView: View {
  @ObservedObject private var persistence = PersistenceManager.shared
  @State private var showingAddSheet = false
  @State private var editingShare: NetworkShare?
  @State private var errorAlert: AppAlert?

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Label("Network Shares", systemImage: "server.rack")
          .font(.headline)
        Spacer()
        Button(action: { showingAddSheet = true }) {
          Label("Add Share", systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
      }

      if persistence.networkShares.isEmpty {
        emptyStateView
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
