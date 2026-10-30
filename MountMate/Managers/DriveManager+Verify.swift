//  Created by homielab.com

import Foundation

extension DriveManager {
  // MARK: - Verify Volume

  /// Verifies `volume` with `diskutil verifyVolume` in the background (never
  /// repairs), marks it "Verifying…" meanwhile and shows the outcome in an
  /// alert. Call on the main thread.
  func verifyVolume(_ volume: Volume) {
    guard !isBusy(volume.id) else { return }
    let volumeID = volume.id
    let name = volume.name
    let fileSystemType = volume.mountedFileSystemType ?? volume.fileSystemType
    let started = volumeVerifier.verify(
      volumeID: volumeID, deviceIdentifier: volume.deviceIdentifier
    ) { [weak self] result in
      guard let self else { return }
      self.setVerifying(volumeID, false)
      self.setBusy(volumeID, false)
      guard let result else { return }  // Cancelled by the user or at quit.
      if !result.succeeded {
        Log.drive.error(
          "Verify failed for \(volumeID, privacy: .public), exit \(result.exitCode ?? -1, privacy: .public): \(VolumeVerificationRules.failureDetail(result) ?? "-", privacy: .public)"
        )
      }
      let outcome = VolumeVerificationRules.outcome(
        for: result, volumeName: name, fileSystemType: fileSystemType)
      self.userActionError = AppAlert(
        title: outcome.title, message: outcome.message, kind: .basic,
        style: outcome.succeeded ? .informational : .warning)
    }
    guard started else { return }
    // The completion is queued on main, so it always runs after this.
    setVerifying(volumeID, true)
    setBusy(volumeID, true)
  }

  /// Stops a running verification; the row stops being busy and no alert is
  /// shown. Call on the main thread.
  func cancelVerifyVolume(_ volume: Volume) {
    volumeVerifier.cancel(volume.id)
  }
}
