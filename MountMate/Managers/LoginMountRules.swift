//  Created by homielab.com

import Foundation

/// Which "Mount at login" shares to try again once the network is up.
///
/// At login the Mac often starts MountMate before Wi-Fi is connected, so the
/// login mount fails. With Keep Alive on, its reconnect sweep picks those
/// shares up; with Keep Alive off nothing else would, so the login mount is
/// retried each time the network becomes available, a few times at most.
enum LoginMountRules {
  /// Retries per share after the mount at launch, for the whole session.
  static let maxRetries = 5

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
/// failed when the network comes up (`LoginMountRules`). Main thread only.
final class LoginMountRetrier {
  /// Mounts a share automatically; calls back on the main thread with
  /// whether it mounted and the (sanitized) error.
  typealias Mount = (NetworkShare, @escaping (Bool, String?) -> Void) -> Void

  private let shares: () -> [NetworkShare]
  private let isMounted: (NetworkShare) -> Bool
  private let isSuppressed: (UUID) -> Bool
  private let mount: Mount

  /// Login shares that have not mounted since launch.
  private(set) var pendingIDs = Set<UUID>()
  /// Login shares with a mount in flight.
  private(set) var mountingIDs = Set<UUID>()
  /// Retries made per share (the mount at launch is not counted).
  private(set) var retries: [UUID: Int] = [:]

  init(
    shares: @escaping () -> [NetworkShare],
    isMounted: @escaping (NetworkShare) -> Bool,
    isSuppressed: @escaping (UUID) -> Bool,
    mount: @escaping Mount
  ) {
    self.shares = shares
    self.isMounted = isMounted
    self.isSuppressed = isSuppressed
    self.mount = mount
  }

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

  /// The network is available: mounts the login shares that failed again.
  /// Returns the shares it started mounting.
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
      } else if (attempt ?? 0) >= LoginMountRules.maxRetries {
        Log.network.error(
          "Failed to auto-mount \(share.name, privacy: .private)\(label, privacy: .public): \(error ?? "Unknown error", privacy: .private). Giving up until the next launch."
        )
      } else {
        Log.network.error(
          "Failed to auto-mount \(share.name, privacy: .private)\(label, privacy: .public): \(error ?? "Unknown error", privacy: .private). Retrying when the network is available."
        )
      }
    }
  }
}
