//  Created by homielab.com

import XCTest

@testable import MountMate

final class NetworkShareBackupTests: XCTestCase {
  private let mountUnderHome: (NetworkShare) -> String = {
    NetworkMountTable.configuredMountPoint(for: $0, homeDirectory: "/Users/test")
  }

  private func plan(_ json: String, existing: [NetworkShare] = []) throws
    -> NetworkShareBackup.ImportPlan
  {
    try NetworkShareBackup.importPlan(
      from: Data(json.utf8), existing: existing, mountPoint: mountUnderHome)
  }

  private func file(_ entries: String, version: Int = 1) -> String {
    """
    {"format": "mountmate.networkShares", "version": \(version), "shares": [\(entries)]}
    """
  }

  private let sampleShares = [
    NetworkShare(
      name: "Media", server: "nas.local:445", sharePath: "Media/Movies", username: "CORP\\jane",
      mountAtLogin: false, keepMounted: true, shareProtocol: .smb),
    NetworkShare(
      name: "Exports", server: "[fd00::2]", sharePath: "volume1/Exports", username: "",
      mountAtLogin: true, keepMounted: false, shareProtocol: .nfs,
      customMountPoint: "/Volumes/Exports", readOnly: true, softMount: true),
    NetworkShare(
      name: "Old", server: "mac.local", sharePath: "Old", username: "admin", shareProtocol: .afp),
  ]

  /// The fields a user sees, without the ID that an import replaces.
  private func fields(_ share: NetworkShare) -> [String] {
    [
      share.name, share.server, share.sharePath, share.username, "\(share.mountAtLogin)",
      "\(share.keepMounted)", share.shareProtocol.rawValue, share.customMountPoint ?? "-",
      "\(share.readOnly)", "\(share.softMount)",
    ]
  }

  // MARK: - Round trip

  func testExportThenImportGivesTheSameShares() throws {
    let data = try NetworkShareBackup.encode(sampleShares)
    let plan = try NetworkShareBackup.importPlan(
      from: data, existing: [], mountPoint: mountUnderHome)

    XCTAssertEqual(plan.shares.map(fields), sampleShares.map(fields))
    XCTAssertEqual(plan.skipped, 0)
    // Imported shares get new IDs, so they never reuse another Mac's
    // Keychain account.
    XCTAssertTrue(Set(plan.shares.map(\.id)).isDisjoint(with: sampleShares.map(\.id)))
  }

  func testExportHasAVersionAndNoPasswordOrID() throws {
    let data = try NetworkShareBackup.encode(sampleShares)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(object["format"] as? String, NetworkShareBackup.format)
    XCTAssertEqual(object["version"] as? Int, NetworkShareBackup.currentVersion)

    let entries = try XCTUnwrap(object["shares"] as? [[String: Any]])
    XCTAssertEqual(entries.count, 3)
    let allowed: Set<String> = [
      "name", "protocol", "server", "sharePath", "username", "mountAtLogin", "keepMounted",
      "customMountPoint", "readOnly", "softMount",
    ]
    for entry in entries {
      XCTAssertTrue(Set(entry.keys).isSubset(of: allowed), "\(entry.keys)")
    }
    let text = try XCTUnwrap(String(data: data, encoding: .utf8))
    XCTAssertFalse(text.lowercased().contains("password"))
    XCTAssertFalse(text.contains(sampleShares[0].id.uuidString))
  }

  // MARK: - Duplicates

  func testSkipsSharesThatAreAlreadySaved() throws {
    let saved = NetworkShare(
      name: "My Media", server: "NAS.local", sharePath: "media/movies", username: "")
    let plan = try NetworkShareBackup.importPlan(
      from: NetworkShareBackup.encode(sampleShares), existing: [saved], mountPoint: mountUnderHome)

    XCTAssertEqual(plan.shares.map(\.name), ["Exports", "Old"])
    XCTAssertEqual(plan.duplicates, 1)
    XCTAssertEqual(plan.invalid, 0)
  }

  func testSkipsAShareListedTwiceInTheFile() throws {
    let entry = #"{"protocol": "smb", "server": "nas", "sharePath": "Public"}"#
    let plan = try plan(file("\(entry), \(entry)"))
    XCTAssertEqual(plan.shares.count, 1)
    XCTAssertEqual(plan.duplicates, 1)
  }

  func testRenamesAShareWhoseNameIsTakenBySavedShareOnAnotherServer() throws {
    let saved = NetworkShare(name: "Public", server: "other", sharePath: "Public", username: "")
    let plan = try plan(
      file(#"{"name": "Public", "protocol": "smb", "server": "nas", "sharePath": "Public"}"#),
      existing: [saved])
    XCTAssertEqual(plan.shares.map(\.name), ["Public (2)"])
  }

  // MARK: - Invalid entries

  func testCountsBrokenEntriesAndKeepsTheRest() throws {
    let plan = try plan(
      file(
        """
        {"protocol": "smb", "server": "nas", "sharePath": "Good"},
        {"protocol": "smb", "sharePath": "NoServer"},
        {"protocol": "smb", "server": "   ", "sharePath": "Blank"},
        {"protocol": "nfs", "server": 42, "sharePath": "export"},
        "not an object",
        {"name": "a/b", "protocol": "smb", "server": "nas", "sharePath": "Slash"}
        """))
    XCTAssertEqual(plan.shares.map(\.name), ["Good"])
    XCTAssertEqual(plan.invalid, 5)
    XCTAssertEqual(plan.duplicates, 0)
  }

  func testSkipsAnUnknownProtocol() throws {
    let plan = try plan(
      file(
        """
        {"protocol": "ftp", "server": "nas", "sharePath": "files"},
        {"protocol": "nfs", "server": "nas", "sharePath": "export"}
        """))
    XCTAssertEqual(plan.shares.map(\.shareProtocol), [.nfs])
    XCTAssertEqual(plan.invalid, 1)
  }

  func testSkipsAShareWhoseMountPointIsTaken() throws {
    let saved = NetworkShare(
      name: "Docs", server: "other", sharePath: "Docs", username: "",
      customMountPoint: "/Volumes/NAS")
    let plan = try plan(
      file(
        #"{"protocol": "smb", "server": "nas", "sharePath": "Media", "customMountPoint": "/Volumes/NAS"}"#
      ),
      existing: [saved])
    XCTAssertTrue(plan.shares.isEmpty)
    XCTAssertEqual(plan.invalid, 0)
    XCTAssertEqual(plan.skipped, 1)
    XCTAssertTrue(plan.mountPointConflicts[0].contains("Docs"))
  }

  func testFillsDefaultsForMissingFields() throws {
    let plan = try plan(file(#"{"protocol": "smb", "server": " nas ", "sharePath": "/Media/"}"#))
    let share = try XCTUnwrap(plan.shares.first)
    XCTAssertEqual(share.name, "Media")
    XCTAssertEqual(share.server, "nas")
    XCTAssertEqual(share.sharePath, "Media")
    XCTAssertEqual(share.username, "")
    XCTAssertTrue(share.mountAtLogin)
    XCTAssertTrue(share.keepMounted)
    XCTAssertNil(share.customMountPoint)
    // Files from versions without read-only shares mount writable.
    XCTAssertFalse(share.readOnly)
    // Files from versions without soft mounts mount hard.
    XCTAssertFalse(share.softMount)
  }

  func testSoftMountIsKeptOnlyForNFS() throws {
    let plan = try plan(
      file(
        """
        {"protocol": "nfs", "server": "nas", "sharePath": "export", "softMount": true},
        {"protocol": "smb", "server": "nas", "sharePath": "Public", "softMount": true}
        """))
    XCTAssertEqual(plan.shares.map(\.softMount), [true, false])
  }

  func testSplitsAURLInTheServerField() throws {
    let plan = try plan(file(#"{"protocol": "smb", "server": "smb://admin@nas.local/Public"}"#))
    let share = try XCTUnwrap(plan.shares.first)
    XCTAssertEqual(share.server, "nas.local")
    XCTAssertEqual(share.sharePath, "Public")
    XCTAssertEqual(share.username, "admin")
    XCTAssertEqual(share.name, "Public")
  }

  func testSplitsAUNCPathInTheServerField() throws {
    let plan = try plan(file(#"{"protocol": "smb", "server": "\\\\nas\\Public", "sharePath": ""}"#))
    let share = try XCTUnwrap(plan.shares.first)
    XCTAssertEqual(share.server, "nas")
    XCTAssertEqual(share.sharePath, "Public")
  }

  func testKeepsThePortAndPrefersTheEntrysOwnPathAndUser() throws {
    let plan = try plan(
      file(
        #"{"protocol": "smb", "server": "bob@nas:8445/Other", "sharePath": "Media", "username": "jane"}"#
      ))
    let share = try XCTUnwrap(plan.shares.first)
    XCTAssertEqual(share.server, "nas:8445")
    XCTAssertEqual(share.sharePath, "Media")
    XCTAssertEqual(share.username, "jane")
  }

  func testSkipsAURLEntryThatMatchesASavedShareAfterCleanup() throws {
    let saved = NetworkShare(name: "Public", server: "nas.local", sharePath: "Public", username: "")
    let plan = try plan(
      file(
        #"{"protocol": "smb", "server": "smb://admin@NAS.local/Public"}, {"protocol": "smb", "server": "\\\\nas2\\Data"}, {"protocol": "smb", "server": "smb://nas2/Data"}"#
      ), existing: [saved])
    XCTAssertEqual(plan.shares.map(\.server), ["nas2"])
    XCTAssertEqual(plan.duplicates, 2)
  }

  // MARK: - Whole file

  func testRejectsAFileThatIsNotAnExport() {
    for json in ["", "[]", #"{"shares": []}"#, #"{"format": "other", "version": 1, "shares": []}"#]
    {
      XCTAssertThrowsError(try plan(json), json) { error in
        XCTAssertEqual(error as? NetworkShareBackup.ReadError, .notABackup)
      }
    }
    XCTAssertThrowsError(
      try plan(#"{"format": "mountmate.networkShares", "version": 1, "shares": 3}"#)
    ) { error in
      XCTAssertEqual(error as? NetworkShareBackup.ReadError, .notABackup)
    }
  }

  func testRejectsANewerVersion() {
    XCTAssertThrowsError(try plan(file("", version: 2))) { error in
      XCTAssertEqual(error as? NetworkShareBackup.ReadError, .newerVersion(2))
    }
  }

  func testAnEmptyExportImportsNothing() throws {
    let plan = try NetworkShareBackup.importPlan(
      from: NetworkShareBackup.encode([]), existing: [], mountPoint: mountUnderHome)
    XCTAssertEqual(plan, NetworkShareBackup.ImportPlan(shares: [], duplicates: 0, invalid: 0))
  }

  // MARK: - Message

  private func englishBundle() throws -> Bundle {
    let path = try XCTUnwrap(
      Bundle(for: DriveManager.self).path(forResource: "en", ofType: "lproj"))
    return try XCTUnwrap(Bundle(path: path))
  }

  func testResultMessageCountsImportedAndSkipped() throws {
    let bundle = try englishBundle()
    let locale = Locale(identifier: "en")
    let smb = NetworkShare(name: "A", server: "nas", sharePath: "A", username: "")
    let nfs = NetworkShare(
      name: "B", server: "nas", sharePath: "B", username: "", shareProtocol: .nfs)

    XCTAssertEqual(
      NetworkShareBackup.resultMessage(
        for: .init(shares: [nfs], duplicates: 0, invalid: 0), bundle: bundle, locale: locale),
      "Imported 1 share.")
    XCTAssertEqual(
      NetworkShareBackup.resultMessage(
        for: .init(shares: [smb, nfs], duplicates: 1, invalid: 2), bundle: bundle,
        locale: locale),
      "Imported 2 shares. Skipped 3 (already saved or invalid). "
        + "Passwords are not exported. Add them by editing each share.")
    XCTAssertEqual(
      NetworkShareBackup.resultMessage(
        for: .init(shares: [], duplicates: 4, invalid: 0), bundle: bundle, locale: locale),
      "Imported 0 shares. Skipped 4 (already saved or invalid).")
  }

  // MARK: - Mount points claimed by volumes and shares

  private let mediaVolume = MountPointClaims.volumeClaims([
    VolumeCustomMountPoint(
      volumeUUID: "U1", backingDiskIdentifier: "disk4", name: "Media Disk",
      mountPoint: "/Users/test/mountmate/Media")
  ])

  func testFileShareOnAVolumeMountPointIsSkippedWithTheVolumeName() throws {
    let data = try NetworkShareBackup.encode([
      NetworkShare(name: "Media", server: "nas", sharePath: "Media", username: ""),
      NetworkShare(name: "Docs", server: "nas", sharePath: "Docs", username: ""),
    ])
    let plan = try NetworkShareBackup.importPlan(
      from: data, existing: [], mountPoint: mountUnderHome, volumeClaims: mediaVolume)

    XCTAssertEqual(plan.shares.map(\.name), ["Docs"])
    XCTAssertEqual(plan.invalid, 0)
    XCTAssertEqual(plan.skipped, 1)
    XCTAssertEqual(plan.mountPointConflicts.count, 1)
    XCTAssertTrue(plan.mountPointConflicts[0].contains("Media Disk"))
    XCTAssertTrue(NetworkShareBackup.resultMessage(for: plan).contains("Media Disk"))
  }

  func testFileShareWithoutClashImportsNormallyWithVolumeClaims() throws {
    let data = try NetworkShareBackup.encode([
      NetworkShare(name: "Docs", server: "nas", sharePath: "Docs", username: "")
    ])
    let plan = try NetworkShareBackup.importPlan(
      from: data, existing: [], mountPoint: mountUnderHome, volumeClaims: mediaVolume)
    XCTAssertEqual(plan.shares.map(\.name), ["Docs"])
    XCTAssertEqual(plan.skipped, 0)
  }

  func testMountedShareOnAVolumeMountPointIsSkipped() throws {
    let mounted = NetworkShare(
      name: "Movies", server: "nas", sharePath: "Movies", username: "",
      customMountPoint: "/Users/test/mountmate/media/")
    let plan = NetworkShareBackup.importPlan(
      candidates: [mounted], existing: [], mountPoint: mountUnderHome, volumeClaims: mediaVolume)

    XCTAssertTrue(plan.shares.isEmpty)
    XCTAssertEqual(plan.mountPointConflicts.count, 1)
    let message = NetworkShareBackup.mountedImportMessage(for: plan, discovered: 1)
    XCTAssertTrue(message.contains("Movies"))
    XCTAssertTrue(message.contains("Media Disk"))
  }

  func testMountedShareOnAnotherSharesMountPointIsSkipped() throws {
    let saved = NetworkShare(
      name: "Backup", server: "nas", sharePath: "Backup", username: "",
      customMountPoint: "/Volumes/NAS")
    let dropped = NetworkShare(
      name: "Photos", server: "other", sharePath: "Photos", username: "",
      customMountPoint: "/Volumes/NAS")
    let plan = NetworkShareBackup.importPlan(
      candidates: [dropped], existing: [saved], mountPoint: mountUnderHome)

    XCTAssertTrue(plan.shares.isEmpty)
    XCTAssertEqual(plan.mountPointConflicts.count, 1)
    XCTAssertTrue(plan.mountPointConflicts[0].contains("Backup"))
  }

  func testMountedImportMessage() throws {
    let bundle = try englishBundle()
    let locale = Locale(identifier: "en")
    let share = NetworkShare(name: "A", server: "nas", sharePath: "A", username: "")
    XCTAssertEqual(
      NetworkShareBackup.mountedImportMessage(
        for: .init(shares: [], duplicates: 0, invalid: 0), discovered: 0, bundle: bundle,
        locale: locale),
      "No mounted SMB, NFS or AFP shares were found.")
    XCTAssertEqual(
      NetworkShareBackup.mountedImportMessage(
        for: .init(shares: [], duplicates: 2, invalid: 0), discovered: 2, bundle: bundle,
        locale: locale),
      "Those mounted shares are already in MountMate.")
    XCTAssertEqual(
      NetworkShareBackup.mountedImportMessage(
        for: .init(shares: [], duplicates: 0, invalid: 0, mountPointConflicts: ["X."]),
        discovered: 1, bundle: bundle, locale: locale),
      "X.")
    XCTAssertTrue(
      NetworkShareBackup.mountedImportMessage(
        for: .init(shares: [share], duplicates: 0, invalid: 0, mountPointConflicts: ["X."]),
        discovered: 2, bundle: bundle, locale: locale
      ).hasSuffix(" X."))
  }

  // MARK: - Mount points from another Mac

  func testExportWritesMountPointsUnderHomeWithTilde() throws {
    let share = NetworkShare(
      name: "Media", server: "nas.local", sharePath: "Media", username: "",
      shareProtocol: .smb, customMountPoint: "/Users/alice/NAS/Media")
    let data = try NetworkShareBackup.encode([share], homeDirectory: "/Users/alice")
    let text = try XCTUnwrap(String(data: data, encoding: .utf8))
    XCTAssertTrue(text.contains("\"~/NAS/Media\""), text)
    XCTAssertFalse(text.contains("alice"))
  }

  func testImportExpandsTildeAndResetsAnotherUsersFolder() throws {
    let json = file(
      """
      {"protocol": "smb", "server": "a.local", "sharePath": "A", "customMountPoint": "~/NAS/A"},
      {"protocol": "smb", "server": "b.local", "sharePath": "B", "customMountPoint": "/Users/alice/NAS/B"},
      {"protocol": "smb", "server": "c.local", "sharePath": "C", "customMountPoint": "/Volumes/Missing/C"},
      {"protocol": "smb", "server": "d.local", "sharePath": "D", "customMountPoint": "/Volumes/D"}
      """)
    let plan = try NetworkShareBackup.importPlan(
      from: Data(json.utf8), existing: [], mountPoint: mountUnderHome,
      homeDirectory: "/Users/test",
      folderExists: { ["/Users/test/NAS", "/Volumes"].contains($0) })
    XCTAssertEqual(
      plan.shares.map { $0.customMountPoint ?? "-" }, ["/Users/test/NAS/A", "-", "-", "/Volumes/D"])
    XCTAssertEqual(plan.resetMountPoints, 2)
    XCTAssertEqual(plan.skipped, 0)
    let message = NetworkShareBackup.resultMessage(
      for: plan, bundle: try englishBundle(), locale: Locale(identifier: "en"))
    XCTAssertTrue(message.contains("2 shares use the default mount folder"), message)
  }
}
