import Foundation
import CoreFoundation

public enum UsageError: Error, Equatable, LocalizedError {
    case loginRequired, keychainAccess, invalidResponse, unavailable(Int), network, rateLimited(TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .loginRequired: return "Нужно войти в Claude Code"
        case .keychainAccess: return "Нужно разрешить чтение авторизации Claude Code"
        case .invalidResponse: return "Не удалось прочитать формат лимитов Claude"
        case .unavailable(let code): return "Сервис лимитов недоступен (HTTP \(code))"
        case .network: return "Нет связи с сервисом лимитов"
        case .rateLimited: return "Claude ограничил частоту обновления — ожидаю"
        }
    }
}

public struct UsageWindow: Equatable, Sendable {
    public let used: Double
    public let resetsAt: Date?
    public var remaining: Double { max(0, 100 - used) }
    // Round down: a nearly exhausted budget must not look more available than it is.
    public var percent: String { "\(Int(remaining.rounded(.down)))%" }
    public func isExpired(at date: Date) -> Bool { resetsAt.map { $0 <= date } ?? false }
}

public struct UsageSnapshot: Equatable, Sendable {
    public let fable: UsageWindow?
    public let opus: UsageWindow?
    public let fiveHour: UsageWindow?
    public let weekly: UsageWindow?
    public let opusUsesSharedWeek: Bool
    public let fetchedAt: Date

    public func title(at now: Date, failed: Bool = false) -> String {
        let stale = failed || now.timeIntervalSince(fetchedAt) > 300
        func value(_ window: UsageWindow?) -> String {
            guard let window, !window.isExpired(at: now), !stale else { return "—" }
            return window.percent
        }
        return "F \(value(fable)) · O \(value(opus)) · 5 \(value(fiveHour))"
    }
}

public enum UsageParser {
    public static func parse(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        guard data.count <= 1_048_576,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["error"] == nil else { throw UsageError.invalidResponse }
        let five = try window(root["five_hour"])
        let week = try window(root["seven_day"])
        var fable = try window(root["seven_day_fable"])
        var opus = try window(root["seven_day_opus"])
        var seen = Set<String>()
        if let raw = root["limits"], !(raw is NSNull) {
            guard let limits = raw as? [[String: Any]] else { throw UsageError.invalidResponse }
            for limit in limits where limit["kind"] as? String == "weekly_scoped" {
                guard let scope = limit["scope"] as? [String: Any],
                      let model = scope["model"] as? [String: Any],
                      let name = model["display_name"] as? String else { continue }
                let key = name.lowercased()
                guard key == "fable" || key == "opus" else { continue }
                guard seen.insert(key).inserted else { throw UsageError.invalidResponse }
                let value = try window(limit, valueKey: "percent")
                if key == "fable" { fable = value } else { opus = value }
            }
        }
        guard five != nil || week != nil || fable != nil || opus != nil else {
            throw UsageError.invalidResponse
        }
        return UsageSnapshot(fable: fable, opus: opus ?? week, fiveHour: five, weekly: week,
                             opusUsesSharedWeek: opus == nil && week != nil, fetchedAt: now)
    }

    private static func window(_ raw: Any?, valueKey: String = "utilization") throws -> UsageWindow? {
        guard let raw, !(raw is NSNull) else { return nil }
        guard let object = raw as? [String: Any], let number = object[valueKey] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
              number.doubleValue >= 0, number.doubleValue <= 100 else { throw UsageError.invalidResponse }
        var reset: Date?
        if let rawDate = object["resets_at"], !(rawDate is NSNull) {
            guard let date = rawDate as? String else { throw UsageError.invalidResponse }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            reset = formatter.date(from: date)
            if reset == nil { formatter.formatOptions = [.withInternetDateTime]; reset = formatter.date(from: date) }
            guard reset != nil else { throw UsageError.invalidResponse }
        }
        return UsageWindow(used: number.doubleValue, resetsAt: reset)
    }
}

public protocol UsageFetching { func fetch() async throws -> UsageSnapshot }

@MainActor
public final class UsageMonitor {
    public private(set) var snapshot: UsageSnapshot?
    public private(set) var error: UsageError?
    public private(set) var refreshing = false
    public private(set) var nextAttempt = Date.distantPast
    public var onChange: (() -> Void)?
    private let client: any UsageFetching
    private let clock: () -> Date
    private var failures = 0

    public init(client: any UsageFetching, clock: @escaping () -> Date = Date.init) {
        self.client = client; self.clock = clock
    }

    public var title: String {
        snapshot?.title(at: clock(), failed: error != nil) ?? "F — · O — · 5 —"
    }

    public func refresh(manual: Bool = false) async {
        guard !refreshing else { return }
        // Manual refresh can retry authentication/network failures but respects HTTP 429.
        let rateLimited: Bool
        if case .rateLimited = error { rateLimited = true } else { rateLimited = false }
        guard clock() >= nextAttempt || (manual && !rateLimited) else { return }
        refreshing = true; onChange?()
        defer { refreshing = false; onChange?() }
        do {
            snapshot = try await client.fetch()
            error = nil; failures = 0; nextAttempt = clock().addingTimeInterval(120)
        } catch {
            let failure = error as? UsageError ?? .network
            self.error = failure; failures += 1
            if failure == .loginRequired { snapshot = nil }
            let delay: TimeInterval
            if case .rateLimited(let retry) = failure { delay = max(120, retry) }
            else { delay = min(900, 60 * pow(2, Double(min(failures - 1, 4)))) }
            nextAttempt = clock().addingTimeInterval(delay)
        }
    }
}
