import Foundation
import UserNotifications

/// Posts macOS notifications when a hair-touch event is detected, with a
/// per-event cooldown gate so we never spam the user.
///
/// Counts every detected event for the day (independent of cooldown) so the
/// menu bar can show "today's catches" honestly.
@MainActor
final class NotificationManager: ObservableObject {
    static let shared = NotificationManager()

    private let identifier = "com.hairwatcher.touch"

    @Published private(set) var todayCount: Int = 0

    private var lastFiredAt: Date?
    private var todayDate: String = NotificationManager.dayKey(for: Date())

    private enum Key {
        static let count = "todayCount"
        static let date = "todayDate"
    }

    private init() {
        loadCounters()
    }

    /// Asks for `.alert + .sound` permission. Returns the granted state.
    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    /// Records a touch event and (subject to cooldown) posts a notification.
    func recordTouchEvent(cooldownSeconds: Int) {
        rolloverIfNeeded()
        todayCount += 1
        persistCounters()

        let now = Date()
        TouchHistoryStore.shared.recordEvent(at: now)
        if let last = lastFiredAt,
           now.timeIntervalSince(last) < TimeInterval(cooldownSeconds) {
            return
        }
        lastFiredAt = now

        let content = UNMutableNotificationContent()
        content.title = "Hands off your hair"
        content.body = todayCount == 1
            ? "Caught you in the act."
            : "You've done this \(todayCount) times today."
        content.sound = .default

        // Stable identifier means the latest notification replaces any prior
        // pending one in Notification Center, so we never accumulate clutter.
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    func resetTodayCount() {
        todayCount = 0
        todayDate = Self.dayKey(for: Date())
        persistCounters()
        TouchHistoryStore.shared.clearDay(Date())
    }

    private func rolloverIfNeeded() {
        let key = Self.dayKey(for: Date())
        if key != todayDate {
            todayDate = key
            todayCount = 0
        }
    }

    private func loadCounters() {
        let defaults = UserDefaults.standard
        todayDate = defaults.string(forKey: Key.date) ?? Self.dayKey(for: Date())
        todayCount = defaults.integer(forKey: Key.count)
        rolloverIfNeeded()
    }

    private func persistCounters() {
        let defaults = UserDefaults.standard
        defaults.set(todayDate, forKey: Key.date)
        defaults.set(todayCount, forKey: Key.count)
    }

    private static func dayKey(for date: Date) -> String {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(comps.year ?? 0)-\(comps.month ?? 0)-\(comps.day ?? 0)"
    }
}
