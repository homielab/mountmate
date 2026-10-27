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
    // A RAID master is a virtual logical disk. `eject` is only valid for a
    // physical device, while unmountDisk safely unmounts every volume in the
    // set and produces the same Finder-visible result.
    let ejectArgs = disk.isRAIDSet ? ["unmountDisk", disk.id] : ["eject", disk.id]
    // A sleeping (spun-down) disk has to wake before it can be ejected,
    // which can take well over the default 15s. The first attempt often
    // unmounts the volumes but fails the eject while the drive spins up,
    // so allow more time and retry once, 2 s later, before reporting an
    // error (#70).
    let ejectTimeout: TimeInterval = 60
    let runEject = {
      runProcess(executable: "/usr/sbin/diskutil", arguments: ejectArgs, timeout: ejectTimeout)
    }
    let finish: (ProcessResult) -> Void = { result in
      DispatchQueue.main.async {
        if !result.succeeded {
          KeepAliveManager.shared.unsuppress(volumes: disk.allVolumes, keeping: wasSuppressed)
          self.setEjecting(disk.id, false)
          self.handleDiskUtilError(
            DiskUtilErrorClassifier.failureMessage(for: result, timeout: ejectTimeout),
            for: disk.name ?? disk.id, disk: disk, operation: .eject)
          self.refreshDrives(qos: .userInitiated)
        } else {
          self.refreshDrives(qos: .userInitiated) { self.setEjecting(disk.id, false) }
        }
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
        let failure: (result: ProcessResult, operation: DiskOperation)? =
          switch outcome {
          case .succeeded: nil
          case .unmountFailed(let result): (result, .unmount)
          case .ejectFailed(let result): (result, .eject)
          }
        if let failure {
          KeepAliveManager.shared.unsuppress(volumes: disk.allVolumes, keeping: wasSuppressed)
          self.setEjecting(disk.id, false)
          self.handleDiskUtilError(
            DiskUtilErrorClassifier.failureMessage(for: failure.result, timeout: timeout),
            for: disk.name ?? disk.id, disk: disk, operation: failure.operation)
          self.refreshDrives(qos: .userInitiated)
        } else {
          self.refreshDrives(qos: .userInitiated) { self.setEjecting(disk.id, false) }
        }
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
        if !result.succeeded {
          KeepAliveManager.shared.unsuppress(volumes: [volume], keeping: wasSuppressed)
          self.setBusy(volume.id, false)
          self.handleDiskUtilError(
            DiskUtilErrorClassifier.failureMessage(for: result, timeout: Self.mountUnmountTimeout),
            for: volume.name, volume: volume, operation: .unmount)
          self.refreshDrives(qos: .userInitiated)
        } else {
          self.refreshDrives(qos: .userInitiated) { self.setBusy(volume.id, false) }
        }
      }
    }
  }
}
