import Foundation

/// 한 개의 사용량 창(예: 5시간 창, 주간 창).
struct UsageWindow {
    let label: String
    let usedPercent: Double      // 0–100
    let resetsAt: Date?

    var remainingPercent: Double { min(100, max(0, 100 - usedPercent)) }
}

/// 프로바이더 하나의 현재 상태.
struct ProviderUsage {
    var name: String
    var short: String            // 메뉴 막대용 약칭
    var windows: [UsageWindow] = []
    var extras: [String] = []
    var error: String?
    var stale = false            // 마지막 요청은 실패했고 이전 데이터를 보여주는 중
    var manual = false           // Grok처럼 수동 타이머 기반
    var fetchedAt: Date?
}

enum FetchError: LocalizedError {
    case auth(String)
    case rateLimited(until: Date)
    case http(Int)
    case parse
    case missing(String)

    var errorDescription: String? {
        switch self {
        case .auth(let m), .missing(let m): return m
        case .rateLimited(let d): return "서버 요청 제한 — \(Fmt.clock(d)) 이후 자동 재시도"
        case .http(let c): return "HTTP \(c) 오류"
        case .parse: return "응답 형식을 읽을 수 없음"
        }
    }
}

enum Fmt {
    static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        // 마이크로초(6자리) 등 포매터가 못 읽는 소수점 초를 제거하고 재시도
        let trimmed = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: trimmed)
    }

    /// "3시간 12분 후"
    static func countdown(_ d: Date) -> String {
        let s = Int(d.timeIntervalSinceNow)
        if s <= 0 { return "곧 리셋" }
        let days = s / 86_400, h = (s % 86_400) / 3_600, m = (s % 3_600) / 60
        if days > 0 { return "\(days)일 \(h)시간 후" }
        if h > 0 { return "\(h)시간 \(m)분 후" }
        return "\(max(m, 1))분 후"
    }

    /// 메뉴 막대 2줄용 아주 짧은 남은 시간: "5d", "2h", "45m"
    static func tinyCountdown(_ d: Date) -> String {
        let s = max(0, Int(d.timeIntervalSinceNow))
        if s >= 86_400 { return "\(s / 86_400)d" }
        if s >= 3_600 { return "\(s / 3_600)h" }
        return "\(max(1, s / 60))m"
    }

    /// "3시간 12분" (리셋까지 남은 시간, '후' 없이)
    static func remaining(_ d: Date) -> String {
        let s = Int(d.timeIntervalSinceNow)
        if s <= 0 { return "곧" }
        let days = s / 86_400, h = (s % 86_400) / 3_600, m = (s % 3_600) / 60
        if days > 0 { return "\(days)일 \(h)시간" }
        if h > 0 { return "\(h)시간 \(m)분" }
        return "\(max(m, 1))분"
    }

    /// 메뉴 막대용 짧은 카운트다운: "2h13m", "3d4h"
    static func shortCountdown(_ d: Date) -> String {
        let s = max(0, Int(d.timeIntervalSinceNow))
        let days = s / 86_400, h = (s % 86_400) / 3_600, m = (s % 3_600) / 60
        if days > 0 { return "\(days)d\(h)h" }
        if h > 0 { return "\(h)h\(m)m" }
        return "\(max(m, 1))m"
    }

    /// "오후 10:40" / "내일 오전 9:00" / "10/6(월) 오후 2:00"
    static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        let cal = Calendar.current
        if cal.isDateInToday(d) { f.dateFormat = "a h:mm" }
        else if cal.isDateInTomorrow(d) { f.dateFormat = "'내일' a h:mm" }
        else { f.dateFormat = "M/d(E) a h:mm" }
        return f.string(from: d)
    }

    /// "2h30m", "90m", "1:45", "3"(시간), "2시간 30분", "1d" → 초
    static func parseDuration(_ raw: String) -> TimeInterval? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if s.isEmpty { return nil }
        if let n = Double(s) { return n * 3_600 }
        let colon = s.split(separator: ":")
        if colon.count == 2, let h = Double(colon[0]), let m = Double(colon[1]) { return h * 3_600 + m * 60 }
        let units: [(String, Double)] = [("d", 86_400), ("일", 86_400), ("h", 3_600), ("시간", 3_600), ("m", 60), ("분", 60)]
        var total = 0.0
        let re = try! NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)\s*(d|일|h|시간|m|분)"#)
        let ns = s as NSString
        for match in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let n = Double(ns.substring(with: match.range(at: 1))) ?? 0
            let unit = ns.substring(with: match.range(at: 2))
            total += n * (units.first { $0.0 == unit }?.1 ?? 0)
        }
        return total > 0 ? total : nil
    }
}
