//  Created by homielab.com

import Combine
import Foundation
import Sparkle
import SwiftUI

final class UpdaterController: NSObject, ObservableObject {
  private var updaterController: SPUStandardUpdaterController!

  /// Mirrors `SPUUpdater.canCheckForUpdates` (false while a check or an
  /// update session is already running), so the menu item can be disabled.
  @Published private(set) var canCheckForUpdates = false

  /// Mirrors `SPUUpdater.automaticallyChecksForUpdates` (stored by Sparkle
  /// in the app's user defaults) so a toggle can bind to it.
  @Published var automaticallyChecksForUpdates = false {
    didSet {
      if updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates {
        updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
      }
    }
  }

  /// Update found by a scheduled check that waits for the user (badge on the
  /// menu bar icon, line in the popover). See `UpdateReminder`.
  @Published private(set) var reminder = UpdateReminder()

  override init() {
    super.init()
    // Gentle scheduled update reminders: scheduled checks don't open
    // Sparkle's window on top of other apps; the delegate methods below turn
    // a found update into a reminder instead.
    self.updaterController = SPUStandardUpdaterController(
      startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    updaterController.updater.publisher(for: \.canCheckForUpdates)
      .receive(on: DispatchQueue.main)
      .assign(to: &$canCheckForUpdates)
    automaticallyChecksForUpdates = updaterController.updater.automaticallyChecksForUpdates
  }

  var updater: SPUUpdater {
    updaterController.updater
  }

  /// Starts a user-initiated check, or brings an update that is already
  /// waiting (see `reminder`) into focus.
  @objc func checkForUpdates() {
    updater.checkForUpdates()
  }
}

extension UpdaterController: SPUStandardUserDriverDelegate {
  var supportsGentleScheduledUpdateReminders: Bool { true }

  func standardUserDriverShouldHandleShowingScheduledUpdate(
    _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
  ) -> Bool {
    UpdateReminder.standardDriverShowsScheduledUpdate(immediateFocus: immediateFocus)
  }

  func standardUserDriverWillHandleShowingUpdate(
    _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
  ) {
    reminder.willShowUpdate(
      handledByStandardDriver: handleShowingUpdate, userInitiated: state.userInitiated,
      version: update.displayVersionString)
    if reminder.hasPendingUpdate {
      Log.app.info(
        "Update \(update.displayVersionString, privacy: .public) available, showing a reminder")
    }
  }

  func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
    reminder.userGaveAttention()
  }

  func standardUserDriverWillFinishUpdateSession() {
    reminder.updateSessionFinished()
  }
}
