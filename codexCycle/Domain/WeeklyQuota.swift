import Foundation

enum QuotaWindow: String, CaseIterable {
    case fiveHour
    case weekly

    var durationMinutes: Int64 {
        switch self {
        case .fiveHour:
            return 300
        case .weekly:
            return 10_080
        }
    }
}

struct QuotaUsageReading: Equatable {
    let remainingPercent: Int
    let resetsAt: Date?
    let fetchedAt: Date

    func isValid(at now: Date) -> Bool {
        resetsAt.map { $0 > now } != false
    }
}

struct QuotaUsageSnapshot: Equatable {
    let fiveHour: QuotaUsageReading?
    let weekly: QuotaUsageReading?

    var isEmpty: Bool {
        fiveHour == nil && weekly == nil
    }

    var earliestResetAt: Date? {
        [fiveHour?.resetsAt, weekly?.resetsAt]
            .compactMap { $0 }
            .min()
    }

    var latestFetchedAt: Date? {
        [fiveHour?.fetchedAt, weekly?.fetchedAt]
            .compactMap { $0 }
            .max()
    }

    func removingExpiredReadings(at now: Date) -> QuotaUsageSnapshot? {
        let snapshot = QuotaUsageSnapshot(
            fiveHour: fiveHour.flatMap { $0.isValid(at: now) ? $0 : nil },
            weekly: weekly.flatMap { $0.isValid(at: now) ? $0 : nil }
        )
        return snapshot.isEmpty ? nil : snapshot
    }
}

enum QuotaUsageError: Error, Equatable {
    case noMainCodexBucket
    case noSupportedWindows
}

enum QuotaUsageParser {
    static func parse(
        _ response: GetAccountRateLimitsResult,
        fetchedAt: Date = Date()
    ) throws -> QuotaUsageSnapshot {
        let mainBucket = response.rateLimitsByLimitId?["codex"]
            ?? (response.rateLimits.limitId == "codex" ? response.rateLimits : nil)

        guard let mainBucket else {
            throw QuotaUsageError.noMainCodexBucket
        }

        let windows = [mainBucket.primary, mainBucket.secondary].compactMap { $0 }
        let snapshot = QuotaUsageSnapshot(
            fiveHour: reading(
                from: windows.first {
                    $0.windowDurationMins == QuotaWindow.fiveHour.durationMinutes
                },
                fetchedAt: fetchedAt
            ),
            weekly: reading(
                from: windows.first {
                    $0.windowDurationMins == QuotaWindow.weekly.durationMinutes
                },
                fetchedAt: fetchedAt
            )
        )

        guard !snapshot.isEmpty else {
            throw QuotaUsageError.noSupportedWindows
        }
        return snapshot
    }

    private static func reading(
        from window: RateLimitWindow?,
        fetchedAt: Date
    ) -> QuotaUsageReading? {
        guard let window else { return nil }

        let remaining = Int(floor(100 - window.usedPercent))
        return QuotaUsageReading(
            remainingPercent: min(100, max(0, remaining)),
            resetsAt: window.resetsAt.map {
                Date(timeIntervalSince1970: TimeInterval($0))
            },
            fetchedAt: fetchedAt
        )
    }
}
