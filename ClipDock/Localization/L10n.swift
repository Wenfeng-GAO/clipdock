import Foundation

enum L10n {
    /// Lightweight localization helper backed by `Localizable.strings`.
    /// - Note: `key` falls back to itself when missing to avoid blank UI.
    static func tr(_ key: String, _ args: CVarArg...) -> String {
        let format = NSLocalizedString(key, tableName: nil, bundle: .main, value: key, comment: "")
        guard !args.isEmpty else { return format }
        return String(format: format, locale: Locale.current, arguments: args)
    }
}
