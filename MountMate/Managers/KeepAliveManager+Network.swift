//  Created by homielab.com

import Foundation

extension KeepAliveManager {
  // MARK: - Network Changes

  /// Main thread only.
  func handleNetworkChange(_ path: NetworkPathSnapshot) {
    guard isEnabled else {
      // Keep Alive off: nothing reconnects, but a "Mount at login" share
      // that failed because the Mac started before Wi-Fi still deserves its
      // mount once the network is up.
      if path.isSatisfied { retryLoginMounts() }
      return
    }

    switch NetworkChangeRules.decision(previous: currentInterface, path: path) {
    case .unavailable:
      currentInterface = nil
      Log.keepAlive.notice("Network unavailable. Waiting for recovery before reconnecting mounts.")
    case .available(let interface, let remountShares, let networkChanged):
      currentInterface = interface
      if remountShares && remountOnNetworkChange {
        Log.keepAlive.notice(
          "Network interface changed (→ \(interface?.name ?? "?", privacy: .public)). Remounting shares."
        )
        remountSharesForInterfaceChange()
      } else {
        Log.keepAlive.notice("Network became available. Running keep-alive reconnect sweep.")
        // Back online (or on another network): earlier failures say nothing
        // about reachability now, so retry everything right away.
        sweepNow(resetBackoff: networkChanged)
      }
    }
  }

  /// Main thread only.
  func retryLoginMounts() {
    if let loginMountRetryAction {
      loginMountRetryAction()
    } else {
      NetworkMountManager.shared.retryLoginMounts()
    }
  }

  /// Re-establishes active share mounts through the new primary interface.
  /// Main thread only.
  private func remountSharesForInterfaceChange() {
    if let interfaceChangeAction {
      interfaceChangeAction()
      return
    }
    let shares = keepAliveShares
    guard !shares.isEmpty else { return }
    // One mount-table refresh for all shares (not one per share).
    NetworkMountManager.shared.refreshMountStatus(readUsage: false) { [weak self] in
      guard let self else { return }
      var needsSweep = false
      for share in shares {
        guard !self.isSuppressed(shareID: share.id) else { continue }
        guard NetworkMountManager.shared.isMounted(share: share) else {
          // Not mounted right now — the regular sweep will reconnect it.
          needsSweep = true
          continue
        }
        self.markReconnecting(shareID: share.id)
        NetworkMountManager.shared.forceRemount(share: share) { [weak self] success in
          self?.recordResult(shareID: share.id, name: share.name, success: success)
          if success {
            Log.keepAlive.notice(
              "Remounted \(share.name, privacy: .private) through the new network interface.")
          } else {
            Log.keepAlive.error(
              "Could not remount \(share.name, privacy: .private) through the new network interface."
            )
          }
        }
      }
      if needsSweep {
        self.sweepNow(resetBackoff: true)
      }
    }
  }
}
