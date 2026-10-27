//  Created by homielab.com

import Foundation

struct LockedVolumeAppAlert {
  /// The saved password was rejected: offer to forget it.
  let offersForgetSavedPassword: Bool
  /// Password, remember in Keychain, forget the saved password.
  let onConfirm: (String, Bool, Bool) -> Void
}

struct RenameVolumeAppAlert {
  let currentName: String
  /// Why a name cannot be used (shown under the field), nil when it can.
  let validate: (String) -> String?
  let onConfirm: (String) -> Void
}

enum AppAlertKind {
  case basic
  case renameVolume(RenameVolumeAppAlert)
  case lockedVolume(LockedVolumeAppAlert)
  case forceEject(() -> Void)
  case forceUnmount(() -> Void)
}

struct AppAlert: Identifiable {
  enum Style: Sendable {
    case warning
    case informational
  }

  let id = UUID()
  let title: String
  let message: String
  let kind: AppAlertKind
  var style: Style = .warning
}
