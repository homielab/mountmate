//  Created by homielab.com

import Foundation

/// Whether a failed share mount may be retried automatically.
///
/// After the password of a NAS or domain account changes, every automatic
/// retry with the old saved password counts as a failed sign-in on the
/// server, and servers lock the account after a few of them (on every device
/// that uses it). So once the server rejects the credentials, Keep Alive and
/// the login retries leave the share alone until the user edits it or mounts
/// it by hand.
enum ShareRetryRules {
  /// Whether `status` (NetFS / errno) means the server rejected the
  /// account or its password, so retrying with the same credentials cannot
  /// succeed and may lock the account:
  /// - `EAUTH`: wrong username or password.
  /// - `ENETFSPWDNEEDSCHANGE` (-5045): the password expired or must change.
  /// - `ENETFSPWDPOLICY` (-5046): the password breaks the server's policy.
  /// - `ENETFSACCOUNTRESTRICTED` (-5999): the account is locked, disabled or
  ///   not allowed to sign in now.
  ///
  /// Not counted: `userCanceledErr` (-128, NetFS wanted to ask for a login
  /// the share does not have), `EACCES`/`EPERM` (also used for share
  /// permissions and local mount-point permissions), missing shares, and
  /// network or protocol errors: those keep the normal backoff.
  static func isCredentialFailure(_ status: Int32) -> Bool {
    switch status {
    case EAUTH, -5045, -5046, -5999: return true
    default: return false
    }
  }

  /// `isCredentialFailure` for a mount result: only a failure that carries a
  /// NetFS status can be one (NFS uses no password).
  static func isCredentialFailure(_ outcome: MountOutcome) -> Bool {
    guard case .failed(_, let status?) = outcome else { return false }
    return isCredentialFailure(status)
  }
}
