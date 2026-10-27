//  Created by homielab.com

import Foundation

extension DriveManager {
  // MARK: - Verify Volume

  /// Verifies `volume` with `diskutil verifyVolume` in the background (never
  /// repairs), marks it "Verifying…" meanwhile and shows the outcome in an
  /// alert. Call on the main thread.
  func verifyVolume(_ volume: Volume) {
    let volumeID = volume.id
    let name = volume.name
    let started = volumeVerifier.verify(
      volumeID: volumeID, deviceIdentifier: volume.deviceIdentifier
    ) { [weak self] result in
      guard let self else { return }
      self.setVerifying(volumeID, false)
      self.setBusy(volumeID, false)
      let outcome = VolumeVerificationRules.outcome(for: result, volumeName: name)
      self.userActionError = AppAlert(
        title: outcome.title, message: outcome.message, kind: .basic,
        style: outcome.succeeded ? .informational : .warning)
    }
    guard started else { return }
    // The completion is queued on main, so it always runs after this.
    setVerifying(volumeID, true)
    setBusy(volumeID, true)
  }
}
