import Foundation

enum AppLanguage: String, CaseIterable, Equatable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"
}

struct AppLocalization {
    let language: AppLanguage

    private let bundle: Bundle

    init(language: AppLanguage, bundle: Bundle = .main) {
        self.language = language

        if
            let path = bundle.path(
                forResource: language.rawValue,
                ofType: "lproj"
            ),
            let localizedBundle = Bundle(path: path)
        {
            self.bundle = localizedBundle
        } else {
            self.bundle = bundle
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
            locale: Locale(identifier: language.rawValue),
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
