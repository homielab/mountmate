//  Created by homielab.com

import Foundation
import Sparkle
import SwiftUI

final class UpdaterController: NSObject, ObservableObject {
  private let updater: SPUUpdater

  init(updater: SPUUpdater) {
    self.updater = updater
    super.init()
  }

  @objc func checkForUpdates() {
    updater.checkForUpdates()
  }
}
