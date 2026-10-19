//  Created by homielab.com

import Foundation

extension Notification.Name {
  static let willManuallyMount = Notification.Name("com.homielab.mountmate.willManuallyMount")
  /// Posted when a mount announced with `willManuallyMount` has finished
  /// (succeeded or failed), so any unused approval is withdrawn right away.
  static let didFinishManualMount = Notification.Name(
    "com.homielab.mountmate.didFinishManualMount")
}
