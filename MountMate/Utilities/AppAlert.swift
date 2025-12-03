//  Created by homielab.com

import Foundation

struct LockedVolumeAppAlert {
  let onConfirm: (String, Bool) -> Void
}

enum AppAlertKind {
  case basic
  case lockedVolume(LockedVolumeAppAlert)
  case forceEject(() -> Void)
}

struct AppAlert: Identifiable {
  let id = UUID()
  let title: String
  let message: String
  let kind: AppAlertKind
}
