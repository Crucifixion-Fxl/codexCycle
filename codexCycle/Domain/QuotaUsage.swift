import Foundation

enum QuotaWindow: String, CaseIterable, Codable {
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

struct QuotaUsageReading: Codable, Equatable {
    let remainingPercent: Int
    let resetsAt: Date?
    let fetchedAt: Date
}

struct QuotaUsageSnapshot: Equatable {
    let fiveHour: QuotaUsageReading?
    let weekly: QuotaUsageReading?

    subscript(window: QuotaWindow) -> QuotaUsageReading? {
        switch window {
        case .fiveHour:
            return fiveHour
        case .weekly:
            return weekly
        }
    }

    var isEmpty: Bool {
        fiveHour == nil && weekly == nil
    }

    var earliestResetAt: Date? {
        [fiveHour?.resetsAt, weekly?.resetsAt]
            .compactMap { $0 }
            .min()
    }

    func removingExpiredReadings(at now: Date) -> QuotaUsageSnapshot? {
        let filtered = QuotaUsageSnapshot(
            fiveHour: validReading(fiveHour, at: now),
            weekly: validReading(weekly, at: now)
        )
        return filtered.isEmpty ? nil : filtered
    }

    private func validReading(
        _ reading: QuotaUsageReading?,
        at now: Date
    ) -> QuotaUsageReading? {
        guard let reading else { return nil }
        return reading.resetsAt.map { $0 > now } == false ? nil : reading
    }
}

struct QuotaDisplaySelection: Equatable {
    let preferredWindow: QuotaWindow
    let currentWindow: QuotaWindow?
    let currentReading: QuotaUsageReading?

    var isFallback: Bool {
        currentWindow != nil && currentWindow != preferredWindow
    }

    init(
        preferredWindow: QuotaWindow,
        snapshot: QuotaUsageSnapshot?
    ) {
        self.preferredWindow = preferredWindow

        if let preferredReading = snapshot?[preferredWindow] {
            currentWindow = preferredWindow
            currentReading = preferredReading
            return
        }

        let fallbackWindow = QuotaWindow.allCases.first {
            $0 != preferredWindow && snapshot?[$0] != nil
        }
        currentWindow = fallbackWindow
        currentReading = fallbackWindow.flatMap { snapshot?[$0] }
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
