import Foundation

/// One calendar day's touch statistics.
struct DaySummary: Identifiable, Equatable {
    let id: String
    let date: Date
    let count: Int
    /// True when some catches on this day predate timestamp logging (legacy counter only).
    let hasUntimestampedCatches: Bool
}

/// Persists hair-touch event timestamps locally for statistics.
/// Camera frames are never stored — only `Date` metadata.
@MainActor
final class TouchHistoryStore: ObservableObject {
    static let shared = TouchHistoryStore()

    private static let retentionDays = 365

    private enum Key {
        static let timestamps = "touchEventTimestamps"
    }

    @Published private(set) var revision = 0

    private var timestamps: [TimeInterval] = []
    private let calendar = Calendar.current

    private init() {
        load()
        pruneOldEntries()
    }

    // MARK: - Recording

    func recordEvent(at date: Date = Date()) {
        timestamps.append(date.timeIntervalSince1970)
        pruneOldEntries()
        persist()
        revision += 1
    }

    func clearDay(_ day: Date) {
        let key = Self.dayKey(for: day, calendar: calendar)
        timestamps.removeAll { interval in
            Self.dayKey(for: Date(timeIntervalSince1970: interval), calendar: calendar) == key
        }
        persist()
        revision += 1
    }

    // MARK: - Queries

    func daySummaries() -> [DaySummary] {
        var grouped: [String: [TimeInterval]] = [:]
        for interval in timestamps {
            let key = Self.dayKey(for: Date(timeIntervalSince1970: interval), calendar: calendar)
            grouped[key, default: []].append(interval)
        }

        var summaries: [DaySummary] = grouped.map { key, intervals in
            let date = Self.startOfDay(forKey: key, calendar: calendar) ?? Date()
            let count = displayCount(dayKey: key, timestampCount: intervals.count)
            let hasUntimestamped = count > intervals.count
            return DaySummary(
                id: key,
                date: date,
                count: count,
                hasUntimestampedCatches: hasUntimestamped
            )
        }

        let todayKey = Self.dayKey(for: Date(), calendar: calendar)
        if summaries.first(where: { $0.id == todayKey }) == nil {
            let legacy = legacyOrphanCount(forDayKey: todayKey)
            if legacy > 0 {
                summaries.append(DaySummary(
                    id: todayKey,
                    date: calendar.startOfDay(for: Date()) ?? Date(),
                    count: legacy,
                    hasUntimestampedCatches: true
                ))
            }
        }

        return summaries.sorted { $0.date > $1.date }
    }

    func events(on day: Date) -> [Date] {
        let key = Self.dayKey(for: day, calendar: calendar)
        return timestamps
            .filter { Self.dayKey(for: Date(timeIntervalSince1970: $0), calendar: calendar) == key }
            .map { Date(timeIntervalSince1970: $0) }
            .sorted()
    }

    func hourlyBuckets(on day: Date) -> [Int] {
        var buckets = Array(repeating: 0, count: 24)
        for event in events(on: day) {
            let hour = calendar.component(.hour, from: event)
            if hour >= 0, hour < 24 {
                buckets[hour] += 1
            }
        }
        return buckets
    }

    func count(on day: Date) -> Int {
        let key = Self.dayKey(for: day, calendar: calendar)
        return displayCount(dayKey: key, timestampCount: events(on: day).count)
    }

    func totalCount(inLastDays days: Int) -> Int {
        guard days > 0 else { return 0 }
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: Date()))!
        return daySummaries()
            .filter { $0.date >= start }
            .reduce(0) { $0 + $1.count }
    }

    var isEmpty: Bool {
        daySummaries().isEmpty
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Key.timestamps) else { return }
        if let decoded = try? JSONDecoder().decode([TimeInterval].self, from: data) {
            timestamps = decoded
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(timestamps) {
            UserDefaults.standard.set(data, forKey: Key.timestamps)
        }
    }

    private func pruneOldEntries() {
        guard let cutoff = calendar.date(
            byAdding: .day,
            value: -Self.retentionDays,
            to: calendar.startOfDay(for: Date())
        ) else { return }
        let cutoffInterval = cutoff.timeIntervalSince1970
        let before = timestamps.count
        timestamps.removeAll { $0 < cutoffInterval }
        if timestamps.count != before {
            persist()
        }
    }

    private func displayCount(dayKey: String, timestampCount: Int) -> Int {
        max(timestampCount, legacyOrphanCount(forDayKey: dayKey))
    }

    /// Catches recorded before timestamp logging existed (today only, via NotificationManager).
    private func legacyOrphanCount(forDayKey dayKey: String) -> Int {
        let todayKey = Self.dayKey(for: Date(), calendar: calendar)
        guard dayKey == todayKey else { return 0 }
        let recorded = timestamps.filter {
            Self.dayKey(for: Date(timeIntervalSince1970: $0), calendar: calendar) == todayKey
        }.count
        let legacy = NotificationManager.shared.todayCount
        return max(0, legacy - recorded)
    }

    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(comps.year ?? 0)-\(comps.month ?? 0)-\(comps.day ?? 0)"
    }

    private static func startOfDay(forKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var comps = DateComponents()
        comps.year = parts[0]
        comps.month = parts[1]
        comps.day = parts[2]
        return calendar.date(from: comps)
    }
}
