//  Created by homielab.com

import Foundation

/// The file format of Settings → Network Shares → Export Shares…, used to
/// move saved shares to another Mac. It holds what the share sheet holds
/// except passwords (they stay in the Keychain of the Mac they were typed
/// on) and share IDs (imported shares get new ones).
///
/// ```json
/// {
///   "format" : "mountmate.networkShares",
///   "shares" : [ { "name" : "Media", "protocol" : "smb", "server" : "nas.local", … } ],
///   "version" : 1
/// }
/// ```
enum NetworkShareBackup {
  static let format = "mountmate.networkShares"
  static let currentVersion = 1
  static let defaultFileName = "MountMate Network Shares.json"

  enum ReadError: Error, Equatable {
    /// Not JSON, or not a MountMate share export.
    case notABackup
    /// Written by a newer MountMate with a format this version cannot read.
    case newerVersion(Int)

    var message: String {
      switch self {
      case .notABackup:
        return NSLocalizedString(
          "This file is not a MountMate network share export.",
          comment: "Network share import error")
      case .newerVersion:
        return NSLocalizedString(
          "This file was exported by a newer version of MountMate. Update MountMate to import it.",
          comment: "Network share import error")
      }
    }
  }

  /// One share in the file. Every field but the protocol, server and path
  /// may be missing (a hand-written file), with the share sheet's defaults.
  struct Entry: Codable, Equatable {
    var name: String
    var shareProtocol: ShareProtocol
    var server: String
    var sharePath: String
    var username: String
    var mountAtLogin: Bool
    var keepMounted: Bool
    var customMountPoint: String?
    var readOnly: Bool

    private enum CodingKeys: String, CodingKey {
      case name, server, sharePath, username, mountAtLogin, keepMounted, customMountPoint,
        readOnly
      case shareProtocol = "protocol"
    }

    init(_ share: NetworkShare) {
      name = share.name
      shareProtocol = share.shareProtocol
      server = share.server
      sharePath = share.sharePath
      username = share.username
      mountAtLogin = share.mountAtLogin
      keepMounted = share.keepMounted
      customMountPoint = share.customMountPoint
      readOnly = share.readOnly
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      // An unknown protocol ("ftp") fails here, so the entry is skipped.
      shareProtocol = try container.decode(ShareProtocol.self, forKey: .shareProtocol)
      server = try container.decode(String.self, forKey: .server)
      sharePath = try container.decodeIfPresent(String.self, forKey: .sharePath) ?? ""
      name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
      username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
      mountAtLogin = try container.decodeIfPresent(Bool.self, forKey: .mountAtLogin) ?? true
      keepMounted = try container.decodeIfPresent(Bool.self, forKey: .keepMounted) ?? mountAtLogin
      customMountPoint = try container.decodeIfPresent(String.self, forKey: .customMountPoint)
      // Missing in files from MountMate versions without read-only shares.
      readOnly = try container.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(name, forKey: .name)
      try container.encode(shareProtocol, forKey: .shareProtocol)
      try container.encode(server, forKey: .server)
      try container.encode(sharePath, forKey: .sharePath)
      try container.encode(username, forKey: .username)
      try container.encode(mountAtLogin, forKey: .mountAtLogin)
      try container.encode(keepMounted, forKey: .keepMounted)
      try container.encodeIfPresent(customMountPoint, forKey: .customMountPoint)
      try container.encode(readOnly, forKey: .readOnly)
    }

    /// A new saved share (new ID) with the fields cleaned like the share
    /// sheet cleans them (a URL or UNC server is split), or nil when the server or the path is empty.
    func makeShare() -> NetworkShare? {
      // A hand-written file may hold a whole URL or UNC path as the server;
      // its path and username fill the entry's fields only when those are empty.
      let parsed = NetworkShare.cleanedServerInput(server)
      let cleanedServer = parsed.server
      let ownPath = NetworkShare.cleanedSharePathInput(sharePath)
      let cleanedPath = ownPath.isEmpty ? parsed.sharePath : ownPath
      let ownUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
      let cleanedUser = ownUser.isEmpty ? parsed.username : ownUser
      guard !cleanedServer.isEmpty, !cleanedPath.isEmpty else { return nil }
      let mountPoint = customMountPoint?.trimmingCharacters(in: .whitespacesAndNewlines)
      return NetworkShare(
        name: NetworkShare.resolvedDisplayName(name, sharePath: cleanedPath),
        server: cleanedServer, sharePath: cleanedPath,
        username: shareProtocol.supportsUserCredentials
          ? cleanedUser : "",
        mountAtLogin: mountAtLogin, keepMounted: keepMounted, shareProtocol: shareProtocol,
        customMountPoint: mountPoint?.isEmpty == false ? mountPoint : nil, readOnly: readOnly)
    }
  }

  private struct File: Encodable {
    let format: String
    let version: Int
    let shares: [Entry]
  }

  /// Reads the header first, so a file of another kind or a newer format is
  /// reported as such instead of as "every share was invalid".
  private struct Header: Decodable {
    let format: String
    let version: Int
  }

  private struct EntryList: Decodable {
    let shares: [LossyEntry]
  }

  /// An entry that could not be decoded becomes nil instead of failing the
  /// whole file.
  private struct LossyEntry: Decodable {
    let entry: Entry?

    init(from decoder: Decoder) throws {
      entry = try? Entry(from: decoder)
    }
  }

  /// The export file for `shares`: pretty-printed JSON without passwords.
  static func encode(_ shares: [NetworkShare]) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(
      File(format: format, version: currentVersion, shares: shares.map(Entry.init)))
  }

  /// The entries of an export file; nil marks one that could not be read
  /// (missing server, unknown protocol, wrong type).
  static func decode(_ data: Data) throws -> [Entry?] {
    let decoder = JSONDecoder()
    guard let header = try? decoder.decode(Header.self, from: data), header.format == format
    else { throw ReadError.notABackup }
    guard header.version <= currentVersion else {
      throw ReadError.newerVersion(header.version)
    }
    guard let list = try? decoder.decode(EntryList.self, from: data) else {
      throw ReadError.notABackup
    }
    return list.shares.map(\.entry)
  }

  struct ImportPlan: Equatable {
    /// Shares to save, with new IDs and names that do not clash.
    var shares: [NetworkShare]
    /// Entries already saved (same protocol, host and path), also twice in
    /// the file.
    var duplicates: Int
    /// Entries that could not be read or would not pass the share sheet's
    /// checks (bad name, invalid mount point).
    var invalid: Int
    /// One line per share left out because its mount folder is already used
    /// by a saved volume custom mount point or another share.
    var mountPointConflicts: [String] = []

    var skipped: Int { duplicates + invalid + mountPointConflicts.count }
  }

  /// What importing `data` next to `existing` shares would add.
  /// - Parameters:
  ///   - mountPoint: the folder a share is mounted at, as for
  ///     `NetworkShareValidation`.
  ///   - volumeClaims: the saved volume custom mount points.
  static func importPlan(
    from data: Data, existing: [NetworkShare], mountPoint: (NetworkShare) -> String,
    volumeClaims: [MountPointClaims.Claim] = []
  ) throws -> ImportPlan {
    importPlan(
      candidates: try decode(data).map { $0?.makeShare() }, existing: existing,
      mountPoint: mountPoint, volumeClaims: volumeClaims)
  }

  /// What adding `candidates` (from a file, Import Mounted or a drop) next to
  /// `existing` shares would add; nil marks an entry that could not be read.
  static func importPlan(
    candidates: [NetworkShare?], existing: [NetworkShare], mountPoint: (NetworkShare) -> String,
    volumeClaims: [MountPointClaims.Claim] = []
  ) -> ImportPlan {
    var plan = ImportPlan(shares: [], duplicates: 0, invalid: 0)
    for candidate in candidates {
      guard var share = candidate else {
        plan.invalid += 1
        continue
      }
      let saved = existing + plan.shares
      if PersistenceManager.containsNetworkShare(matching: share, in: saved) {
        plan.duplicates += 1
        continue
      }
      // The default mount folder is ~/mountmate/<name>, so "Public" from two
      // servers becomes "Public" and "Public (2)" as with Import Mounted.
      share.name = PersistenceManager.uniqueShareName(share.name, existing: saved.map(\.name))
      guard
        NetworkShareValidation.error(
          candidate: share, original: nil, otherShares: saved, mountPoint: mountPoint,
          volumeClaims: volumeClaims) != nil
      else {
        plan.shares.append(share)
        continue
      }
      // A folder claimed by a volume rule or another share would make the
      // later mount fail with "not empty": say whose it is.
      let claims = volumeClaims + MountPointClaims.shareClaims(saved, mountPoint: mountPoint)
      if let claim = MountPointClaims.claim(on: mountPoint(share), in: claims, excludingKey: nil) {
        plan.mountPointConflicts.append(
          String(
            format: NSLocalizedString(
              "Share Not Added Mount Point In Use",
              comment: "Share import result: share name, then why its mount point is taken"),
            share.name, MountPointClaims.message(for: claim)))
      } else {
        plan.invalid += 1
      }
    }
    return plan
  }

  /// The message after Import Mounted or a drop of `discovered` mounted
  /// shares: how many were added, or why none were, then each share left out
  /// because its mount point is in use.
  static func mountedImportMessage(
    for plan: ImportPlan, discovered: Int, bundle: Bundle = .main, locale: Locale = .current
  ) -> String {
    var sentences: [String] = []
    if !plan.shares.isEmpty {
      sentences.append(
        PluralizedString.format(
          "shares.imported", plan.shares.count, bundle: bundle, locale: locale))
    } else if discovered > plan.mountPointConflicts.count {
      sentences.append(
        bundle.localizedString(
          forKey: "Those mounted shares are already in MountMate.", value: nil, table: nil))
    } else if discovered == 0 {
      sentences.append(
        bundle.localizedString(
          forKey: "No mounted SMB, NFS or AFP shares were found.", value: nil, table: nil))
    }
    return (sentences + plan.mountPointConflicts).joined(separator: " ")
  }

  /// "Imported 3 shares.", then "Skipped 2 …" when something was skipped and
  /// a reminder to add passwords when an imported share can have one.
  static func resultMessage(
    for plan: ImportPlan, bundle: Bundle = .main, locale: Locale = .current
  ) -> String {
    var sentences = [
      PluralizedString.format(
        "shares.backup.imported", plan.shares.count, bundle: bundle, locale: locale)
    ]
    if plan.skipped > 0 {
      sentences.append(
        PluralizedString.format(
          "shares.backup.skipped", plan.skipped, bundle: bundle, locale: locale))
      sentences += plan.mountPointConflicts
    }
    if plan.shares.contains(where: { $0.shareProtocol.supportsUserCredentials }) {
      sentences.append(
        bundle.localizedString(
          forKey: "Passwords are not exported. Add them by editing each share.", value: nil,
          table: nil))
    }
    return sentences.joined(separator: " ")
  }
}
