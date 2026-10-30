//  Created by homielab.com

import Foundation

extension KeepAliveManager {
  // MARK: - Reconnect Sweep

  /// Checks every keep-alive target and reconnects the ones that are down.
  ///
  /// Always hops to the main queue: mount completions and the published state
  /// it reads are main-thread bound, and `isSweeping` serializes sweeps.
  func sweep() {
    guard isEnabled, !isSweeping else { return }
    // Nothing to keep alive: skip the mount table scan entirely so the
    // periodic timer costs nothing for most users.
    let hasShareTargets = !keepAliveShares.isEmpty
    guard hasShareTargets || !PersistenceManager.shared.keepAliveVolumes.isEmpty
    else { return }
    isSweeping = true
    sweepGeneration &+= 1
    let generation = sweepGeneration

    let group = DispatchGroup()
    if hasShareTargets {
      // Hold the group open until the status refresh has run and the
      // reconnect work has been queued, so `isSweeping` can't clear early
      // and let a second sweep overlap this one.
      group.enter()
      NetworkMountManager.shared.refreshMountStatus(readUsage: false) { [weak self] in
        defer { group.leave() }
        guard let self else { return }
        self.reconnectShares(group: group)
        self.reconnectVolumes(group: group)
      }
    } else {
      // Only volumes to keep alive: the network mount table isn't needed.
      reconnectVolumes(group: group)
    }

    group.notify(queue: .main) { [weak self] in
      guard let self else { return }
      // Targets that vanished while the sweep ran (drive pulled, share
      // removed) must not keep the "reconnecting" badge up.
      self.reconcileTargets()
      self.finishSweep(generation: generation)
    }

    // Watchdog: never let one stuck completion block all future sweeps.
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.sweepWatchdogInterval) {
      [weak self] in
      guard let self, self.isSweeping, self.sweepGeneration == generation else { return }
      Log.keepAlive.error("Keep-alive sweep did not finish in time; allowing new sweeps.")
      self.finishSweep(generation: generation)
    }
  }

  /// Ends sweep `generation` (if it is still the running one) and starts the
  /// sweep requested meanwhile, if any. Main thread only.
  func finishSweep(generation: Int) {
    guard isSweeping, sweepGeneration == generation else { return }
    isSweeping = false
    runPendingSweep()
  }

  private func reconnectShares(group: DispatchGroup) {
    let shares = keepAliveShares
    guard !shares.isEmpty else { return }

    // The mounted-set snapshot was just refreshed by the sweep prologue.
    let mountedIDs = NetworkMountManager.shared.mountedShareIDs

    for share in shares {
      if mountedIDs.contains(share.id) {
        recordResult(shareID: share.id, name: share.name, success: true)
        continue
      }
      guard !isSuppressed(shareID: share.id) else { continue }
      guard isDueForRetry(shareID: share.id) else { continue }

      recordAttempt(shareID: share.id)
      group.enter()
      Log.keepAlive.notice("Attempting to remount network share \(share.name, privacy: .private).")
      // Not user-initiated: keeps the backoff state just recorded and any
      // user suppression intact.
      NetworkMountManager.shared.mount(share: share, userInitiated: false) {
        [weak self] success, error in
        self?.recordResult(shareID: share.id, name: share.name, success: success)
        if success {
          Log.keepAlive.notice("Remounted \(share.name, privacy: .private).")
        } else {
          Log.keepAlive.error(
            "Remount failed for \(share.name, privacy: .private): \(error ?? "skipped", privacy: .private)"
          )
        }
        group.leave()
      }
    }
  }

  private func reconnectVolumes(group: DispatchGroup) {
    let keepAliveVolumes = PersistenceManager.shared.keepAliveVolumes
    guard !keepAliveVolumes.isEmpty else { return }

    let drives = DriveManager.shared
    let candidateVolumes = Self.volumeCandidates(
      disks: drives.physicalDisks ?? [], isStale: drives.isShowingStaleDisks,
      unverifiedDiskIDs: drives.unverifiedDiskIDs,
      keepAliveIDs: Set(keepAliveVolumes.map(\.id)),
      isBlocked: PersistenceManager.shared.isVolumeBlocked)

    for volume in candidateVolumes {
      guard let compositeId = volume.compositeId else { continue }
      if volume.isMounted {
        recordResult(volumeID: compositeId, name: volume.name, success: true)
        continue
      }
      guard !isSuppressed(volumeID: compositeId) else { continue }
      guard isDueForRetry(volumeID: compositeId) else { continue }
      // Another mount or unmount is running: skip without counting an attempt.
      guard !DriveManager.shared.isBusy(volume.id) else { continue }

      recordAttempt(volumeID: compositeId)
      group.enter()
      Log.keepAlive.notice("Attempting to remount volume \(volume.name, privacy: .private).")
      // Silent mount: transient reconnect failures must not pop error dialogs.
      // The result is recorded when the mount really finishes, however long a
      // slow (spinning) drive takes.
      remount(
        volume: volume,
        mounter: { volume, completion in
          DriveManager.shared.mount(
            volume: volume, allowsErrorAlerts: false, isUserInitiated: false,
            trigger: .keepAlive, completion: completion)
        },
        completion: { [weak self] result in
          var succeeded = false
          if case .success = result { succeeded = true }
          self?.recordResult(volumeID: compositeId, name: volume.name, success: succeeded)
          group.leave()
        })
    }
  }

  /// Keep-alive volumes the sweep may check, in list order.
  ///
  /// After a failed refresh (`isStale`) the list may show disks that are gone
  /// or changed, and an unverified disk's volumes may not be what they seem:
  /// skip them until fresh data arrives instead of reporting "Cannot
  /// Reconnect" for a drive that isn't there.
  static func volumeCandidates(
    disks: [PhysicalDisk], isStale: Bool, unverifiedDiskIDs: Set<String>,
    keepAliveIDs: Set<String>, isBlocked: (Volume) -> Bool
  ) -> [Volume] {
    guard !isStale else { return [] }
    return disks.filter { !unverifiedDiskIDs.contains($0.id) }
      .flatMap(\.allVolumes)
      .filter { volume in
        guard let compositeId = volume.compositeId else { return false }
        return keepAliveIDs.contains(compositeId) && !isBlocked(volume)
      }
  }

  /// Runs `mounter` and reports its result once, on the main thread, when it
  /// completes. If it never completes, reports a timeout failure after
  /// `timeout` so a stuck mount cannot block the sweep. Internal (not private)
  /// for unit tests.
  func remount(
    volume: Volume,
    mounter: (Volume, @escaping (Result<Void, Error>) -> Void) -> Void,
    timeout: TimeInterval = DriveManager.mountUnmountTimeout * 2 + 20,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    let lock = NSLock()
    var finished = false
    let finish: (Result<Void, Error>) -> Void = { result in
      lock.lock()
      let isFirst = !finished
      finished = true
      lock.unlock()
      guard isFirst else { return }
      DispatchQueue.main.async { completion(result) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
      finish(.failure(MountFailure.timedOut()))
    }
    mounter(volume, finish)
  }
}
