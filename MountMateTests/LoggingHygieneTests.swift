import Foundation
import XCTest

@testable import MountMate

/// Guards the logging rules: everything goes through `Log` (unified logging,
/// readable in Console.app) and nothing that can carry a password or a
/// credential URL is logged as public.
final class LoggingHygieneTests: XCTestCase {
  private static let appSourceDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("MountMate")

  /// (relative path, line number, line) for every line of the app's Swift sources.
  private func appSourceLines() throws -> [(String, Int, String)] {
    let root = Self.appSourceDirectory
    guard
      let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    else {
      XCTFail("Cannot read \(root.path)")
      return []
    }
    var lines: [(String, Int, String)] = []
    for case let url as URL in enumerator where url.pathExtension == "swift" {
      let path = String(url.path.dropFirst(root.path.count + 1))
      let text = try String(contentsOf: url, encoding: .utf8)
      for (index, line) in text.components(separatedBy: "\n").enumerated() {
        lines.append((path, index + 1, line))
      }
    }
    XCTAssertFalse(lines.isEmpty, "No Swift sources found in \(root.path)")
    return lines
  }

  func testLoggerUsesTheAppBundleIdentifier() {
    XCTAssertEqual(Log.subsystem, "com.homielab.mountmate")
  }

  func testAppSourcesDoNotUsePrint() throws {
    let offenders = try appSourceLines().filter { _, _, line in
      let code = line.trimmingCharacters(in: .whitespaces)
      return !code.hasPrefix("//")
        && code.range(of: #"\bprint\("#, options: .regularExpression) != nil
    }
    XCTAssertTrue(
      offenders.isEmpty,
      "Use Log.<category> instead of print(): "
        + offenders.map { "\($0.0):\($0.1)" }.joined(separator: ", "))
  }

  func testSensitiveValuesAreNeverLoggedPublic() throws {
    let publicInterpolation = try NSRegularExpression(
      pattern: #"\\\(((?:(?!\\\().)+?), privacy: \.public\)"#)
    let sensitive = try NSRegularExpression(
      pattern: "password|passphrase|credential|secret|url|user|stderr|stdout|arguments",
      options: .caseInsensitive)
    var offenders: [String] = []
    for (path, number, line) in try appSourceLines() {
      let range = NSRange(line.startIndex..., in: line)
      for match in publicInterpolation.matches(in: line, range: range) {
        guard let expressionRange = Range(match.range(at: 1), in: line) else { continue }
        let expression = String(line[expressionRange])
        // Byte and element counts are harmless.
        if expression.hasSuffix(".count") { continue }
        let expressionNSRange = NSRange(expression.startIndex..., in: expression)
        if sensitive.firstMatch(in: expression, range: expressionNSRange) != nil {
          offenders.append("\(path):\(number) \(expression)")
        }
      }
    }
    XCTAssertTrue(
      offenders.isEmpty,
      "Log these with privacy: .private (or redact them): " + offenders.joined(separator: ", "))
  }
}
