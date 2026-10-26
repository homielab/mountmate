//  Created by homielab.com

import Foundation

extension Notification.Name {
  static let willManuallyMount = Notification.Name("com.homielab.mountmate.willManuallyMount")
  /// Posted when a mount announced with `willManuallyMount` has finished
  /// (succeeded or failed), so any unused approval is withdrawn right away.
  static let didFinishManualMount = Notification.Name(
    "com.homielab.mountmate.didFinishManualMount")
  /// Posted on the main queue when Disk Arbitration reports a volume-capable
  /// disk appearing or disappearing, including ones that never mount (blocked
  /// or unformatted), so the list refreshes without a mount event.
  static let diskAppearanceDidChange = Notification.Name(
    "com.homielab.mountmate.diskAppearanceDidChange")
}
