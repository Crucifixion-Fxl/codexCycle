import Foundation

struct WeeklyQuotaReading: Codable, Equatable {
    let remainingPercent: Int
    let resetsAt: Date?
    let fetchedAt: Date

    func isValid(at now: Date) -> Bool {
        resetsAt.map { $0 > now } != false
    }
}

enum WeeklyQuotaError: Error, Equatable {
    case noMainCodexBucket
    case weeklyWindowUnavailable
}

enum WeeklyQuotaParser {
    private static let weeklyDurationMinutes: Int64 = 10_080

    static func parse(
        _ response: GetAccountRateLimitsResult,
        fetchedAt: Date = Date()
    ) throws -> WeeklyQuotaReading {
        let mainBucket = response.rateLimitsByLimitId?["codex"]
            ?? (response.rateLimits.limitId == "codex" ? response.rateLimits : nil)

        guard let mainBucket else {
            throw WeeklyQuotaError.noMainCodexBucket
        }

        let windows = [mainBucket.primary, mainBucket.secondary].compactMap { $0 }
        guard let weekly = windows.first(where: {
            $0.windowDurationMins == weeklyDurationMinutes
        }) else {
            throw WeeklyQuotaError.weeklyWindowUnavailable
        }

        let remaining = Int(floor(100 - weekly.usedPercent))
        return WeeklyQuotaReading(
            remainingPercent: min(100, max(0, remaining)),
            resetsAt: weekly.resetsAt.map {
                Date(timeIntervalSince1970: TimeInterval($0))
            },
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
