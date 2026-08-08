//  Created by homielab.com

import SwiftUI

struct ManualSharesSectionHeader: View {
  @ObservedObject private var networkManager = NetworkMountManager.shared

  var body: some View {
    HStack {
      Text("Manually Connected Shares")
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
        title: "Eject Failed",
        message: "Could not eject: \(failures.joined(separator: ", "))",
        kind: .basic)
    }
  }
}
