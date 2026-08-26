import Foundation

enum AppLanguage: String, CaseIterable, Equatable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
}

struct AppLocalization {
    let language: AppLanguage

    private let bundle: Bundle
    private let locale: Locale

    init(
        language: AppLanguage = .system,
        bundle: Bundle = .main,
        locale: Locale = .current
    ) {
        self.language = language

        if language != .system,
           let path = bundle.path(forResource: language.rawValue, ofType: "lproj"),
           let localizedBundle = Bundle(path: path) {
            self.bundle = localizedBundle
            self.locale = Locale(identifier: language.rawValue)
        } else {
            self.bundle = bundle
            self.locale = locale
        }
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
