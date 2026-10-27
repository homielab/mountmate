//  Created by homielab.com

import Foundation

// MARK: - Custom Mount Points (/etc/fstab)

extension PersistenceManager {
  func customMountPoint(for volume: Volume) -> VolumeCustomMountPoint? {
    // Custom mount points are /etc/fstab rules addressed by volume UUID, so
    // only volumes with a real UUID can have one.
    guard volume.stableVolumeUUID != nil else { return nil }
    let identifier = stableIdentifier(for: volume)
    return customMountPoints.first { $0.id == identifier }
  }

  /// Outcome of an asynchronous custom mount point update.
  enum CustomMountPointUpdateResult: Equatable {
    case success
    /// The user dismissed the administrator password prompt; nothing changed.
    case cancelled
    /// A localized message to show to the user.
    case failure(String)
  }

  /// Adds or replaces the volume's custom mount point: writes its /etc/fstab
  /// rule (which may show the administrator password prompt), then saves it
  /// in MountMate's list.
  ///
  /// The `diskutil` lookup and the privileged write run as a fstab job
  /// (`StartupBlockCoordinator.enqueueFstabJob`), so the UI never waits for
  /// the password prompt, and the update is serialized with startup-block
  /// reconciles. Call on the main thread;
  /// `completion` is called on the main thread.
  func applyCustomMountPoint(
    _ mountPoint: String, for volume: Volume,
    completion: @escaping (CustomMountPointUpdateResult) -> Void
  ) {
    guard !isVolumeBlocked(volume) else {
      completion(
        .failure(
          NSLocalizedString(
            "Custom Mount Point Volume Blocked",
            comment: "Custom mount point blocked-volume error")))
      return
    }
    guard let volumeUUID = volumeUUIDForSystemMount(for: volume) else {
      completion(
        .failure(
          NSLocalizedString(
            "Custom Mount Point Requires UUID",
            comment: "Custom mount point system configuration error")))
      return
    }

    startupBlock.enqueueFstabJob {
      guard let fileSystemType = self.volumeLookup.fstabFileSystemType(for: volume) else {
        MainQueue.perform {
          completion(
            .failure(
              NSLocalizedString(
                "Custom Mount Point Unsupported File System",
                comment: "Custom mount point system configuration error")))
        }
        return
      }

      do {
        let snapshot = try FstabWriter.loadSnapshot()
        let currentContents = snapshot.contents
        let updatedContents = try FstabRules.updatedFstabContents(
          from: currentContents,
          volumeUUID: volumeUUID,
          identifier: self.stableIdentifier(for: volume),
          mountPoint: mountPoint,
          fileSystemType: fileSystemType
        )

        // The volume may have been blocked while this job waited in the
        // queue (e.g. behind another password prompt). Read the current
        // state, as reconcile does.
        let isBlockedNow = await MainQueue.value { self.isVolumeBlocked(volume) }
        guard !isBlockedNow else {
          MainQueue.perform {
            completion(
              .failure(
                NSLocalizedString(
                  "Custom Mount Point Volume Blocked",
                  comment: "Custom mount point blocked-volume error")))
          }
          return
        }

        if updatedContents != currentContents {
          try await FstabWriter.install(updatedContents, expectedCurrent: snapshot.raw)
        }

        MainQueue.perform {
          self.saveCustomMountPoint(mountPoint, for: volume)
          completion(.success)
        }
      } catch {
        let result = Self.customMountPointUpdateResult(for: error)
        MainQueue.perform { completion(result) }
      }
    }
  }

  /// Removes the volume's custom mount point: its /etc/fstab rule (which
  /// may show the administrator password prompt) and its saved entry. Runs
  /// like `applyCustomMountPoint`. Call on the main thread; `completion` is
  /// called on the main thread.
  func removeCustomMountPoint(
    for volume: Volume, completion: @escaping (CustomMountPointUpdateResult) -> Void
  ) {
    removeCustomMountPoint(
      volumeUUID: volumeUUIDForSystemMount(for: volume),
      entryID: stableIdentifier(for: volume),
      completion: completion)
  }

  /// Same as `removeCustomMountPoint(for:completion:)`, from the saved entry
  /// alone, so entries of volumes that are not connected can be removed too.
  func removeCustomMountPoint(
    info: VolumeCustomMountPoint, completion: @escaping (CustomMountPointUpdateResult) -> Void
  ) {
    removeCustomMountPoint(
      volumeUUID: Self.normalizedSystemVolumeUUID(info.volumeUUID) != nil ? info.volumeUUID : nil,
      entryID: info.id,
      completion: completion)
  }

  /// - Parameters:
  ///   - volumeUUID: The UUID the /etc/fstab rule addresses, or nil when the
  ///     volume has none (then it cannot have a rule, and only the saved
  ///     entry is removed).
  ///   - entryID: The `VolumeCustomMountPoint.id` of the saved entry.
  private func removeCustomMountPoint(
    volumeUUID: String?, entryID: String,
    completion: @escaping (CustomMountPointUpdateResult) -> Void
  ) {
    startupBlock.enqueueFstabJob {
      do {
        if let volumeUUID {
          let snapshot = try FstabWriter.loadSnapshot()
          let currentContents = snapshot.contents
          let updatedContents = FstabRules.removingCustomMountEntry(
            volumeUUID: volumeUUID, from: currentContents)

          if updatedContents != currentContents {
            try await FstabWriter.install(updatedContents, expectedCurrent: snapshot.raw)
          }
        }

        MainQueue.perform {
          self.customMountPoints.removeAll { $0.id == entryID }
          self.saveCustomMountPoints()
          completion(.success)
        }
      } catch {
        let result = Self.customMountPointUpdateResult(for: error)
        MainQueue.perform { completion(result) }
      }
    }
  }

  private static func customMountPointUpdateResult(for error: Error)
    -> CustomMountPointUpdateResult
  {
    if FstabWriter.isAdminPromptCancellation(error) { return .cancelled }
    return .failure(
      String(
        format: NSLocalizedString(
          "Custom Mount Point System Save Error",
          comment: "Custom mount point system configuration error"),
        error.localizedDescription))
  }

  /// Main thread only.
  private func saveCustomMountPoint(_ mountPoint: String, for volume: Volume) {
    let identifier = stableIdentifier(for: volume)
    let info = VolumeCustomMountPoint(
      volumeUUID: volume.id,
      backingDiskIdentifier: backingDiskIdentifier(for: volume),
      name: volume.name,
      mountPoint: mountPoint
    )

    if let index = customMountPoints.firstIndex(where: { $0.id == identifier }) {
      customMountPoints[index] = info
    } else {
      customMountPoints.append(info)
    }
    saveCustomMountPoints()
  }
}
