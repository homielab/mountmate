//  Created by homielab.com

import Foundation

extension DriveManager {
  // MARK: - Mount and Unmount

  /// Mounts a volume.
  ///
  /// - Parameter readOnly: Mount with `diskutil mount readOnly`.
  /// - Parameter allowsErrorAlerts: Pass `false` for automatic (keep-alive)
  ///   mount attempts so transient reconnect failures never surface as error
  ///   dialogs.
  /// - Parameter isUserInitiated: Set to `false` for automatic reconnects so
  ///   blocked-volume mount approval cannot be bypassed.
  /// - Parameter trigger: What asked for the mount; decides whether
  ///   "Open in Finder after mounting" applies (see `OpenAfterMountRules`).
  /// - Parameter completion: Called on the main thread once the mount has
  ///   finished (including the retry and the disk list refresh), with the
  ///   failure message of `diskutil` when it did not succeed.
  func mount(
    volume: Volume, readOnly: Bool = false, allowsErrorAlerts: Bool = true,
    isUserInitiated: Bool = true, trigger: MountTrigger = .automatic,
    completion: ((Result<Void, Error>) -> Void)? = nil
  ) {
    if isUserInitiated {
      let userInfo = ["deviceIdentifier": volume.deviceIdentifier]
      NotificationCenter.default.post(name: .willManuallyMount, object: nil, userInfo: userInfo)
    }
    KeepAliveManager.shared.resume(volume: volume)
    // Stays set through the retry below and is cleared in handleMountResult.
    setBusy(volume.id, true)
    DispatchQueue.global(qos: .userInitiated).async {
      let result = runProcess(
        executable: "/usr/sbin/diskutil",
        arguments: Self.mountArguments(for: volume, readOnly: readOnly),
        timeout: Self.mountUnmountTimeout)
      if isUserInitiated {
        Self.postDidFinishManualMount(volume)
      }

      if self.shouldRetryMount(after: result, volume: volume) {
        Log.drive.notice(
          "Initial mount failed for \(volume.deviceIdentifier, privacy: .public) shortly after it appeared, possibly due to a race condition. Retrying in \(Int(MountRetryRules.retryDelay), privacy: .public)s"
        )

        DispatchQueue.global(qos: .userInitiated).asyncAfter(
          deadline: .now() + MountRetryRules.retryDelay
        ) {
          if isUserInitiated {
            let userInfo = ["deviceIdentifier": volume.deviceIdentifier]
            NotificationCenter.default.post(
              name: .willManuallyMount, object: nil, userInfo: userInfo)
          }
          let retryResult = runProcess(
            executable: "/usr/sbin/diskutil",
            arguments: Self.mountArguments(for: volume, readOnly: readOnly),
            timeout: Self.mountUnmountTimeout)
          if isUserInitiated {
            Self.postDidFinishManualMount(volume)
          }
          self.handleMountResult(
            retryResult, for: volume, allowsErrorAlerts: allowsErrorAlerts, trigger: trigger,
            completion: completion)
        }
      } else {
        self.handleMountResult(
          result, for: volume, allowsErrorAlerts: allowsErrorAlerts, trigger: trigger,
          completion: completion)
      }
    }
  }

  /// Opens a Finder window for each of `volumeIDs` that is now mounted, when
  /// "Open in Finder after mounting" is on and `trigger` is a user request.
  /// Call on the main thread after the drive list refreshed.
  func openInFinderAfterMounting(_ volumeIDs: [String], trigger: MountTrigger) {
    let mountPoints = OpenAfterMountRules.mountPoints(
      afterMounting: volumeIDs, in: (physicalDisks ?? []).flatMap(\.allVolumes),
      trigger: trigger, isEnabled: OpenAfterMountRules.isEnabled(),
      isBlocked: { PersistenceManager.shared.isVolumeBlocked($0) })
    OpenAfterMountRules.open(mountPoints)
  }

  /// The `diskutil` arguments that mount `volume`.
  static func mountArguments(for volume: Volume, readOnly: Bool) -> [String] {
    readOnly
      ? ["mount", "readOnly", volume.deviceIdentifier] : ["mount", volume.deviceIdentifier]
  }

  private func shouldRetryMount(after result: ProcessResult, volume: Volume) -> Bool {
    MountRetryRules.shouldRetry(after: result, firstSeen: firstSeen(of: volume), now: Date())
  }

  /// One plain `diskutil mount` of a volume (no read-only, no retry).
  static func runMount(of volume: Volume) -> ProcessResult {
    runProcess(
      executable: "/usr/sbin/diskutil", arguments: mountArguments(for: volume, readOnly: false),
      timeout: mountUnmountTimeout)
  }

  static func postDidFinishManualMount(_ volume: Volume) {
    NotificationCenter.default.post(
      name: .didFinishManualMount, object: nil,
      userInfo: ["deviceIdentifier": volume.deviceIdentifier])
  }

  private func handleMountResult(
    _ result: ProcessResult, for volume: Volume, allowsErrorAlerts: Bool = true,
    trigger: MountTrigger, completion: ((Result<Void, Error>) -> Void)? = nil
  ) {
    DispatchQueue.main.async {
      guard !result.succeeded else {
        // Keep the spinner until the list shows the volume as mounted.
        self.refreshDrives(qos: .userInitiated) {
          self.setBusy(volume.id, false)
          self.openInFinderAfterMounting([volume.id], trigger: trigger)
          completion?(.success(()))
        }
        return
      }
      // Cleared before handling the error: a locked volume starts an unlock
      // that marks the volume busy again.
      self.setBusy(volume.id, false)
      if allowsErrorAlerts {
        self.handleDiskUtilError(
          DiskUtilErrorClassifier.failureMessage(for: result, timeout: Self.mountUnmountTimeout),
          for: volume.name, volume: volume, operation: .mount)
      }
      self.refreshDrives(qos: .userInitiated) {
        completion?(
          .failure(
            MountFailure(
              message: DiskUtilErrorClassifier.failureMessage(
                for: result, timeout: Self.mountUnmountTimeout))))
      }
    }
  }

  /// Unmounts a volume, never forced.
  ///
  /// - Parameter allowsErrorAlerts: Pass `false` when the caller reports the
  ///   failure itself (Shortcuts).
  /// - Parameter completion: Called on the main thread once the unmount has
  ///   finished and the disk list is refreshed, with the failure message of
  ///   `diskutil` when it did not succeed.
  func unmount(
    volume: Volume, allowsErrorAlerts: Bool = true,
    completion: ((Result<Void, Error>) -> Void)? = nil
  ) {
    let wasSuppressed = KeepAliveManager.shared.suppressedVolumes(among: [volume])
    KeepAliveManager.shared.suppress(volume: volume)
    WakeRemountManager.shared.forget([volume])
    setBusy(volume.id, true)
    DispatchQueue.global(qos: .userInitiated).async {
      let result = runProcess(
        executable: "/usr/sbin/diskutil",
        arguments: ["unmount", volume.deviceIdentifier], timeout: Self.mountUnmountTimeout)
      DispatchQueue.main.async {
        if !result.succeeded {
          // Still mounted: keep-alive must keep protecting it.
          KeepAliveManager.shared.unsuppress(volumes: [volume], keeping: wasSuppressed)
          self.setBusy(volume.id, false)
          let message = DiskUtilErrorClassifier.failureMessage(
            for: result, timeout: Self.mountUnmountTimeout)
          if allowsErrorAlerts {
            self.handleDiskUtilError(
              message, for: volume.name, volume: volume, operation: .unmount)
          }
          self.refreshDrives(qos: .userInitiated) {
            completion?(.failure(MountFailure(message: message)))
          }
        } else if let image = self.diskImageToDetach(afterUnmounting: volume) {
          // Match Finder: once the last volume of a disk image is unmounted,
          // detach the image so it no longer lingers in the list (#72). The
          // disk's eject spinner takes over from the volume's.
          self.setBusy(volume.id, false)
          self.eject(disk: image)
          completion?(.success(()))
        } else {
          self.refreshDrives(qos: .userInitiated) {
            self.setBusy(volume.id, false)
            completion?(.success(()))
          }
        }
      }
    }
  }

  /// Unmounts a volume that "Unmount When Idle" found unused. Never forced
  /// and never shows an alert: a volume still in use only gets a log line,
  /// and `completion(false)`. Keep-alive is not suppressed (keep-alive
  /// volumes are never unmounted for being idle). Call on the main thread;
  /// `completion` runs on the main thread.
  func unmountIdleVolume(_ volume: Volume, completion: @escaping (Bool) -> Void) {
    guard !isBusy(volume.id) else {
      completion(false)
      return
    }
    setBusy(volume.id, true)
    DispatchQueue.global(qos: .utility).async {
      let result = runProcess(
        executable: "/usr/sbin/diskutil",
        arguments: ["unmount", volume.deviceIdentifier], timeout: Self.mountUnmountTimeout)
      DispatchQueue.main.async {
        guard result.succeeded else {
          Log.drive.info(
            "Idle unmount of \(volume.name, privacy: .private) skipped (exit \(result.exitCode ?? -1, privacy: .public), timed out: \(result.timedOut, privacy: .public)); retrying after another idle period"
          )
          self.setBusy(volume.id, false)
          completion(false)
          return
        }
        Log.drive.info("Unmounted idle volume \(volume.name, privacy: .private)")
        self.refreshDrives(qos: .utility) { self.setBusy(volume.id, false) }
        completion(true)
      }
    }
  }

  /// The disk image containing `volume`, if no other volume on it is still
  /// mounted. Returns nil for real disks, which stay attached after unmount.
  private func diskImageToDetach(afterUnmounting volume: Volume) -> PhysicalDisk? {
    guard
      let disk = (physicalDisks ?? []).first(where: {
        $0.type == .diskImage && $0.allVolumes.contains { $0.id == volume.id }
      })
    else { return nil }
    let othersMounted = disk.allVolumes.contains { $0.id != volume.id && $0.isMounted }
    return othersMounted ? nil : disk
  }

  /// Whether `remount(volume:)` mounts `volume` again read-only: a volume
  /// that was mounted read-only (a backup or a damaged disk) stays read-only
  /// after its mount point changes.
  static func remountReadOnly(for volume: Volume) -> Bool {
    volume.isReadOnly
  }

  func remount(volume: Volume) {
    // Captured before the unmount, which clears the mount state.
    let readOnly = Self.remountReadOnly(for: volume)
    // Keep-alive must not reconnect the volume in the gap between the
    // unmount and the mount below; mount(volume:) resumes it.
    let wasSuppressed = KeepAliveManager.shared.suppressedVolumes(among: [volume])
    KeepAliveManager.shared.suppress(volume: volume)
    setBusy(volume.id, true)
    DispatchQueue.global(qos: .userInitiated).async {
      let result = runProcess(
        executable: "/usr/sbin/diskutil",
        arguments: ["unmount", volume.deviceIdentifier], timeout: Self.mountUnmountTimeout)
      DispatchQueue.main.async {
        if !result.succeeded {
          // Still mounted: undo the suppression.
          KeepAliveManager.shared.unsuppress(volumes: [volume], keeping: wasSuppressed)
          self.setBusy(volume.id, false)
          self.handleDiskUtilError(
            DiskUtilErrorClassifier.failureMessage(for: result, timeout: Self.mountUnmountTimeout),
            for: volume.name, volume: volume, operation: .unmount)
          self.refreshDrives(qos: .userInitiated)
          return
        }

        // Stays busy: mount(volume:) clears it when it finishes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
          self.mount(volume: volume, readOnly: readOnly)
        }
      }
    }
  }
}
