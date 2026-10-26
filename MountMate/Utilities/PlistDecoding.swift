//  Created by homielab.com

import Foundation

/// Decodes the property lists `diskutil -plist` prints. A parse failure is
/// logged instead of silently turning into "nothing found".
enum PlistDecoding {
  /// The top-level dictionary of `data`; nil (and a warning in the log) when
  /// it is not a property list dictionary.
  /// - Parameter context: what was being read, for the log (never user data).
  static func decode(_ data: Data, context: String = "diskutil output") -> [String: Any]? {
    do {
      let object = try PropertyListSerialization.propertyList(
        from: data, options: [], format: nil)
      if let dictionary = object as? [String: Any] { return dictionary }
      Log.mounter.warning(
        "Property list for \(context, privacy: .public) is not a dictionary")
    } catch {
      Log.mounter.warning(
        "Could not parse the property list for \(context, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
    }
    return nil
  }

  /// `decode(_:context:)` for text read from a process.
  static func decode(_ text: String, context: String = "diskutil output") -> [String: Any]? {
    guard let data = text.data(using: .utf8) else { return nil }
    return decode(data, context: context)
  }
}
