import Foundation

/// Tokens one request (or several) consumed, as the provider reported them.
nonisolated struct AIUsage: Codable, Equatable, Sendable {
    var input = 0
    var output = 0
    var total: Int { input + output }
    var isEmpty: Bool { input == 0 && output == 0 }

    static func + (lhs: AIUsage, rhs: AIUsage) -> AIUsage { AIUsage(input: lhs.input + rhs.input, output: lhs.output + rhs.output) }
    static func += (lhs: inout AIUsage, rhs: AIUsage) { lhs = lhs + rhs }
}

/// Collects usage across the concurrent requests of one operation.
nonisolated final class UsageMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = AIUsage()
    var usage: AIUsage { lock.lock(); defer { lock.unlock() }; return stored }
    func add(_ usage: AIUsage) { lock.lock(); stored += usage; lock.unlock() }
}

/// Price per million tokens, in the service's own billing currency.
nonisolated struct AIPrice: Codable, Equatable, Sendable {
    var input: Double
    var output: Double
    func cost(_ usage: AIUsage) -> Double { (Double(usage.input) * input + Double(usage.output) * output) / 1_000_000 }
}

/// What each saved service has consumed: this calendar month (the period a
/// spending limit applies to) and in total. Costs are added at the price that
/// was current when the tokens were used, so a later price change or discount
/// never rewrites the past.
nonisolated struct AIUsageLedger: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var month = ""
        var monthUsage = AIUsage()
        var monthCost = 0.0
        var totalUsage = AIUsage()
        var totalCost = 0.0
    }
    private(set) var services: [String: Entry] = [:]

    static func month(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    /// The entry as of `now`: a new month starts its monthly figures at zero.
    func entry(for service: UUID, now: Date = Date()) -> Entry {
        var entry = services[service.uuidString] ?? Entry()
        let month = Self.month(now)
        if entry.month != month { entry.month = month; entry.monthUsage = AIUsage(); entry.monthCost = 0 }
        return entry
    }

    mutating func record(_ usage: AIUsage, service: UUID, price: AIPrice?, now: Date = Date()) {
        guard !usage.isEmpty else { return }
        var entry = entry(for: service, now: now)
        let cost = price?.cost(usage) ?? 0
        entry.monthUsage += usage; entry.totalUsage += usage
        entry.monthCost += cost; entry.totalCost += cost
        services[service.uuidString] = entry
    }

    mutating func reset(_ service: UUID) { services[service.uuidString] = nil }

    /// Keep the larger figures of two copies (the app and its Share extension
    /// each write their own): counters only ever grow within a month.
    mutating func merge(_ other: AIUsageLedger) {
        for (id, theirs) in other.services {
            guard let mine = services[id] else { services[id] = theirs; continue }
            if theirs.month > mine.month || (theirs.month == mine.month && theirs.totalUsage.total > mine.totalUsage.total) { services[id] = theirs }
        }
    }
}
