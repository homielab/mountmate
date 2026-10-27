//  Created by homielab.com

import Foundation

extension DriveManager {
  // MARK: - Rename Volume

  /// Asks for a new name for `volume` and renames it. Call on the main thread.
  func promptRenameVolume(_ volume: Volume) {
    let fileSystemType = volume.fileSystemType
    userActionError = AppAlert(
      title: NSLocalizedString("Rename Volume", comment: "Alert title"),
      message: String(
        format: NSLocalizedString(
          "Enter a new name for “%@”.", comment: "Rename Volume prompt; current volume name"),
        volume.name),
      kind: .renameVolume(
        RenameVolumeAppAlert(
          currentName: volume.name,
          validate: { name in
            VolumeRenameRules.problem(with: name, fileSystemType: fileSystemType)
              .map(VolumeRenameRules.message(for:))
          },
          onConfirm: { [weak self] name in self?.renameVolume(volume, to: name) })),
      style: .informational)
  }

  /// Renames `volume` with `diskutil rename` in the background, keeps its row
  /// busy meanwhile and refreshes the list afterwards. Invalid or unchanged
  /// names do nothing. Call on the main thread.
  func renameVolume(_ volume: Volume, to name: String) {
    guard VolumeRenameRules.problem(with: name, fileSystemType: volume.fileSystemType) == nil,
      VolumeRenameRules.isChange(name, from: volume.name), !isBusy(volume.id)
    else { return }
    let arguments = VolumeRenameRules.arguments(
      forDevice: volume.deviceIdentifier, newName: name)
    setBusy(volume.id, true)
    DispatchQueue.global(qos: .userInitiated).async {
      let result = runProcess(
        executable: "/usr/sbin/diskutil", arguments: arguments,
        timeout: VolumeRenameRules.timeout)
      DispatchQueue.main.async {
        if result.succeeded {
          Log.drive.info("Renamed volume \(volume.deviceIdentifier, privacy: .public)")
        } else {
          Log.drive.error(
            "Rename failed for \(volume.deviceIdentifier, privacy: .public), exit \(result.exitCode ?? -1, privacy: .public)"
          )
          let failure = VolumeRenameRules.failure(for: result, volumeName: volume.name)
          self.userActionError = AppAlert(
            title: failure.title, message: failure.message, kind: .basic)
        }
        self.refreshDrives(qos: .userInitiated) {
          self.setBusy(volume.id, false)
        }
      }
    }
  }
}
