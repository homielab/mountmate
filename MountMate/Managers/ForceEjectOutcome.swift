//  Created by homielab.com

import Foundation

/// Decides what a Force Eject reports. Force eject first force-unmounts the
/// disk and then ejects it; when the unmount failed, the eject must not run
/// and the user must see the unmount error, not a follow-up eject error.
enum ForceEjectOutcome: Equatable {
  case succeeded
  /// The force unmount failed: the eject is skipped, report this result.
  case unmountFailed(ProcessResult)
  /// The unmount worked but the eject failed: report this result.
  case ejectFailed(ProcessResult)

  /// Whether the eject step should run after the force unmount.
  static func shouldEject(afterUnmount unmountResult: ProcessResult) -> Bool {
    unmountResult.succeeded
  }

  /// `ejectResult` is `nil` when no eject ran (a RAID set is only unmounted).
  static func choose(unmountResult: ProcessResult, ejectResult: ProcessResult?) -> Self {
    guard unmountResult.succeeded else { return .unmountFailed(unmountResult) }
    if let ejectResult, !ejectResult.succeeded { return .ejectFailed(ejectResult) }
    return .succeeded
  }
}
