import Foundation

struct AppLocalization {
    private let bundle: Bundle
    private let locale: Locale

    init(bundle: Bundle = .main, locale: Locale = .current) {
        self.bundle = bundle
        self.locale = locale
    }

    func text(_ key: String) -> String {
        NSLocalizedString(
            key,
            tableName: nil,
            bundle: bundle,
            value: key,
            comment: ""
        )
    }

    func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(
            format: text(key),
            locale: locale,
            arguments: arguments
        )
    }

    func unit(
        _ value: Int,
        singularKey: String,
        pluralKey: String
    ) -> String {
        format(value == 1 ? singularKey : pluralKey, value)
    }
}
