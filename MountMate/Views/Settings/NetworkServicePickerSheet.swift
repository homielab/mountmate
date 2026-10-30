//  Created by homielab.com

import SwiftUI

/// Picks one of the share servers found on the local network. Browsing runs
/// through `NetworkShareBrowser`; with nothing found or the local-network
/// permission denied, the message says so and the server address can still be
/// typed by hand in the share sheet.
struct NetworkServicePickerSheet: View {
  @Binding var isPresented: Bool
  /// Called with the picked service, then the sheet closes.
  let onPick: (BrowsedShareService) -> Void

  @StateObject private var browser = NetworkShareBrowser()

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "wifi")
          .font(.title2)
          .foregroundStyle(.blue)
          .accessibilityHidden(true)
        Text("Shared Servers on This Network")
          .font(.headline)
      }
      .padding(.top, 18)
      .padding(.bottom, 12)

      Divider()

      Group {
        if browser.failed {
          statusView(
            systemImage: "exclamationmark.triangle",
            text: NSLocalizedString(
              "Local network access was denied, so no servers can be listed. Type the server address by hand.",
              comment: "Network browser permission-denied message"))
        } else if browser.services.isEmpty {
          statusView(
            systemImage: "magnifyingglass",
            text: browser.isBrowsing
              ? NSLocalizedString(
                "Looking for shared servers…", comment: "Network browser searching message")
              : NSLocalizedString(
                "No shared servers found. Type the server address by hand.",
                comment: "Network browser empty message"))
        } else {
          List(browser.services) { service in
            Button {
              onPick(service)
              isPresented = false
            } label: {
              HStack {
                VStack(alignment: .leading, spacing: 2) {
                  Text(service.displayName)
                    .font(.body)
                  Text("\(service.serverAddress) · \(service.shareProtocol.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .accessibilityHidden(true)
              }
            }
            .buttonStyle(.plain)
          }
          .listStyle(.inset)
        }
      }
      .frame(maxHeight: .infinity)

      Divider()
      HStack {
        Text("Only servers announcing SMB or NFS on this network are listed.")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("Cancel") {
          isPresented = false
        }
        .keyboardShortcut(.cancelAction)
      }
      .padding()
    }
    .frame(width: 380, height: 420)
    .onAppear { browser.start() }
    .onDisappear { browser.stop() }
  }

  private func statusView(systemImage: String, text: String) -> some View {
    VStack(spacing: 10) {
      Image(systemName: systemImage)
        .font(.title2)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(text)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
