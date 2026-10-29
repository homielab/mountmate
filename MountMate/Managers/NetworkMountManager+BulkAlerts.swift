//  Created by homielab.com

import Foundation

extension NetworkMountManager {
  /// One alert naming every saved share that Mount All could not mount, with
  /// its reason. Nothing when all of them mounted.
  static func reportMountAllFailures(_ failures: [ShareMountFailure]) {
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

  /// One alert for every share that could not be unmounted, with its reason,
  /// offering Force Unmount where it may help; a forced attempt that fails
  /// again is only reported.
  static func reportUnmountAllFailures(_ failures: [ShareUnmountFailure], offerForce: Bool) {
    let forceable =
      offerForce ? Set(failures.filter(\.failure.canForce).compactMap(\.target.shareID)) : []
    let kind: AppAlertKind =
      forceable.isEmpty
      ? .basic
      : .forceUnmount {
        NetworkMountManager.shared.forceUnmountSavedShares(withIDs: forceable) { failures in
          reportUnmountAllFailures(failures, offerForce: false)
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
