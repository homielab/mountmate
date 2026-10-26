//  Created by homielab.com

import Foundation

/// Bookkeeping behind the Disk Arbitration mount approval callback: which
/// mounts MountMate itself asked for, and when each disk appeared.
///
/// Not thread-safe: the owner serializes access with its own lock. The clock
/// is injectable so the time rules can be tested.
struct MountApprovalLedger {
  /// How long a manual-mount approval stays valid at most.
  static let approvalLifetime: TimeInterval = 60
  /// How long after a disk appears a mount is treated as macOS's automatic
  /// mount rather than a request from an app.
  static let autoMountWindow: TimeInterval = 15

  private let now: () -> Date
  private var approvals: [String: Date] = [:]
  private var appearances: [String: Date] = [:]

  init(now: @escaping () -> Date = Date.init) {
    self.now = now
  }

  // MARK: Manual mount approvals

  /// Approves one mount of `identifier` (BSD name, volume UUID or disk UUID).
  /// Returns the expiration, which `withdrawApproval(for:ifExpiring:)` needs.
  @discardableResult
  mutating func approve(_ identifier: String) -> Date {
    let expiration = now().addingTimeInterval(Self.approvalLifetime)
    approvals[identifier.lowercased()] = expiration
    return expiration
  }

  /// Withdraws the approval of `identifier` (the manual mount finished).
  mutating func withdrawApproval(for identifier: String) {
    approvals.removeValue(forKey: identifier.lowercased())
  }

  /// Withdraws the approval only if it is still the one that expires at
  /// `expiration` (a newer approval for the same identifier stays).
  mutating func withdrawApproval(for identifier: String, ifExpiring expiration: Date) {
    let key = identifier.lowercased()
    if approvals[key] == expiration {
      approvals.removeValue(forKey: key)
    }
  }

  /// Uses up an unexpired approval matching any identifier. One approval
  /// allows one mount.
  mutating func consumeApproval(bsdName: String?, volumeUUID: String?, diskUUID: String?) -> Bool {
    let identifiers = [bsdName, volumeUUID, diskUUID].compactMap { $0?.lowercased() }
    guard !identifiers.isEmpty else { return false }

    let current = now()
    approvals = approvals.filter { $0.value > current }
    for identifier in identifiers where approvals.removeValue(forKey: identifier) != nil {
      return true
    }
    return false
  }

  // MARK: Disk appearances

  mutating func recordAppearance(of bsdName: String?) {
    guard let key = bsdName?.lowercased() else { return }
    appearances[key] = now()
  }

  mutating func forgetAppearance(of bsdName: String?) {
    guard let key = bsdName?.lowercased() else { return }
    appearances.removeValue(forKey: key)
  }

  /// True when this mount looks like macOS auto-mounting a disk that just
  /// appeared. A disk with no recorded appearance is treated as new (and
  /// recorded now), so callback ordering can never let an auto-mount through.
  mutating func isAutomaticMount(bsdName: String?) -> Bool {
    guard let key = bsdName?.lowercased() else { return true }
    let current = now()
    guard let appeared = appearances[key] else {
      appearances[key] = current
      return true
    }
    return current.timeIntervalSince(appeared) < Self.autoMountWindow
  }

  mutating func removeAll() {
    approvals.removeAll()
    appearances.removeAll()
  }
}
