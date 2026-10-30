//  Created by homielab.com

import Foundation

/// The mount folders MountMate has saved: volume custom mount points (their
/// /etc/fstab rules) and network share mount points. Two of them on the same
/// folder make the later mount fail with an unclear "not empty" error, so a
/// folder already claimed is refused at Save.
enum MountPointClaims {
  struct Claim: Equatable, Sendable {
    enum Owner: Equatable, Sendable {
      case volume
      case share
    }

    let owner: Owner
    /// The saved entry's id: `VolumeCustomMountPoint.id` or the share's UUID.
    let key: String
    let name: String
    let path: String
  }

  static func volumeClaims(_ entries: [VolumeCustomMountPoint]) -> [Claim] {
    entries.map { Claim(owner: .volume, key: $0.id, name: $0.name, path: $0.mountPoint) }
  }

  static func shareClaims(_ shares: [NetworkShare], mountPoint: (NetworkShare) -> String)
    -> [Claim]
  {
    shares.map {
      Claim(owner: .share, key: $0.id.uuidString, name: $0.name, path: mountPoint($0))
    }
  }

  /// Same folder once `~`, `..`, a trailing `/` and case are ignored (APFS
  /// and HFS+ are case-insensitive by default).
  static func samePath(_ lhs: String, _ rhs: String) -> Bool {
    NetworkMountTable.samePath(
      CustomMountPointValidator.normalizedPath(lhs),
      CustomMountPointValidator.normalizedPath(rhs))
  }

  /// The first claim on `path` other than the entry `excludingKey`, or nil.
  static func claim(on path: String, in claims: [Claim], excludingKey: String?) -> Claim? {
    claims.first { $0.key != excludingKey && samePath($0.path, path) }
  }

  /// A localized "already used by …" message naming the claim's owner.
  static func message(for claim: Claim) -> String {
    switch claim.owner {
    case .volume:
      return String(
        format: NSLocalizedString(
          "Mount Point Used By Volume", comment: "Mount point validation: saved volume rule"),
        claim.name)
    case .share:
      return String(
        format: NSLocalizedString(
          "Mount Point Used By Share", comment: "Mount point validation: saved network share"),
        claim.name)
    }
  }

  static func error(for path: String, in claims: [Claim], excludingKey: String?) -> String? {
    claim(on: path, in: claims, excludingKey: excludingKey).map(message(for:))
  }
}
