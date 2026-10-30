//  Created by homielab.com

import Foundation

/// Why a network share cannot be saved as entered.
enum NetworkShareValidation {
  /// The first problem with `candidate`, or nil when it can be saved.
  /// - Parameters:
  ///   - original: the share before editing, nil for a new one.
  ///   - otherShares: every saved share except the one being edited.
  ///   - mountPoint: the folder a share is (or will be) mounted at.
  ///   - volumeClaims: the saved volume custom mount points.
  static func error(
    candidate: NetworkShare, original: NetworkShare?, otherShares: [NetworkShare],
    mountPoint: (NetworkShare) -> String, volumeClaims: [MountPointClaims.Claim] = []
  ) -> String? {
    // Existing names stay valid when editing other fields.
    if candidate.name != original?.name,
      let nameError = NetworkShare.displayNameValidationError(candidate.name)
    {
      return nameError
    }

    // A share saved twice before this check existed may keep its endpoint;
    // changing it (or adding a share) must not collide with another one.
    let endpointChanged = original.map { !candidate.hasSameEndpoint(as: $0) } ?? true
    if endpointChanged,
      let duplicate = otherShares.first(where: { $0.hasSameEndpoint(as: candidate) })
    {
      return String(
        format: NSLocalizedString(
          "This share is already saved as “%@”.", comment: "Network share validation error"),
        duplicate.name)
    }

    // Two shares must never use the same mount folder: mounting one would
    // look like the other is mounted, and unmounting one would unmount both.
    // Checked on the resolved folder (`~`, `..` and `//` applied), so the
    // problem shows at Save instead of as a NetFS error when mounting.
    let path = mountPoint(candidate)
    if let pathError = CustomMountPointValidator.pathRuleError(
      CustomMountPointValidator.normalizedPath(path))
    {
      return pathError
    }
    if let clash = otherShares.first(where: {
      NetworkMountTable.samePath(mountPoint($0), path)
    }) {
      return String(
        format: NSLocalizedString(
          "The mount point “%@” is already used by the share “%@”. Choose a different display name or custom mount point.",
          comment: "Network share validation error"),
        path, clash.name)
    }
    // A volume's /etc/fstab rule on the same folder fails the same way.
    return MountPointClaims.error(for: path, in: volumeClaims, excludingKey: nil)
  }
}
