import Foundation
import XCTest

/// Checks the SEO metadata and image alt text of the landing page in `docs/index.html`.
final class DocsLandingMetaTests: XCTestCase {
  private static let indexURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("docs/index.html")

  private func html() throws -> String {
    try String(contentsOf: Self.indexURL, encoding: .utf8)
  }

  private func matches(_ pattern: String, in text: String) throws -> [[String]] {
    let regex = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
    let range = NSRange(text.startIndex..., in: text)
    return regex.matches(in: text, range: range).map { match in
      (0..<match.numberOfRanges).map { index in
        Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
      }
    }
  }

  private func metaContent(_ attribute: String, _ name: String, in text: String) throws -> String? {
    let pattern =
      "<meta\\s+\(attribute)=\"\(NSRegularExpression.escapedPattern(for: name))\"\\s+content=\"([^\"]*)\""
    return try matches(pattern, in: text).first?[1]
  }

  func testDescriptionNamesKeyFeaturesAndMatchesSocialTags() throws {
    let text = try html()
    let description = try XCTUnwrap(metaContent("name", "description", in: text))
    XCTAssertTrue((120...165).contains(description.count), "length \(description.count)")
    XCTAssertTrue(description.contains("network"))
    XCTAssertTrue(description.contains("Homebrew"))
    XCTAssertEqual(try metaContent("property", "og:description", in: text), description)
    XCTAssertEqual(try metaContent("property", "twitter:description", in: text), description)
    let imageAlt = try XCTUnwrap(metaContent("property", "twitter:image:alt", in: text))
    XCTAssertFalse(imageAlt.isEmpty)
  }

  func testHasExactlyOneCanonicalLink() throws {
    let links = try matches("<link\\s+rel=\"canonical\"\\s+href=\"([^\"]*)\"", in: html())
    XCTAssertEqual(links.map { $0[1] }, ["https://mountmate.homielab.com/"])
  }

  func testEveryImageHasDistinctLightAndDarkAlt() throws {
    let images = try matches("<img\\b[^>]*>", in: html()).map { $0[0] }
    XCTAssertFalse(images.isEmpty)
    var altBySrc: [String: String] = [:]
    for image in images {
      let alt = try XCTUnwrap(matches("alt=\"([^\"]*)\"", in: image).first?[1], image)
      XCTAssertFalse(alt.trimmingCharacters(in: .whitespaces).isEmpty, image)
      if let src = try matches("src=\"([^\"]*)\"", in: image).first?[1] {
        altBySrc[src] = alt
      }
    }
    for (light, dark) in [
      ("screenshots/light-full.png", "screenshots/dark-full.png"),
      ("screenshots/light.png", "screenshots/dark.png"),
    ] {
      let lightAlt = try XCTUnwrap(altBySrc[light])
      let darkAlt = try XCTUnwrap(altBySrc[dark])
      XCTAssertNotEqual(lightAlt, darkAlt)
    }
  }

  func testJSONLDParsesWithFeatureList() throws {
    let blocks = try matches(
      "<script type=\"application/ld\\+json\">(.*?)</script>", in: html())
    let json = try XCTUnwrap(blocks.first?[1].data(using: .utf8))
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
    let features = try XCTUnwrap(object["featureList"] as? [String])
    XCTAssertFalse(features.isEmpty)
    XCTAssertEqual(object["@type"] as? String, "SoftwareApplication")
  }
}
