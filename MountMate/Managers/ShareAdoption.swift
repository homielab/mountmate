//  Created by homielab.com

import Foundation

/// Mounts accepted as a saved share's although their host is spelled
/// differently (e.g. Finder's "NAS._smb._tcp.local" or an IP address),
/// keyed by share ID. Recorded when NetFS reports the share as already
/// mounted; dropped when the mount disappears, the share's endpoint
/// changes, or the share is removed (see `attributeMounts`).
///
/// Status refreshes run on background threads, so the adoptions, the saved
/// shares of the last refresh and the manual-share cache are guarded by one
/// lock.
final class ShareAdoption: @unchecked Sendable {
  /// A mount accepted as a saved share's although its host is spelled
  /// differently. Remembers the share's endpoint at adoption time so the
  /// adoption is void once the share's server, path or protocol is edited.
  struct Adoption: Equatable {
    let mountPoint: String
    let shareProtocol: ShareProtocol
    let endpoint: MountedNetworkShare.Endpoint
  }

  private let lock = NSLock()
  private var adoptions: [UUID: Adoption] = [:]
  /// Saved shares as of the last refresh (for attribution off main).
  private var savedSharesSnapshot: [NetworkShare] = []
  private var manualShareCache: [String: NetworkShare] = [:]

  /// Remembers that `share` is mounted at `mountPoint` under another name.
  func adopt(_ mountPoint: String, for share: NetworkShare) {
    let adoption = Adoption(
      mountPoint: mountPoint, shareProtocol: share.shareProtocol,
      endpoint: MountedNetworkShare.endpoint(for: share))
    lock.withLock { adoptions[share.id] = adoption }
  }

  /// Forgets any adopted mount for a share (call when it is edited or removed).
  func forget(shareID: UUID) {
    lock.withLock { _ = adoptions.removeValue(forKey: shareID) }
  }

  func adoption(forShareID shareID: UUID) -> Adoption? {
    lock.withLock { adoptions[shareID] }
  }

  /// Reads the mount table against `savedShares`: attributes each mount,
  /// drops stale adoptions and remembers `savedShares` for `mounts(of:in:)`.
  func parse(_ mountedShares: [MountedNetworkShare], savedShares: [NetworkShare])
    -> NetworkMountTable.Parsed
  {
    lock.withLock {
      let attribution = Self.attributeMounts(mountedShares, to: savedShares, adoptions: adoptions)
      adoptions = attribution.adoptions
      savedSharesSnapshot = savedShares
      return NetworkMountTable.parse(
        mountedShares, savedShares: savedShares, owners: attribution.owners,
        manualShareCache: &manualShareCache)
    }
  }

  /// The mounts in `mountTable` that are `share`, attributed against the
  /// share list of the last refresh (with `share` itself up to date).
  func mounts(of share: NetworkShare, in mountTable: [MountedNetworkShare])
    -> [MountedNetworkShare]
  {
    let (snapshot, current) = lock.withLock { (savedSharesSnapshot, adoptions) }
    return NetworkMountTable.mounts(
      of: share, in: mountTable, savedShares: snapshot, adoptions: current)
  }

  /// Decides which saved share each mount is, in two passes:
  /// 1. exact host + path matches (`matches`) over all shares;
  /// 2. only for mounts no share matched exactly: still-valid adoptions.
  /// A share with an exact match never also claims a mount by adoption.
  /// An adoption is valid while its share exists with the same protocol and
  /// endpoint and an unclaimed mount with that share path is at its mount
  /// point; invalid adoptions are left out of the returned set.
  ///
  /// - Returns: the owning share ID per mount (aligned with `mounts`), and
  ///   the adoptions to keep.
  static func attributeMounts(
    _ mounts: [MountedNetworkShare], to shares: [NetworkShare], adoptions: [UUID: Adoption]
  ) -> (owners: [UUID?], adoptions: [UUID: Adoption]) {
    var owners = [UUID?](repeating: nil, count: mounts.count)
    var exactlyMatched = Set<UUID>()
    for (index, mount) in mounts.enumerated() {
      if let share = shares.first(where: { mount.matches($0) }) {
        owners[index] = share.id
        exactlyMatched.insert(share.id)
      }
    }

    var keptAdoptions: [UUID: Adoption] = [:]
    for (shareID, adoption) in adoptions {
      guard !exactlyMatched.contains(shareID),
        let share = shares.first(where: { $0.id == shareID }),
        share.shareProtocol == adoption.shareProtocol,
        MountedNetworkShare.endpoint(for: share) == adoption.endpoint,
        let index = mounts.indices.first(where: {
          owners[$0] == nil
            && NetworkMountTable.samePath(mounts[$0].mountPoint, adoption.mountPoint)
            && NetworkMountTable.hasSameSharePath(mounts[$0], share)
        })
      else { continue }
      owners[index] = shareID
      keptAdoptions[shareID] = adoption
    }
    return (owners, keptAdoptions)
  }
}
