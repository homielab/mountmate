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
      .accessibilityLabel(Text("Eject All Manually Connected Shares"))
      .accessibilityValue(
        Text.busyValue(networkManager.isUnmountingManualShares))
    }
  }

  private func ejectAllManualShares() {
    networkManager.unmountAllManuallyConnectedShares { failures in
      Self.report(failures, offerForce: true)
    }
  }

  /// One alert for every share that could not be ejected, with its reason.
  /// It offers Force Unmount for the shares where that may help (busy, timed
  /// out, unknown error); a forced attempt that fails again is only reported.
  private static func report(
    _ failures: [NetworkMountManager.ShareUnmountFailure], offerForce: Bool
  ) {
    let forceable = offerForce ? failures.filter(\.failure.canForce).map(\.target) : []
    let kind: AppAlertKind =
      forceable.isEmpty
      ? .basic
      : .forceUnmount {
        NetworkMountManager.shared.forceUnmountManualShares(forceable) { failures in
          report(failures, offerForce: false)
        }
      }
    guard
      let alert = BulkVolumeActions.failureAlert(
        forNames: failures.map(\.target.name),
        title: NSLocalizedString("Eject Failed", comment: "Alert title"),
        format: NSLocalizedString(
          "Could not eject: %@", comment: "Bulk eject failure; list of share names"),
        reasons: failures.map(\.failure.message), kind: kind)
    else { return }
    DriveManager.shared.userActionError = alert
  }
}
