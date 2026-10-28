//  Created by homielab.com

import Foundation

extension DriveManager {
  func eject(disk: PhysicalDisk) {
    // Nothing could confirm what this disk is (it may be the internal
    // disk). Never refuse silently. Disk images are never internal.
    guard disk.type == .diskImage || !unverifiedDiskIDs.contains(disk.id) else {
      userActionError = AppAlert(
        title: NSLocalizedString("Eject Failed", comment: "Alert title"),
        message: String(
          format: NSLocalizedString(
            "MountMate could not determine whether “%@” is an external disk, so it was not ejected. Try again in a moment.",
            comment: "Eject refused because the disk type is unknown; disk name"),
          disk.name ?? disk.id),
        kind: .basic)
      return
    }
    let wasSuppressed = KeepAliveManager.shared.suppressedVolumes(among: disk.allVolumes)
    KeepAliveManager.shared.suppress(volumes: disk.allVolumes)
    setEjecting(disk.id, true)
    // A RAID master is a virtual logical disk: `ejectArguments` unmounts its
    // volumes instead. A sleeping (spun-down) disk has to wake before it can
    // be ejected: the first attempt often unmounts the volumes but fails the
    // eject while the drive spins up, so allow `ejectTimeout` and retry once,
    // 2 s later, before reporting an error (#70).
    let ejectArgs = BulkVolumeActions.ejectArguments(for: disk)
    let ejectTimeout = BulkVolumeActions.ejectTimeout
    let runEject = {
      runProcess(executable: "/usr/sbin/diskutil", arguments: ejectArgs, timeout: ejectTimeout)
    }
    let finish: (ProcessResult) -> Void = { result in
      DispatchQueue.main.async {
        self.finishDiskOperation(
          failure: result.succeeded
            ? nil : (result: result, operation: .eject, timeout: ejectTimeout),
          name: disk.name ?? disk.id, disk: disk,
          restoreKeepAlive: {
            KeepAliveManager.shared.unsuppress(volumes: disk.allVolumes, keeping: wasSuppressed)
          },
          endProgress: { self.setEjecting(disk.id, false) })
      }
    }
    DispatchQueue.global(qos: .userInitiated).async {
      let result = runEject()
      guard
        !result.succeeded && !result.timedOut
          && !DiskUtilErrorClassifier.isBusyFailure(stderr: result.stderr)
      else { return finish(result) }
      DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2) {
        finish(runEject())
      }
    }
  }

  func forceEject(disk: PhysicalDisk) {
    let wasSuppressed = KeepAliveManager.shared.suppressedVolumes(among: disk.allVolumes)
    KeepAliveManager.shared.suppress(volumes: disk.allVolumes)
    setEjecting(disk.id, true)
    DispatchQueue.global(qos: .userInitiated).async {
      let timeout = Self.mountUnmountTimeout
      let forceUnmountResult = runProcess(
        executable: "/usr/sbin/diskutil", arguments: ["unmountDisk", "force", disk.id],
        timeout: timeout)
      // A failed force unmount is the real reason the disk stays: report it
      // and do not eject on top of it.
      let ejectResult: ProcessResult? =
        disk.isRAIDSet || !ForceEjectOutcome.shouldEject(afterUnmount: forceUnmountResult)
        ? nil
        : runProcess(
          executable: "/usr/sbin/diskutil", arguments: ["eject", disk.id], timeout: timeout)
      let outcome = ForceEjectOutcome.choose(
        unmountResult: forceUnmountResult, ejectResult: ejectResult)
      DispatchQueue.main.async {
        let failure: DiskOperationFailure? =
          switch outcome {
          case .succeeded: nil
          case .unmountFailed(let result): (result, .unmount, timeout)
          case .ejectFailed(let result): (result, .eject, timeout)
          }
        self.finishDiskOperation(
          failure: failure, name: disk.name ?? disk.id, disk: disk,
          restoreKeepAlive: {
            KeepAliveManager.shared.unsuppress(volumes: disk.allVolumes, keeping: wasSuppressed)
          },
          endProgress: { self.setEjecting(disk.id, false) })
      }
    }
  }

  func forceUnmount(volume: Volume) {
    let wasSuppressed = KeepAliveManager.shared.suppressedVolumes(among: [volume])
    KeepAliveManager.shared.suppress(volume: volume)
    setBusy(volume.id, true)
    DispatchQueue.global(qos: .userInitiated).async {
      let result = runProcess(
        executable: "/usr/sbin/diskutil", arguments: ["unmount", "force", volume.deviceIdentifier],
        timeout: Self.mountUnmountTimeout)
      DispatchQueue.main.async {
        self.finishDiskOperation(
          failure: result.succeeded
            ? nil : (result: result, operation: .unmount, timeout: Self.mountUnmountTimeout),
          name: volume.name, volume: volume,
          restoreKeepAlive: {
            KeepAliveManager.shared.unsuppress(volumes: [volume], keeping: wasSuppressed)
          },
          endProgress: { self.setBusy(volume.id, false) })
      }
    }
  }

  /// The diskutil call that failed, which operation it was and its timeout.
  typealias DiskOperationFailure = (
    result: ProcessResult, operation: DiskOperation, timeout: TimeInterval
  )

  /// The common end of Eject, Force Eject and Force Unmount, on the main
  /// thread. On failure: let Keep Alive watch the volumes again, end the
  /// progress state, report the translated error and refresh. On success the
  /// progress state ends only once the refreshed list is in, so the row does
  /// not flash back to "mounted".
  private func finishDiskOperation(
    failure: DiskOperationFailure?, name: String, disk: PhysicalDisk? = nil,
    volume: Volume? = nil, restoreKeepAlive: () -> Void,
    endProgress: @escaping () -> Void
  ) {
    guard let failure else {
      refreshDrives(qos: .userInitiated, then: endProgress)
      return
    }
    restoreKeepAlive()
    endProgress()
    handleDiskUtilError(
      DiskUtilErrorClassifier.failureMessage(for: failure.result, timeout: failure.timeout),
      for: name, volume: volume, disk: disk, operation: failure.operation)
    refreshDrives(qos: .userInitiated)
  }
}
