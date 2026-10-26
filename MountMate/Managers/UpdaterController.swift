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

  override init() {
    super.init()
    // No user driver delegate: MountMate does not implement gentle
    // scheduled update reminders, so it must not claim to support them
    // (`supportsGentleScheduledUpdateReminders`). Sparkle's default handling
    // for background apps applies.
    self.updaterController = SPUStandardUpdaterController(
      startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    updaterController.updater.publisher(for: \.canCheckForUpdates)
      .receive(on: DispatchQueue.main)
      .assign(to: &$canCheckForUpdates)
    automaticallyChecksForUpdates = updaterController.updater.automaticallyChecksForUpdates
  }

  var updater: SPUUpdater {
    updaterController.updater
  }

  @objc func checkForUpdates() {
    updater.checkForUpdates()
  }
}
