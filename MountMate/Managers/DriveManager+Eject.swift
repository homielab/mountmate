//  Created by homielab.com

import Foundation

extension DriveManager {
  /// Ejects `disk`. `allowsErrorAlerts: false` keeps failures out of the
  /// popover (the caller reports them, e.g. a Shortcuts action). `completion`
  /// runs once on the main thread: after the refreshed list is in on success,
  /// or with the reason on a refusal or failure.
  func eject(
    disk: PhysicalDisk, allowsErrorAlerts: Bool = true,
    completion: ((Result<Void, Error>) -> Void)? = nil
  ) {
    guard startEjectIfIdle(disk) else {
      completion?(.failure(DiskOperationError.ejectInProgress()))
      return
    }
    // Nothing could confirm what this disk is (it may be the internal
    // disk). Never refuse silently. Disk images are never internal.
    guard disk.type == .diskImage || !unverifiedDiskIDs.contains(disk.id) else {
      let message = IntentMessages.ejectUnverified(name: disk.name ?? disk.id)
      if allowsErrorAlerts {
        userActionError = AppAlert(
          title: NSLocalizedString("Eject Failed", comment: "Alert title"),
          message: message, kind: .basic)
      }
      completion?(.failure(DiskOperationError(message: message)))
      return
    }
    let wasSuppressed = KeepAliveManager.shared.suppressedVolumes(among: disk.allVolumes)
    KeepAliveManager.shared.suppress(volumes: disk.allVolumes)
    setEjecting(disk.id, true)
    // A RAID master is a virtual logical disk: `ejectArguments` unmounts its
    // volumes instead. A sleeping disk gets one retry (`ejectWithRetry`, #70).
    let ejectTimeout = BulkVolumeActions.ejectTimeout
    let finish: (ProcessResult) -> Void = { result in
      DispatchQueue.main.async {
        self.finishDiskOperation(
          failure: result.succeeded
            ? nil : (result: result, operation: .eject, timeout: ejectTimeout),
          name: disk.name ?? disk.id, disk: disk,
          allowsErrorAlerts: allowsErrorAlerts, completion: completion,
          restoreKeepAlive: {
            KeepAliveManager.shared.unsuppress(volumes: disk.allVolumes, keeping: wasSuppressed)
          },
          endProgress: { self.setEjecting(disk.id, false) })
      }
    }
    DispatchQueue.global(qos: .userInitiated).async {
      finish(BulkVolumeActions.ejectWithRetry(disk))
    }
  }

  func forceEject(disk: PhysicalDisk) {
    guard startEjectIfIdle(disk) else { return }
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

  /// Skipped, with a log line only, while another operation runs on `volume`.
  func forceUnmount(volume: Volume) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { self.forceUnmount(volume: volume) }
      return
    }
    guard !rejectsAsBusy(volume) else { return }
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

  /// False (and logged, no alert) when an eject of `disk` is already
  /// running, e.g. Eject chosen twice from the right-click menu or during
  /// "Eject All External Disks": that eject keeps its spinner and its Keep
  /// Alive bookkeeping. Main thread only.
  func startEjectIfIdle(_ disk: PhysicalDisk) -> Bool {
    guard BulkVolumeActions.canStartEject(of: disk, ejectingDiskIDs: busyEjectingDiskIDs) else {
      Log.drive.info(
        "Eject of \(disk.name ?? disk.id, privacy: .private) ignored: already ejecting")
      return false
    }
    return true
  }

  /// The diskutil call that failed, which operation it was and its timeout.
  typealias DiskOperationFailure = (
    result: ProcessResult, operation: DiskOperation, timeout: TimeInterval
  )

  /// The user ejected `disk` on purpose: its volumes leave the plan of
  /// volumes to mount again after wake or unlock, so plugging it back in
  /// before then does not mount it. A failed eject keeps the plan (the
  /// volumes are still mounted). Nothing to do for a volume-only operation.
  static func forgetWakeRemount(
    afterEjecting disk: PhysicalDisk?, succeeded: Bool,
    wakeRemount: WakeRemountManager = .shared
  ) {
    guard succeeded, let disk else { return }
    wakeRemount.forget(disk.allVolumes)
  }

  /// The common end of Eject, Force Eject and Force Unmount, on the main
  /// thread. On failure: let Keep Alive watch the volumes again, end the
  /// progress state, report the translated error and refresh. On success the
  /// progress state ends only once the refreshed list is in, so the row does
  /// not flash back to "mounted".
  private func finishDiskOperation(
    failure: DiskOperationFailure?, name: String, disk: PhysicalDisk? = nil,
    volume: Volume? = nil, allowsErrorAlerts: Bool = true,
    completion: ((Result<Void, Error>) -> Void)? = nil,
    restoreKeepAlive: () -> Void, endProgress: @escaping () -> Void
  ) {
    Self.forgetWakeRemount(afterEjecting: disk, succeeded: failure == nil)
    guard let failure else {
      refreshDrives(qos: .userInitiated) {
        endProgress()
        completion?(.success(()))
      }
      return
    }
    restoreKeepAlive()
    endProgress()
    let raw = DiskUtilErrorClassifier.failureMessage(for: failure.result, timeout: failure.timeout)
    if allowsErrorAlerts {
      handleDiskUtilError(raw, for: name, volume: volume, disk: disk, operation: failure.operation)
    }
    let parsed = DiskUtilErrorClassifier.classify(raw, for: name, operation: failure.operation)
    let reason =
      DiskUtilErrorClassifier.presentation(
        for: parsed, name: name, operation: failure.operation, details: raw)?.message ?? raw
    completion?(.failure(DiskOperationError(message: reason)))
    refreshDrives(qos: .userInitiated)
  }
}

/// Why a disk operation did not happen, in words fit for the user.
struct DiskOperationError: LocalizedError, Equatable {
  let message: String
  var errorDescription: String? { message }

  /// The disk is already being ejected.
  static func ejectInProgress(
    localize: MountFailure.Localize = MountFailure.defaultLocalize
  ) -> DiskOperationError {
    DiskOperationError(message: localize("This disk is already being ejected."))
  }
}
