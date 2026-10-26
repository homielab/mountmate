//  Created by homielab.com

import Foundation

struct LockedVolumeAppAlert {
  /// The saved password was rejected: offer to forget it.
  let offersForgetSavedPassword: Bool
  /// Password, remember in Keychain, forget the saved password.
  let onConfirm: (String, Bool, Bool) -> Void
}

enum AppAlertKind {
  case basic
  case lockedVolume(LockedVolumeAppAlert)
  case forceEject(() -> Void)
  case forceUnmount(() -> Void)
}

struct AppAlert: Identifiable {
  let id = UUID()
  let title: String
  let message: String
  let kind: AppAlertKind
}
