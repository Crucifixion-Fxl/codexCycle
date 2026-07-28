import Foundation

enum RelativeTimeText {
    static func countdown(to date: Date?, now: Date = Date()) -> String {
        guard let date else {
            return "—"
        }

        let totalSeconds = max(0, Int(date.timeIntervalSince(now)))
        guard totalSeconds >= 60 else {
            return "不足 1 分钟"
        }

        let totalMinutes = totalSeconds / 60
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60

        if days > 0 {
            return hours > 0 ? "\(days) 天 \(hours) 小时" : "\(days) 天"
        }

        if hours > 0 {
            return minutes > 0 ? "\(hours) 小时 \(minutes) 分钟" : "\(hours) 小时"
        }

        return "\(minutes) 分钟"
    }

    static func since(_ date: Date, now: Date = Date()) -> String {
        let totalSeconds = max(0, Int(now.timeIntervalSince(date)))
        if totalSeconds < 60 {
            return "刚刚"
        }

        let totalMinutes = totalSeconds / 60
        if totalMinutes < 60 {
            return "\(totalMinutes) 分钟前"
        }

        let totalHours = totalMinutes / 60
        if totalHours < 24 {
            return "\(totalHours) 小时前"
        }

        return "\(totalHours / 24) 天前"
    }
}
