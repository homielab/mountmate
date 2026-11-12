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

/// A Time Machine backup is writing to a volume the user is about to
/// unmount or eject.
struct TimeMachineBackupAppAlert {
  /// "Unmount Anyway" or "Eject Anyway".
  let proceedTitle: String
  let onProceed: () -> Void
  /// Runs the action without the backing-up volumes (nothing for one volume).
  let onSkip: () -> Void
}

enum AppAlertKind {
  case basic
  case renameVolume(RenameVolumeAppAlert)
  case lockedVolume(LockedVolumeAppAlert)
  case forceEject(() -> Void)
  case forceUnmount(() -> Void)
  case timeMachineBackup(TimeMachineBackupAppAlert)
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
  /// The process keeping a disk busy; the alert shows its icon.
  var blocker: BlockingProcess? = nil
}
