//  Created by homielab.com

import Foundation

struct LockedVolumeAppAlert {
    let onConfirm: (String) -> Void
}

enum AppAlertKind {
    case basic
    case lockedVolume(LockedVolumeAppAlert)
}

struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let kind: AppAlertKind
}
