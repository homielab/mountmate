//  Created by homielab.com

import Foundation

struct LockedVolumeAppAlert {
    let action: (String) -> Void
}

enum AppAlertKind {
    case basic,
         lockedVolume(LockedVolumeAppAlert)
}

struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let kind: AppAlertKind
}
