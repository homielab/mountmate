//  Created by homielab.com

import Foundation

/// What `StartupBlockCoordinator` needs from /etc/fstab and `diskutil`. The
/// app uses `SystemFstabAccess`; tests pass a fake, so no test touches the
/// real /etc/fstab or asks for an administrator password.
protocol StartupBlockFstabAccess {
  func readContents() -> String
  func loadSnapshot() throws -> FstabWriter.Snapshot
  func install(_ contents: String, expectedCurrent: Data) throws
  func startupBlockEligibility(forVolumeUUID uuid: String) -> FstabRules.StartupBlockEligibility
}

/// The real /etc/fstab (`FstabWriter`) and `diskutil` (`FstabVolumeLookup`).
struct SystemFstabAccess: StartupBlockFstabAccess {
  let lookup: FstabVolumeLookup

  func readContents() -> String { FstabWriter.readSystemFstabContents() }
  func loadSnapshot() throws -> FstabWriter.Snapshot { try FstabWriter.loadSnapshot() }
  func install(_ contents: String, expectedCurrent: Data) throws {
    try FstabWriter.install(contents, expectedCurrent: expectedCurrent)
  }
  func startupBlockEligibility(forVolumeUUID uuid: String) -> FstabRules.StartupBlockEligibility {
    lookup.startupBlockEligibility(forVolumeUUID: uuid)
  }
}

/// The owner of the settings and the list of blocked volumes, which the
/// coordinator reads and reports to. All calls arrive on the main thread.
protocol StartupBlockHost: AnyObject {
  /// The wanted state: the "Block at Startup" setting and the blocked list.
  func startupBlockState() -> (enabled: Bool, blockedInfos: [ManagedVolumeInfo])
  /// A user-initiated update started or finished (shown as a spinner).
  func startupBlockUpdateInProgress(_ inProgress: Bool)
  /// The volume UUIDs that have a MountMate rule in /etc/fstab after a read
  /// or write.
  func startupBlockRulesDidChange(volumeUUIDs: Set<String>)
  /// A short message about what an explicit user action changed.
  func startupBlockShowFeedback(_ message: String)
  /// An update the user asked for failed (or its prompt was cancelled).
  func startupBlockDidFail(title: String, message: String)
}

/// Keeps the startup-block rules in /etc/fstab in step with the blocked list.
///
/// The Disk Arbitration approval callback only exists while MountMate is
/// running, but macOS mounts connected volumes during startup, before login
/// items launch. With "Block at Startup" on, each blocked volume is also
/// written to /etc/fstab as `UUID=… none <fs> rw,noauto`, which makes macOS
/// itself skip the automatic mount. Manual mounts (MountMate, Disk Utility,
/// `diskutil mount`) still work.
///
/// Rules can only be added while the volume is connected, because the
/// filesystem type is read from it. A blocked volume that is not connected
/// gets its rule the next time it appears and MountMate dissents its mount.
///
/// Every read-modify-write cycle runs on `queue`, so concurrent block,
/// unblock and reconcile actions (and custom mount point updates, which share
/// the queue) cannot interleave.
final class StartupBlockCoordinator {
  /// Serializes every /etc/fstab read-modify-write cycle.
  let queue = DispatchQueue(label: "com.homielab.mountmate.fstab")

  private static let declinedKey = "startupBlockBackgroundDeclined"

  private let defaults: UserDefaults
  private let access: StartupBlockFstabAccess
  private let scheduleDelay: TimeInterval
  private weak var host: StartupBlockHost?
  private var isReconcilePending = false

  init(
    defaults: UserDefaults, access: StartupBlockFstabAccess, host: StartupBlockHost,
    scheduleDelay: TimeInterval = 3.0
  ) {
    self.defaults = defaults
    self.access = access
    self.host = host
    self.scheduleDelay = scheduleDelay
  }

  /// Set when a background update fails (e.g. its admin prompt is cancelled).
  /// Background updates then stay quiet — also across launches — until the
  /// user blocks, unblocks or toggles the setting. Only touched on `queue`.
  private var backgroundUpdateDeclined: Bool {
    get { defaults.bool(forKey: Self.declinedKey) }
    set { defaults.set(newValue, forKey: Self.declinedKey) }
  }

  /// Called once shortly after launch. Adds rules for blocked volumes that
  /// were connected at boot without one, and removes leftover rules whose
  /// removal was cancelled earlier (e.g. after unblocking the last blocked
  /// volume, when the Disk Arbitration session is no longer running).
  /// Prompts only when /etc/fstab actually needs to change.
  func reconcileAtLaunch(enabled: Bool, knownRuleUUIDs: Set<String>) {
    guard enabled || !knownRuleUUIDs.isEmpty else { return }
    reconcile(userInitiated: false)
  }

  /// Schedules a coalesced background reconcile a few seconds out. Called
  /// when a blocked volume's auto-mount was just dissented: the volume is
  /// connected at that moment, so its missing rule can be added.
  func scheduleReconcile() {
    DispatchQueue.main.async { [weak self] in
      guard let self, let host = self.host, host.startupBlockState().enabled,
        !self.isReconcilePending
      else { return }
      self.isReconcilePending = true
      DispatchQueue.main.asyncAfter(deadline: .now() + self.scheduleDelay) { [weak self] in
        guard let self else { return }
        self.isReconcilePending = false
        self.reconcile(userInitiated: false)
      }
    }
  }

  /// Syncs MountMate's startup-block rules in /etc/fstab with the blocked
  /// list: adds rules for connected blocked volumes that lack one (only when
  /// the setting is on) and removes rules that are no longer wanted. Writes
  /// /etc/fstab at most once. Must be called on the main thread.
  ///
  /// - Parameters:
  ///   - userInitiated: Explicit user actions always try, even after an
  ///     earlier admin prompt was cancelled; background reconciles do not.
  ///   - silentOnCancel: Show no alert when the user cancels the
  ///     administrator prompt (the caller reports the failure itself).
  ///   - completion: Called on the main thread with false if the update failed.
  func reconcile(
    userInitiated: Bool, silentOnCancel: Bool = false, fromToggle: Bool = false,
    completion: ((Bool) -> Void)? = nil
  ) {
    if userInitiated { host?.startupBlockUpdateInProgress(true) }
    queue.async { [weak self] in
      guard let self else { return }
      defer {
        if userInitiated {
          DispatchQueue.main.async { self.host?.startupBlockUpdateInProgress(false) }
        }
      }
      if userInitiated {
        self.backgroundUpdateDeclined = false
      } else if self.backgroundUpdateDeclined {
        return
      }

      // Read the wanted state when the job runs, not when it was queued, so
      // jobs queued behind a password prompt act on the latest settings.
      // Several queued jobs collapse naturally: once one has applied the
      // current state, the rest find nothing to change and do not prompt.
      // (Safe: the main thread never waits on the queue.)
      let (enabled, blockedInfos) = DispatchQueue.main.sync {
        self.host?.startupBlockState() ?? (false, [])
      }

      do {
        let change = try self.applyRules(
          enabled: enabled, blockedInfos: blockedInfos, attemptsLeft: 2)
        if userInitiated,
          let message = FstabRules.feedbackMessage(
            for: change, enabled: enabled, fromToggle: fromToggle)
        {
          DispatchQueue.main.async { self.host?.startupBlockShowFeedback(message) }
        }
        DispatchQueue.main.async { completion?(true) }
      } catch {
        if userInitiated {
          if !(silentOnCancel && FstabWriter.isAdminPromptCancellation(error)) {
            self.handleError(error)
          }
        } else {
          // No alert for updates the user did not just ask for.
          self.backgroundUpdateDeclined = true
          Log.persistence.error(
            "Background startup block update failed; not retrying until the next user action: \(error.localizedDescription, privacy: .public)"
          )
        }
        DispatchQueue.main.async { completion?(false) }
      }
    }
  }

  /// One read-compute-write cycle of `reconcile`. Runs on `queue`. Retries
  /// when /etc/fstab changed between the read and the privileged write (e.g.
  /// a custom mount point was saved meanwhile).
  @discardableResult
  private func applyRules(
    enabled: Bool, blockedInfos: [ManagedVolumeInfo], attemptsLeft: Int
  ) throws -> FstabRules.StartupRuleChange {
    do {
      let snapshot = try access.loadSnapshot()
      let contents = snapshot.contents
      let diff = FstabRules.startupBlockDiff(
        enabled: enabled, blockedInfos: blockedInfos, contents: contents)

      for info in diff.alreadyHasEntry {
        Log.persistence.info(
          "“\(info.name, privacy: .private)” already has an /etc/fstab entry; not adding a startup block rule."
        )
      }
      var additions: [FstabRules.StartupBlockAddition] = []
      for (uuid, info) in diff.missing {
        switch access.startupBlockEligibility(forVolumeUUID: uuid) {
        case .eligible(let fileSystemType):
          additions.append(.init(uuid: uuid, fileSystemType: fileSystemType, info: info))
        case .notConnected:
          Log.persistence.info(
            "“\(info.name, privacy: .private)” is not connected; its startup block rule will be added when it next appears."
          )
        case .ineligible(let reason):
          Log.persistence.info(
            "No startup block rule for “\(info.name, privacy: .private)”: \(reason, privacy: .public)."
          )
        }
      }

      let stale = diff.stale
      guard !stale.isEmpty || !additions.isEmpty else {
        publishRules(from: contents)
        return FstabRules.StartupRuleChange(ruleCount: diff.present.count)
      }

      let (updated, skipped) = FstabRules.applyingStartupBlockChanges(
        to: contents, removing: stale, adding: additions)
      for addition in skipped {
        Log.persistence.error(
          "Skipped a startup block rule with unsafe fields (“\(addition.info.name, privacy: .private)”)."
        )
      }

      try access.install(updated, expectedCurrent: snapshot.raw)
      publishRules(from: updated)
      Log.persistence.notice(
        "Startup block rules updated (\(additions.count, privacy: .public) added, \(stale.count, privacy: .public) removed)."
      )
      return FstabRules.StartupRuleChange(
        addedNames: additions.map(\.info.name), removedCount: stale.count,
        ruleCount: diff.present.count - stale.count + additions.count)
    } catch let error as NSError
      where error.domain == "MountMate" && error.code == FstabWriter.fstabChangedErrorCode
      && attemptsLeft > 1
    {
      Log.persistence.notice(
        "/etc/fstab changed during the update; retrying with the new contents.")
      return try applyRules(
        enabled: enabled, blockedInfos: blockedInfos, attemptsLeft: attemptsLeft - 1)
    }
  }

  private func publishRules(from contents: String) {
    let uuids = FstabRules.managedFstabVolumeUUIDs(
      kinds: [FstabRules.mountMateBlockPrefix], in: contents)
    DispatchQueue.main.async { [weak self] in
      self?.host?.startupBlockRulesDidChange(volumeUUIDs: uuids)
    }
  }

  private func handleError(_ error: Error) {
    Log.persistence.error(
      "Failed to update startup block rules in /etc/fstab: \(error.localizedDescription, privacy: .public)"
    )
    // A cancelled password prompt is not an error; say plainly what it means.
    let message =
      FstabWriter.isAdminPromptCancellation(error)
      ? NSLocalizedString(
        "System Mount Rule Update Cancelled",
        comment: "Alert message when the admin prompt for a startup block rule was cancelled")
      : String(
        format: NSLocalizedString(
          "System Mount Rule Update Failed", comment: "Alert message"),
        error.localizedDescription)
    let title = NSLocalizedString("System Mount Rule Not Updated", comment: "Alert title")
    DispatchQueue.main.async { self.host?.startupBlockDidFail(title: title, message: message) }
  }
}
