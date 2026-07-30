import Foundation

enum RelativeTimeText {
    static func countdown(
        to date: Date?,
        now: Date = Date(),
        localization: AppLocalization = AppLocalization(language: .english)
    ) -> String {
        guard let date else {
            return "—"
        }

        let totalSeconds = max(0, Int(date.timeIntervalSince(now)))
        guard totalSeconds >= 60 else {
            return localization.text("relative.less_than_one_minute")
        }

        let totalMinutes = totalSeconds / 60
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60

        if days > 0 {
            let dayText = localization.unit(
                days,
                singularKey: "unit.day.one",
                pluralKey: "unit.day.other"
            )
            guard hours > 0 else { return dayText }
            let hourText = localization.unit(
                hours,
                singularKey: "unit.hour.one",
                pluralKey: "unit.hour.other"
            )
            return "\(dayText) \(hourText)"
        }

        if hours > 0 {
            let hourText = localization.unit(
                hours,
                singularKey: "unit.hour.one",
                pluralKey: "unit.hour.other"
            )
            guard minutes > 0 else { return hourText }
            let minuteText = localization.unit(
                minutes,
                singularKey: "unit.minute.one",
                pluralKey: "unit.minute.other"
            )
            return "\(hourText) \(minuteText)"
        }

        return localization.unit(
            minutes,
            singularKey: "unit.minute.one",
            pluralKey: "unit.minute.other"
        )
    }

    static func since(
        _ date: Date,
        now: Date = Date(),
        localization: AppLocalization = AppLocalization(language: .english)
    ) -> String {
        let totalSeconds = max(0, Int(now.timeIntervalSince(date)))
        if totalSeconds < 60 {
            return localization.text("relative.just_now")
        }

        let totalMinutes = totalSeconds / 60
        let relativeText: String
        if totalMinutes < 60 {
            relativeText = localization.unit(
                totalMinutes,
                singularKey: "unit.minute.one",
                pluralKey: "unit.minute.other"
            )
        } else {
            let totalHours = totalMinutes / 60
            if totalHours < 24 {
                relativeText = localization.unit(
                    totalHours,
                    singularKey: "unit.hour.one",
                    pluralKey: "unit.hour.other"
                )
            } else {
                relativeText = localization.unit(
                    totalHours / 24,
                    singularKey: "unit.day.one",
                    pluralKey: "unit.day.other"
                )
            }
        }

        return localization.format("relative.ago", relativeText)
    }
}
