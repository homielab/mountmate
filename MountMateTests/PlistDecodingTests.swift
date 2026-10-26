//  Created by homielab.com

import XCTest

@testable import MountMate

final class PlistDecodingTests: XCTestCase {
  func testDecodesADictionaryFromDataAndText() {
    let xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <plist version="1.0"><dict><key>DeviceIdentifier</key><string>disk4</string></dict></plist>
      """
    XCTAssertEqual(PlistDecoding.decode(xml)?["DeviceIdentifier"] as? String, "disk4")
    XCTAssertEqual(
      PlistDecoding.decode(Data(xml.utf8))?["DeviceIdentifier"] as? String, "disk4")
  }

  func testGarbageAndEmptyInputGiveNil() {
    XCTAssertNil(PlistDecoding.decode("not a plist"))
    XCTAssertNil(PlistDecoding.decode(""))
  }

  func testAPropertyListThatIsNotADictionaryGivesNil() {
    let array = """
      <?xml version="1.0" encoding="UTF-8"?>
      <plist version="1.0"><array><string>a</string></array></plist>
      """
    XCTAssertNil(PlistDecoding.decode(array))
  }
}
