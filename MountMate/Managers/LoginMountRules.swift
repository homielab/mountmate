//  Created by homielab.com

import Foundation

/// Which "Mount at login" shares to try again, and when.
///
/// At login the Mac often starts MountMate before Wi-Fi is connected, or
/// before a NAS that lost power with it has booted, so the login mount
/// fails. With Keep Alive on, its reconnect sweep picks those shares up;
/// with Keep Alive off nothing else would, so the login mount is retried
/// on a timer (`retryDelays`) and each time the network becomes available,
/// a few times at most in total.
enum LoginMountRules {
  /// Retries per share after the mount at launch, for the whole session
  /// (timer and network retries together).
  static let maxRetries = 5

  /// Wait after a failed mount before retry 1, 2, 3, …; the last value
  /// repeats: about 6 minutes for all 5 retries, enough for a NAS to boot.
  static let retryDelays: [TimeInterval] = [15, 30, 60, 120]

  /// How long to wait before retry number `retry` (1-based); nil when the
  /// share has no retries left.
  static func retryDelay(beforeRetry retry: Int) -> TimeInterval? {
    guard retry >= 1, retry <= maxRetries, let last = retryDelays.last else { return nil }
    return retry <= retryDelays.count ? retryDelays[retry - 1] : last
  }

  /// When the retry timer should fire: the shortest wait among the shares
  /// still waiting (pending, not being mounted, retries left); nil when
  /// none is, so no timer runs.
  static func nextTimerDelay(
    pendingIDs: Set<UUID>, mountingIDs: Set<UUID>, retries: [UUID: Int]
  ) -> TimeInterval? {
    pendingIDs.subtracting(mountingIDs)
      .compactMap { retryDelay(beforeRetry: retries[$0, default: 0] + 1) }
      .min()
  }

  /// The shares to mount again now. A share qualifies while it is still
  /// marked "Mount at login", has not mounted since launch (`pendingIDs`),
  /// is not mounted now, is not already being mounted, was not unmounted by
  /// the user in MountMate (suppressed) and has retries left.
  static func sharesToRetry(
    shares: [NetworkShare],
    isNetworkAvailable: Bool,
    pendingIDs: Set<UUID>,
    mountingIDs: Set<UUID>,
    retries: [UUID: Int],
    isMounted: (NetworkShare) -> Bool,
    isSuppressed: (UUID) -> Bool
  ) -> [NetworkShare] {
    guard isNetworkAvailable else { return [] }
    return shares.filter { share in
      share.mountAtLogin
        && pendingIDs.contains(share.id)
        && !mountingIDs.contains(share.id)
        && retries[share.id, default: 0] < maxRetries
        && !isMounted(share)
        && !isSuppressed(share.id)
    }
  }
}

/// Mounts the "Mount at login" shares at launch and retries the ones that
/// failed on a one-shot timer and when the network comes up
/// (`LoginMountRules`). Main thread only.
final class LoginMountRetrier {
  /// Mounts a share automatically; calls back on the main thread with
  /// whether it mounted and the (sanitized) error.
  typealias Mount = (NetworkShare, @escaping (Bool, String?) -> Void) -> Void
  /// Runs the block once after the delay (seconds) on the main thread;
  /// returns a closure that cancels it.
  typealias Schedule = (TimeInterval, @escaping () -> Void) -> () -> Void

  private let shares: () -> [NetworkShare]
  private let isMounted: (NetworkShare) -> Bool
  private let isSuppressed: (UUID) -> Bool
  private let mount: Mount
  private let schedule: Schedule?
  private let retryWhenDue: (() -> Void)?
  private let onGiveUp: ((NetworkShare, String?) -> Void)?
  /// Shares already reported as given up, so each is reported once.
  private var gaveUpIDs = Set<UUID>()
  /// Cancels the pending retry timer; nil when none is scheduled.
  private var cancelTimer: (() -> Void)?

  /// Login shares that have not mounted since launch.
  private(set) var pendingIDs = Set<UUID>()
  /// Login shares with a mount in flight.
  private(set) var mountingIDs = Set<UUID>()
  /// Retries made per share (the mount at launch is not counted).
  private(set) var retries: [UUID: Int] = [:]

  /// `schedule` nil: no timer, only network retries. `retryWhenDue` runs
  /// when the timer fires (default: `retry()`). `onGiveUp` runs once per
  /// share when its last try fails (with the sanitized error), unless the
  /// share was mounted or unmounted by the user meanwhile.
  init(
    shares: @escaping () -> [NetworkShare],
    isMounted: @escaping (NetworkShare) -> Bool,
    isSuppressed: @escaping (UUID) -> Bool,
    mount: @escaping Mount,
    schedule: Schedule? = nil,
    retryWhenDue: (() -> Void)? = nil,
    onGiveUp: ((NetworkShare, String?) -> Void)? = nil
  ) {
    self.shares = shares
    self.isMounted = isMounted
    self.isSuppressed = isSuppressed
    self.mount = mount
    self.schedule = schedule
    self.retryWhenDue = retryWhenDue
    self.onGiveUp = onGiveUp
  }

  /// Whether a retry timer is waiting to fire.
  var isTimerScheduled: Bool { cancelTimer != nil }

  /// Whether some login share may still be retried.
  var hasPendingShares: Bool {
    pendingIDs.contains { retries[$0, default: 0] < LoginMountRules.maxRetries }
  }

  /// Mounts every "Mount at login" share (app launch).
  func mountAtLaunch() {
    for share in shares() where share.mountAtLogin {
      pendingIDs.insert(share.id)
      start(share, retry: nil)
    }
  }

  /// The network is available (or the retry timer fired): mounts the login
  /// shares that failed again. Returns the shares it started mounting.
  @discardableResult
  func retry(isNetworkAvailable: Bool = true) -> [NetworkShare] {
    let due = LoginMountRules.sharesToRetry(
      shares: shares(), isNetworkAvailable: isNetworkAvailable, pendingIDs: pendingIDs,
      mountingIDs: mountingIDs, retries: retries, isMounted: isMounted,
      isSuppressed: isSuppressed)
    for share in due {
      let attempt = retries[share.id, default: 0] + 1
      retries[share.id] = attempt
      start(share, retry: attempt)
    }
    return due
  }

  private func start(_ share: NetworkShare, retry attempt: Int?) {
    mountingIDs.insert(share.id)
    mount(share) { [weak self] success, error in
      guard let self else { return }
      self.mountingIDs.remove(share.id)
      let label = attempt.map { " (retry \($0) of \(LoginMountRules.maxRetries))" } ?? ""
      if success {
        self.pendingIDs.remove(share.id)
        self.retries.removeValue(forKey: share.id)
        Log.network.notice(
          "Auto-mounted \(share.name, privacy: .private)\(label, privacy: .public)")
      } else if let delay = LoginMountRules.retryDelay(beforeRetry: (attempt ?? 0) + 1) {
        Log.network.error(
          "Failed to auto-mount \(share.name, privacy: .private)\(label, privacy: .public): \(error ?? "Unknown error", privacy: .private). Retrying in \(Int(delay), privacy: .public) s or when the network comes up."
        )
      } else {
        Log.network.error(
          "Failed to auto-mount \(share.name, privacy: .private)\(label, privacy: .public): \(error ?? "Unknown error", privacy: .private). Giving up until the next launch."
        )
        if !self.isMounted(share), !self.isSuppressed(share.id),
          self.gaveUpIDs.insert(share.id).inserted
        {
          self.onGiveUp?(share, error)
        }
      }
      self.updateTimer()
    }
  }

  /// Keeps one timer for the earliest share still waiting; cancels it once
  /// no share waits (mounted, unmounted by the user, given up, or being
  /// mounted: that mount's completion schedules the next one). Called only
  /// when a mount finishes, so the number of timers is bounded by the
  /// retries.
  private func updateTimer() {
    guard let schedule else { return }
    let waiting = shares().filter {
      $0.mountAtLogin && pendingIDs.contains($0.id) && !isMounted($0) && !isSuppressed($0.id)
    }
    guard
      let delay = LoginMountRules.nextTimerDelay(
        pendingIDs: Set(waiting.map(\.id)), mountingIDs: mountingIDs, retries: retries)
    else {
      cancelTimer?()
      cancelTimer = nil
      return
    }
    guard cancelTimer == nil else { return }
    cancelTimer = schedule(delay) { [weak self] in
      guard let self else { return }
      self.cancelTimer = nil
      if let retryWhenDue = self.retryWhenDue {
        retryWhenDue()
      } else {
        self.retry()
      }
    }
  }
}
