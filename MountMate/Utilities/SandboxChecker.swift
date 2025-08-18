//  Created by homielab.com

import Foundation

struct SandboxChecker {
    static var isSandboxed: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }
}
