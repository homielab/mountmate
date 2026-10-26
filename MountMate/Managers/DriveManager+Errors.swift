//  Created by homielab.com

import Foundation

extension DriveManager {
  // MARK: - Error Handling

  func handleDiskUtilError(
    _ error: String, for name: String, volume: Volume? = nil, disk: PhysicalDisk? = nil,
    operation: DiskOperation
  ) {
    let parsedError = DiskUtilErrorClassifier.classify(error, for: name, operation: operation)

    if parsedError == .mountLockedVolume {
      guard let volume else {
        userActionError = AppAlert(
          title: String(
            format: NSLocalizedString("“%@” is locked", comment: "Alert title"), name),
          message: String(
            format: NSLocalizedString(
              "Enter the password to unlock “%@”", comment: "Alert message"), name),
          kind: .basic)
        return
      }
      if !unlocker.unlockWithSavedPassword(volume) {
        unlocker.presentUnlockPrompt(for: volume, passwordFailed: false)
      }
      return
    }
    guard
      let text = DiskUtilErrorClassifier.presentation(
        for: parsedError, name: name, operation: operation, details: error)
    else { return }

    let kind: AppAlertKind
    switch parsedError {
    case .unmountBusyVolume:
      kind = disk.map { disk in .forceEject { self.forceEject(disk: disk) } } ?? .basic
    case .inUse where operation == .eject:
      kind = disk.map { disk in .forceEject { self.forceEject(disk: disk) } } ?? .basic
    case .inUse where operation == .unmount:
      kind = volume.map { volume in .forceUnmount { self.forceUnmount(volume: volume) } } ?? .basic
    default:
      kind = .basic
    }
    userActionError = AppAlert(title: text.title, message: text.message, kind: kind)
  }
}
