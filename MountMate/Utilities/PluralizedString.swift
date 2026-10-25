import Foundation

/// Looks up a plural-aware string in `Localizable.stringsdict` and fills in its arguments.
///
/// Languages such as Russian and Ukrainian need up to four plural forms, which a
/// plain `Localizable.strings` entry cannot express. `bundle` and `locale` are
/// parameters so tests can pick a language without changing the system settings.
enum PluralizedString {
  static func format(
    _ key: String, _ arguments: CVarArg..., bundle: Bundle = .main, locale: Locale = .current
  ) -> String {
    let template = bundle.localizedString(forKey: key, value: key, table: nil)
    return String(format: template, locale: locale, arguments: arguments)
  }
}
