//  Created by homielab.com

import Foundation

/// Decides how a newly found update is announced.
///
/// MountMate lives in the menu bar, so an update window that opens on its own
/// lands on top of whatever the user is doing. Scheduled checks therefore only
/// set a reminder (a badge on the menu bar icon and a line in the popover);
/// Sparkle's window opens when the user asks for it. Checks the user started
/// show the window right away, as before.
struct UpdateReminder: Equatable, Sendable {
  /// Display version of the update waiting for the user, or nil.
  private(set) var pendingVersion: String?

  var hasPendingUpdate: Bool { pendingVersion != nil }

  /// Answer for `standardUserDriverShouldHandleShowingScheduledUpdate`:
  /// Sparkle never shows a scheduled update by itself, even when it would
  /// get immediate focus (right after launch or after the Mac was idle).
  static func standardDriverShowsScheduledUpdate(immediateFocus: Bool) -> Bool {
    false
  }

  /// Called before an update is shown (`standardUserDriverWillHandleShowingUpdate`).
  /// A reminder is kept only when MountMate, not Sparkle, has to show it.
  mutating func willShowUpdate(
    handledByStandardDriver: Bool, userInitiated: Bool, version: String
  ) {
    if handledByStandardDriver || userInitiated {
      pendingVersion = nil
    } else {
      pendingVersion = version
    }
  }

  /// The user looked at the update window or chose install/skip/later.
  mutating func userGaveAttention() {
    pendingVersion = nil
  }

  /// Sparkle's update session ended (dismissed, skipped, failed, installed).
  mutating func updateSessionFinished() {
    pendingVersion = nil
  }
}
