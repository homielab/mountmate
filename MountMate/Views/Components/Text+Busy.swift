import SwiftUI

extension Text {
  /// VoiceOver value for a button whose action is running; empty when idle.
  static func busyValue(_ isBusy: Bool) -> Text {
    isBusy
      ? Text(NSLocalizedString("Accessibility Busy", comment: "Accessibility value while busy"))
      : Text("")
  }
}
