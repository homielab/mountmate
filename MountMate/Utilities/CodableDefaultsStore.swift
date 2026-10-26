//  Created by homielab.com

import Foundation

/// Saves and loads lists of `Codable` values as JSON in `UserDefaults`,
/// tolerating entries that can no longer be decoded.
enum CodableDefaultsStore {
  /// Returns false (and keeps the previously saved value) when the list
  /// cannot be encoded; the reason is logged.
  @discardableResult
  static func save<T: Codable>(
    _ items: [T], to key: String, defaults: UserDefaults = .standard
  ) -> Bool {
    do {
      defaults.set(try JSONEncoder().encode(items), forKey: key)
      return true
    } catch {
      Log.persistence.error(
        "Could not save \(key, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
      return false
    }
  }

  /// Loads a saved list. Elements are decoded one by one, so a single entry
  /// that cannot be read (e.g. written by a newer version) does not empty the
  /// whole list. When anything is skipped, the raw data is backed up first,
  /// because the next save overwrites it with the readable entries only.
  static func load<T: Codable>(from key: String, defaults: UserDefaults = .standard) -> [T] {
    guard let data = defaults.data(forKey: key) else { return [] }
    let result = decodeLossyArray(T.self, from: data)
    if result.hadFailures {
      Log.persistence.error(
        "Some saved entries for \(key, privacy: .public) could not be read and were skipped (\(result.elements.count, privacy: .public) kept)."
      )
      backUpUndecodableData(data, forKey: key, defaults: defaults)
    }
    return result.elements
  }

  struct LossyDecodeResult<Element> {
    var elements: [Element]
    /// True when at least one element, or the whole payload, could not be
    /// decoded.
    var hadFailures: Bool
  }

  /// Decodes each element on its own; a nil `value` marks an element that
  /// failed. (Its decoder still consumes the element, so decoding continues
  /// with the next one.)
  private struct LossyElement<Element: Decodable>: Decodable {
    let value: Element?

    init(from decoder: Decoder) throws {
      value = try? Element(from: decoder)
    }
  }

  /// Decodes a JSON array, skipping elements that fail to decode. A payload
  /// that is not a JSON array at all yields no elements and `hadFailures`.
  static func decodeLossyArray<Element: Decodable>(
    _ type: Element.Type, from data: Data
  ) -> LossyDecodeResult<Element> {
    guard let wrapped = try? JSONDecoder().decode([LossyElement<Element>].self, from: data) else {
      return LossyDecodeResult(elements: [], hadFailures: true)
    }
    let elements = wrapped.compactMap(\.value)
    return LossyDecodeResult(elements: elements, hadFailures: elements.count != wrapped.count)
  }

  /// Stores `data` under "<key>_backup_<unix timestamp>". At most one backup
  /// per key per app version, so a list that keeps failing to decode on
  /// every launch does not pile up copies.
  static func backUpUndecodableData(
    _ data: Data, forKey key: String, defaults: UserDefaults = .standard,
    appVersion: String = CodableDefaultsStore.currentAppVersion, now: Date = Date()
  ) {
    let markerKey = "\(key)_backupVersion"
    guard defaults.string(forKey: markerKey) != appVersion else { return }
    let backupKey = "\(key)_backup_\(Int(now.timeIntervalSince1970))"
    defaults.set(data, forKey: backupKey)
    defaults.set(appVersion, forKey: markerKey)
    Log.persistence.notice(
      "Backed up the unreadable data of \(key, privacy: .public) to \(backupKey, privacy: .public)."
    )
  }

  static var currentAppVersion: String {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "?"
    let build = info?["CFBundleVersion"] as? String ?? "?"
    return "\(version) (\(build))"
  }
}
