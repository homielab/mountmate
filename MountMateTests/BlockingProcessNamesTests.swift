//  Created by homielab.com

import XCTest

@testable import MountMate

final class BlockingProcessNamesTests: XCTestCase {
  func testSystemServicesGetFriendlyNamesAndSymbols() {
    let cases: [(String, String, String)] = [
      (
        "/System/Library/Frameworks/CoreServices.framework/Versions/A/Support/mds",
        "Spotlight indexing", "magnifyingglass"
      ),
      ("/usr/libexec/mds_stores", "Spotlight indexing", "magnifyingglass"),
      ("mdworker_shared", "Spotlight indexing", "magnifyingglass"),
      ("/System/Library/Frameworks/QuickLookUI.framework/QuickLookUIService", "Quick Look", "eye"),
      ("quicklookd", "Quick Look", "eye"),
      (
        "/System/Library/CoreServices/backupd.bundle/Contents/Resources/backupd", "Time Machine",
        "clock.arrow.circlepath"
      ),
      ("backupd-helper", "Time Machine", "clock.arrow.circlepath"),
      (
        "/System/Library/PrivateFrameworks/CloudDocsDaemon.framework/Versions/A/Support/bird",
        "iCloud Drive", "icloud"
      ),
      ("/bin/zsh", "Terminal shell", "terminal"),
      (
        "/System/Library/Filesystems/apfs.fs/Contents/Resources/fsck_apfs", "Disk check",
        "stethoscope"
      ),
      ("/usr/libexec/fseventsd", "macOS file tracking", "doc.text.magnifyingglass"),
      ("XprotectService", "Malware scan", "checkmark.shield"),
    ]
    for (path, name, symbol) in cases {
      let process = BlockingProcessNames.describe(path: path)
      XCTAssertEqual(process.displayName, name, path)
      XCTAssertEqual(process.kind, .system(symbol: symbol), path)
      XCTAssertEqual(process.rawName, (path as NSString).lastPathComponent)
    }
  }

  func testFinderIsAnAppWithItsBundle() {
    let finder = BlockingProcessNames.describe(
      path: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", pid: 412)
    XCTAssertEqual(finder.displayName, "Finder")
    XCTAssertEqual(finder.kind, .app(bundlePath: "/System/Library/CoreServices/Finder.app"))
    XCTAssertEqual(finder.pid, 412)
    // diskutil printed only the name.
    XCTAssertEqual(
      BlockingProcessNames.describe(path: "Finder").kind,
      .app(bundlePath: BlockingProcessNames.finderBundlePath))
  }

  func testAppHelperIsNamedAfterTheOuterApp() {
    let helper = BlockingProcessNames.describe(
      path:
        "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
    )
    XCTAssertEqual(helper.displayName, "Google Chrome")
    XCTAssertEqual(helper.kind, .app(bundlePath: "/Applications/Google Chrome.app"))
    XCTAssertEqual(helper.rawName, "Google Chrome Helper")
  }

  func testUnknownProcessKeepsItsRawName() {
    let unknown = BlockingProcessNames.describe(path: "/usr/local/bin/rsync")
    XCTAssertEqual(unknown.displayName, "rsync")
    XCTAssertEqual(unknown.kind, .unknown)
    XCTAssertNil(BlockingProcessNames.outermostAppBundle(in: "relative/Foo.app/x"))
  }

  func testClassifierUsesFriendlyNameAndKeepsPID() throws {
    let raw =
      "Volume Backup on disk4s2 failed to unmount: dissented by PID 77 (/System/Library/Frameworks/CoreServices.framework/Frameworks/Metadata.framework/Versions/A/Support/mds_stores)"
    XCTAssertEqual(
      DiskUtilErrorClassifier.classify(raw, for: "Backup", operation: .eject),
      .inUse(process: "Spotlight indexing"))
    let process = try XCTUnwrap(DiskUtilErrorClassifier.blockingProcess(in: raw))
    XCTAssertEqual(process.pid, 77)
    XCTAssertEqual(process.rawName, "mds_stores")
    XCTAssertNil(
      DiskUtilErrorClassifier.blockingProcess(in: "Resource busy (/usr/libexec/mds)")?.pid)
  }

  func testFriendlyNamesAreLocalizedInEveryLanguage() throws {
    let keys = [
      "Spotlight indexing", "Terminal shell", "macOS file tracking", "Malware scan", "Disk check",
    ]
    for language in ["en", "fr", "ru", "uk", "vi", "zh-Hans", "zh-Hant"] {
      let path = try XCTUnwrap(
        Bundle.main.path(forResource: language, ofType: "lproj"), language)
      let bundle = try XCTUnwrap(Bundle(path: path))
      for key in keys {
        let value = bundle.localizedString(forKey: key, value: "<missing>", table: nil)
        XCTAssertNotEqual(value, "<missing>", "\(language): \(key)")
      }
    }
  }
}
