//  Created by homielab.com

import SwiftUI

/// Header of "Saved Network Shares" with Mount All / Unmount All buttons for
/// the saved shares. A button only shows while it has something to act on.
struct SavedSharesSectionHeader: View {
  /// The saved shares shown in the section.
  let shares: [NetworkShare]
  @ObservedObject private var networkManager = NetworkMountManager.shared

  var body: some View {
    let candidates = SavedShareBulkRules.candidates(
      shares: shares, mountedIDs: networkManager.mountedShareIDs)
    HStack {
      Label("Saved Network Shares", systemImage: "server.rack")
      Spacer()
      if !candidates.mount.isEmpty || networkManager.isMountingSavedShares {
        button(
          systemImage: "arrow.up.circle.fill", label: "Mount All Saved Shares",
          isBusy: networkManager.isMountingSavedShares, action: mountAll)
      }
      if !candidates.unmount.isEmpty || networkManager.isUnmountingSavedShares {
        button(
          systemImage: "eject.circle.fill", label: "Unmount All Saved Shares",
          isBusy: networkManager.isUnmountingSavedShares, action: unmountAll)
      }
    }
  }

  private func button(
    systemImage: String, label: LocalizedStringKey, isBusy: Bool, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      if isBusy {
        ProgressView().controlSize(.small)
      } else {
        Image(systemName: systemImage)
      }
    }
    .buttonStyle(.plain)
    .disabled(isBusy)
    .help(Text(label))
    .accessibilityLabel(Text(label))
    .accessibilityValue(Text.busyValue(isBusy))
  }

  private func mountAll() {
    networkManager.mountAllShares(trigger: .popover) { failures in
      guard
        let alert = BulkVolumeActions.failureAlert(
          forNames: failures.map(\.name),
          title: NSLocalizedString("Mount Failed", comment: "Alert title"),
          format: NSLocalizedString(
            "Could not mount: %@", comment: "Bulk mount failure; list of share names"),
          reasons: SavedShareBulkRules.mountFailureReasons(failures))
      else { return }
      DriveManager.shared.userActionError = alert
    }
  }

  private func unmountAll() {
    networkManager.unmountAllShares { failures in
      Self.report(failures, offerForce: true)
    }
  }

  /// One alert for every share that could not be unmounted, with its reason,
  /// offering Force Unmount where it may help; a forced attempt that fails
  /// again is only reported.
  private static func report(
    _ failures: [NetworkMountManager.ShareUnmountFailure], offerForce: Bool
  ) {
    let forceable =
      offerForce ? Set(failures.filter(\.failure.canForce).compactMap(\.target.shareID)) : []
    let kind: AppAlertKind =
      forceable.isEmpty
      ? .basic
      : .forceUnmount {
        NetworkMountManager.shared.forceUnmountSavedShares(withIDs: forceable) { failures in
          report(failures, offerForce: false)
        }
      }
    guard
      let alert = BulkVolumeActions.failureAlert(
        forNames: failures.map(\.target.name),
        title: NSLocalizedString("Unmount Failed", comment: "Alert title"),
        format: NSLocalizedString(
          "Could not unmount: %@", comment: "Bulk unmount failure; list of share names"),
        reasons: failures.map(\.failure.message), kind: kind)
    else { return }
    DriveManager.shared.userActionError = alert
  }
}
