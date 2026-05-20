import Foundation

struct DaySummary: Identifiable, Equatable {
    let id: String
    let date: Date
    let count: Int
    let hasUntimestampedCatches: Bool
}

private struct TouchRecord: Codable, Equatable {
    let t: TimeInterval
    let k: String
}

@MainActor
final class TouchHistoryStore: ObservableObject {
    static let shared = TouchHistoryStore()

    private static let retentionDays = 365

    private enum Key {
        static let timestamps = "touchEventTimestamps"
        static let records = "touchEventRecords"
    }

    @Published private(set) var revision = 0

    private var records: [TouchRecord] = []
    private let calendar = Calendar.current

    private init() {
        load()
        pruneOldEntries()
    }

    func recordEvent(kind: TouchKind, at date: Date = Date()) {
        records.append(TouchRecord(t: date.timeIntervalSince1970, k: kind.rawValue))
        pruneOldEntries()
        persist()
        revision += 1
    }

    func clearDay(_ day: Date, kind: TouchKind) {
        let key = Self.dayKey(for: day, calendar: calendar)
        records.removeAll { record in
            record.k == kind.rawValue
                && Self.dayKey(for: Date(timeIntervalSince1970: record.t), calendar: calendar) == key
        }
        persist()
        revision += 1
    }

    func daySummaries(kind: TouchKind) -> [DaySummary] {
        var grouped: [String: [TouchRecord]] = [:]
        for record in records where record.k == kind.rawValue {
            let key = Self.dayKey(for: Date(timeIntervalSince1970: record.t), calendar: calendar)
            grouped[key, default: []].append(record)
        }

        var summaries: [DaySummary] = grouped.map { key, dayRecords in
            let date = Self.startOfDay(forKey: key, calendar: calendar) ?? Date()
            let count = displayCount(kind: kind, dayKey: key, timestampCount: dayRecords.count)
            return DaySummary(
                id: "\(kind.rawValue)-\(key)",
                date: date,
                count: count,
                hasUntimestampedCatches: count > dayRecords.count
            )
        }

        let todayKey = Self.dayKey(for: Date(), calendar: calendar)
        if summaries.first(where: { $0.id == "\(kind.rawValue)-\(todayKey)" }) == nil {
            let legacy = legacyOrphanCount(kind: kind, forDayKey: todayKey)
            if legacy > 0 {
                summaries.append(DaySummary(
                    id: "\(kind.rawValue)-\(todayKey)",
                    date: calendar.startOfDay(for: Date()),
                    count: legacy,
                    hasUntimestampedCatches: true
                ))
            }
        }

        return summaries.sorted { $0.date > $1.date }
    }

    func events(on day: Date, kind: TouchKind) -> [Date] {
        let key = Self.dayKey(for: day, calendar: calendar)
        return records
            .filter { record in
                record.k == kind.rawValue
                    && Self.dayKey(for: Date(timeIntervalSince1970: record.t), calendar: calendar) == key
            }
            .map { Date(timeIntervalSince1970: $0.t) }
            .sorted()
    }

    func hourlyBuckets(on day: Date, kind: TouchKind) -> [Int] {
        var buckets = Array(repeating: 0, count: 24)
        for event in events(on: day, kind: kind) {
            let hour = calendar.component(.hour, from: event)
            if hour >= 0, hour < 24 {
                buckets[hour] += 1
            }
        }
        return buckets
    }

    func count(on day: Date, kind: TouchKind) -> Int {
        let key = Self.dayKey(for: day, calendar: calendar)
        return displayCount(
            kind: kind,
            dayKey: key,
            timestampCount: events(on: day, kind: kind).count
        )
    }

    func totalCount(inLastDays days: Int, kind: TouchKind) -> Int {
        guard days > 0 else { return 0 }
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: Date()))!
        return daySummaries(kind: kind)
            .filter { $0.date >= start }
            .reduce(0) { $0 + $1.count }
    }

    func isEmpty(kind: TouchKind) -> Bool {
        daySummaries(kind: kind).isEmpty
    }

    private func load() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Key.records),
           let decoded = try? JSONDecoder().decode([TouchRecord].self, from: data) {
            records = decoded
            return
        }
        if let data = defaults.data(forKey: Key.timestamps),
           let legacy = try? JSONDecoder().decode([TimeInterval].self, from: data) {
            records = legacy.map { TouchRecord(t: $0, k: TouchKind.hair.rawValue) }
            persist()
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: Key.records)
        }
    }

    private func pruneOldEntries() {
        guard let cutoff = calendar.date(
            byAdding: .day,
            value: -Self.retentionDays,
            to: calendar.startOfDay(for: Date())
        ) else { return }
        let cutoffInterval = cutoff.timeIntervalSince1970
        let before = records.count
        records.removeAll { $0.t < cutoffInterval }
        if records.count != before {
            persist()
        }
    }

    private func displayCount(kind: TouchKind, dayKey: String, timestampCount: Int) -> Int {
        max(timestampCount, legacyOrphanCount(kind: kind, forDayKey: dayKey))
    }

    private func legacyOrphanCount(kind: TouchKind, forDayKey dayKey: String) -> Int {
        guard kind == .hair else { return 0 }
        let todayKey = Self.dayKey(for: Date(), calendar: calendar)
        guard dayKey == todayKey else { return 0 }
        let recorded = records.filter {
            $0.k == TouchKind.hair.rawValue
                && Self.dayKey(for: Date(timeIntervalSince1970: $0.t), calendar: calendar) == todayKey
        }.count
        let legacy = NotificationManager.shared.todayHairCount
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
