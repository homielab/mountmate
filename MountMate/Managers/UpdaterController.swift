//  Created by homielab.com

import Foundation
import Sparkle
import SwiftUI

final class UpdaterController: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
  private var updaterController: SPUStandardUpdaterController!

  override init() {
    super.init()
    self.updaterController = SPUStandardUpdaterController(
      startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
  }

  var supportsGentleScheduledUpdateReminders: Bool {
    true
  }

  var updater: SPUUpdater {
    updaterController.updater
  }

  @objc func checkForUpdates() {
    updater.checkForUpdates()
  }
}
