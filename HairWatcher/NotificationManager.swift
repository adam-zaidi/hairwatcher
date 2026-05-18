import Foundation
import UserNotifications

/// Posts macOS notifications when a touch event is detected, with per-kind
/// cooldown gates so hair and face alerts do not block each other.
@MainActor
final class NotificationManager: ObservableObject {
    static let shared = NotificationManager()

    @Published private(set) var todayHairCount: Int = 0
    @Published private(set) var todayFaceCount: Int = 0

    private var lastFiredAtHair: Date?
    private var lastFiredAtFace: Date?
    private var todayDate: String = NotificationManager.dayKey(for: Date())

    private enum Key {
        static let hairCount = "todayHairCount"
        static let faceCount = "todayFaceCount"
        static let date = "todayDate"
        static let legacyCount = "todayCount"
    }

    private init() {
        loadCounters()
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    func recordTouch(kind: TouchKind, cooldownSeconds: Int) {
        rolloverIfNeeded()
        switch kind {
        case .hair: todayHairCount += 1
        case .face: todayFaceCount += 1
        }
        persistCounters()

        let now = Date()
        TouchHistoryStore.shared.recordEvent(kind: kind, at: now)

        let lastFired: Date?
        switch kind {
        case .hair: lastFired = lastFiredAtHair
        case .face: lastFired = lastFiredAtFace
        }
        if let last = lastFired,
           now.timeIntervalSince(last) < TimeInterval(cooldownSeconds) {
            return
        }

        switch kind {
        case .hair: lastFiredAtHair = now
        case .face: lastFiredAtFace = now
        }

        let content = UNMutableNotificationContent()
        switch kind {
        case .hair:
            content.title = "Hands off your hair"
            content.body = todayHairCount == 1
                ? "Caught you in the act."
                : "You've touched your hair \(todayHairCount) times today."
        case .face:
            content.title = "Hands off your face"
            content.body = todayFaceCount == 1
                ? "Caught you in the act."
                : "You've touched your face \(todayFaceCount) times today."
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "com.hairwatcher.touch.\(kind.rawValue)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    func resetToday(kind: TouchKind) {
        switch kind {
        case .hair: todayHairCount = 0
        case .face: todayFaceCount = 0
        }
        todayDate = Self.dayKey(for: Date())
        persistCounters()
        TouchHistoryStore.shared.clearDay(Date(), kind: kind)
    }

    func resetAllToday() {
        todayHairCount = 0
        todayFaceCount = 0
        todayDate = Self.dayKey(for: Date())
        persistCounters()
        TouchHistoryStore.shared.clearDay(Date(), kind: .hair)
        TouchHistoryStore.shared.clearDay(Date(), kind: .face)
    }

    /// Legacy API used when only one counter row is shown.
    var todayCount: Int { todayHairCount + todayFaceCount }

    func resetTodayCount() {
        resetAllToday()
    }

    private func rolloverIfNeeded() {
        let key = Self.dayKey(for: Date())
        if key != todayDate {
            todayDate = key
            todayHairCount = 0
            todayFaceCount = 0
        }
    }

    private func loadCounters() {
        let defaults = UserDefaults.standard
        todayDate = defaults.string(forKey: Key.date) ?? Self.dayKey(for: Date())

        if defaults.object(forKey: Key.hairCount) != nil {
            todayHairCount = defaults.integer(forKey: Key.hairCount)
            todayFaceCount = defaults.integer(forKey: Key.faceCount)
        } else {
            todayHairCount = defaults.integer(forKey: Key.legacyCount)
            todayFaceCount = 0
        }
        rolloverIfNeeded()
    }

    private func persistCounters() {
        let defaults = UserDefaults.standard
        defaults.set(todayDate, forKey: Key.date)
        defaults.set(todayHairCount, forKey: Key.hairCount)
        defaults.set(todayFaceCount, forKey: Key.faceCount)
    }

    private static func dayKey(for date: Date) -> String {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(comps.year ?? 0)-\(comps.month ?? 0)-\(comps.day ?? 0)"
    }
}
