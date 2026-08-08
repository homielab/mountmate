//  Created by homielab.com

import SwiftUI

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
