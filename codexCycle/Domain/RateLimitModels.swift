import Foundation

struct GetAccountRateLimitsResult: Decodable, Equatable {
    let rateLimits: RateLimitSnapshot
    let rateLimitsByLimitId: [String: RateLimitSnapshot]?
}

struct RateLimitSnapshot: Decodable, Equatable {
    let limitId: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
}

struct RateLimitWindow: Decodable, Equatable {
    let usedPercent: Double
    let windowDurationMins: Int64?
    let resetsAt: Int64?
}
