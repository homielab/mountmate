//  Created by homielab.com

import SwiftUI

struct ManualSharesSectionHeader: View {
  @ObservedObject private var networkManager = NetworkMountManager.shared

  var body: some View {
    HStack {
      Label("Manually Connected Shares", systemImage: "network")
      Spacer()
      Button(action: ejectAllManualShares) {
        if networkManager.isUnmountingManualShares {
          ProgressView().controlSize(.small)
        } else {
          Image(systemName: "eject.circle.fill")
        }
      }
      .buttonStyle(.plain)
      .disabled(networkManager.isUnmountingManualShares)
      .help("Eject All Manually Connected Shares")
    }
  }

  private func ejectAllManualShares() {
    networkManager.unmountAllManuallyConnectedShares { failures in
      guard !failures.isEmpty else { return }
      DriveManager.shared.userActionError = AppAlert(
        title: NSLocalizedString("Eject Failed", comment: "Alert title"),
        message: "Could not eject: \(failures.joined(separator: ", "))",
        kind: .basic)
    }
  }
}
