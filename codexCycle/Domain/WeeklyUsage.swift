import Foundation

struct WeeklyUsageReading: Codable, Equatable {
    let remainingPercent: Int
    let resetsAt: Date?
    let fetchedAt: Date
}

enum WeeklyUsageError: Error, Equatable {
    case noMainCodexBucket
    case noWeeklyWindow
}

enum WeeklyUsageParser {
    static let weeklyWindowMinutes: Int64 = 10_080

    static func parse(
        _ response: GetAccountRateLimitsResult,
        fetchedAt: Date = Date()
    ) throws -> WeeklyUsageReading {
        let mainBucket = response.rateLimitsByLimitId?["codex"]
            ?? (response.rateLimits.limitId == "codex" ? response.rateLimits : nil)

        guard let mainBucket else {
            throw WeeklyUsageError.noMainCodexBucket
        }

        let weeklyWindow = [mainBucket.primary, mainBucket.secondary]
            .compactMap { $0 }
            .first { $0.windowDurationMins == weeklyWindowMinutes }

        guard let weeklyWindow else {
            throw WeeklyUsageError.noWeeklyWindow
        }

        let remaining = Int(floor(100 - weeklyWindow.usedPercent))
        let clamped = min(100, max(0, remaining))
        let resetDate = weeklyWindow.resetsAt.map {
            Date(timeIntervalSince1970: TimeInterval($0))
        }

        return WeeklyUsageReading(
            remainingPercent: clamped,
            resetsAt: resetDate,
            fetchedAt: fetchedAt
        )
    }
}

enum UsageLevel: Equatable {
    case sufficient
    case low
    case critical

    init(remainingPercent: Int) {
        switch remainingPercent {
        case 50...:
            self = .sufficient
        case 20..<50:
            self = .low
        default:
            self = .critical
        }
    }
}

struct RGBComponents: Equatable {
    let red: Double
    let green: Double
    let blue: Double
}

enum UsageGradient {
    static let red = RGBComponents(red: 0.96, green: 0.20, blue: 0.24)
    static let yellow = RGBComponents(red: 1.00, green: 0.78, blue: 0.12)
    static let green = RGBComponents(red: 0.18, green: 0.80, blue: 0.40)

    static func color(at percent: Double) -> RGBComponents {
        let value = min(100, max(0, percent))

        if value <= 20 {
            return interpolate(from: red, to: yellow, amount: value / 20)
        }

        if value < 50 {
            return interpolate(from: yellow, to: green, amount: (value - 20) / 30)
        }

        return green
    }

    private static func interpolate(
        from start: RGBComponents,
        to end: RGBComponents,
        amount: Double
    ) -> RGBComponents {
        RGBComponents(
            red: start.red + (end.red - start.red) * amount,
            green: start.green + (end.green - start.green) * amount,
            blue: start.blue + (end.blue - start.blue) * amount
        )
    }
}
