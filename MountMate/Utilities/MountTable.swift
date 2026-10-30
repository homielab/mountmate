//  Created by homielab.com

import Foundation

/// One row of the kernel mount table: what is mounted, where, and as which
/// filesystem type ("apfs", "smbfs", "nfs"…).
struct MountEntry: Equatable, Sendable {
  let source: String
  let mountPoint: String
  let fileSystemType: String
  /// Mounted read-only (`MNT_RDONLY`).
  var isReadOnly: Bool = false
}

/// Reads the kernel mount table with `getfsstat(MNT_NOWAIT)`: the same data
/// `/sbin/mount` prints, already split into fields and without starting a
/// process. `MNT_NOWAIT` returns the cached statistics, so it never waits on
/// a mounted file system (an unresponsive server cannot block it).
enum MountTable {
  /// Every mounted file system, or nil if the table could not be read.
  static func entries() -> [MountEntry]? {
    var capacity = Int(getfsstat(nil, 0, MNT_NOWAIT))
    guard capacity >= 0 else { return nil }
    while true {
      // Leave room for mounts that appear between the two calls; a full
      // buffer may have been truncated, so read again with more room.
      capacity += 8
      var buffer = Array(repeating: statfs(), count: capacity)
      let count = buffer.withUnsafeMutableBufferPointer { pointer in
        getfsstat(
          pointer.baseAddress, Int32(MemoryLayout<statfs>.stride * capacity), MNT_NOWAIT)
      }
      guard count >= 0 else { return nil }
      if Int(count) < capacity {
        return buffer.prefix(Int(count)).map(entry(from:))
      }
      capacity = Int(count)
    }
  }

  /// The network shares (SMB, NFS, AFP) in the mount table, or nil if it
  /// could not be read.
  static func networkShares() -> [MountedNetworkShare]? {
    entries().map(networkShares(in:))
  }

  /// The entries that are network shares, in table order.
  static func networkShares(in entries: [MountEntry]) -> [MountedNetworkShare] {
    entries.compactMap(MountedNetworkShare.init(entry:))
  }

  /// The fields of one `statfs` record.
  static func entry(from stat: statfs) -> MountEntry {
    MountEntry(
      source: string(fromCharacters: stat.f_mntfromname),
      mountPoint: string(fromCharacters: stat.f_mntonname),
      fileSystemType: string(fromCharacters: stat.f_fstypename),
      isReadOnly: isReadOnly(flags: stat.f_flags))
  }

  /// Whether the `statfs` mount flags contain `MNT_RDONLY`.
  static func isReadOnly(flags: UInt32) -> Bool {
    flags & UInt32(MNT_RDONLY) != 0
  }

  /// Mount points of the read-only file systems, or empty if the table could
  /// not be read.
  static func readOnlyMountPoints(in entries: [MountEntry]) -> Set<String> {
    Set(entries.filter(\.isReadOnly).map(\.mountPoint))
  }

  /// File system type by mount point ("apfs", "ufsd_NTFS"…). A mount point
  /// listed twice keeps its last (topmost) entry.
  static func fileSystemTypes(in entries: [MountEntry]) -> [String: String] {
    Dictionary(
      entries.map { ($0.mountPoint, $0.fileSystemType) }, uniquingKeysWith: { _, last in last })
  }

  /// A NUL-terminated UTF-8 string stored in a fixed-size C array (imported
  /// as a tuple). Never reads past the array, even without a terminator.
  static func string<Characters>(fromCharacters characters: Characters) -> String {
    withUnsafeBytes(of: characters) { bytes in
      let length = bytes.firstIndex(of: 0) ?? bytes.count
      return String(decoding: bytes.prefix(length), as: UTF8.self)
    }
  }
}
