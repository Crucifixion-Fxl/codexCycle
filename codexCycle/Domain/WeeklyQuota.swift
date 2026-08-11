import Foundation

struct WeeklyQuotaReading: Equatable {
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
