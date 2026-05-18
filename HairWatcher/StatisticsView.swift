import SwiftUI
import Charts

struct StatisticsView: View {
    @ObservedObject private var history = TouchHistoryStore.shared
    @ObservedObject private var notifications = NotificationManager.shared
    @State private var selectedKind: TouchKind = .hair

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Picker("Kind", selection: $selectedKind) {
                    Text("Hair").tag(TouchKind.hair)
                    Text("Face").tag(TouchKind.face)
                }
                .pickerStyle(.segmented)

                if history.isEmpty(kind: selectedKind) {
                    emptyState
                } else {
                    summaryCards
                    dayList
                }
                privacyNote
            }
            .padding(16)
        }
        .id("\(history.revision)-\(selectedKind.rawValue)")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.bar")
                .imageScale(.large)
            VStack(alignment: .leading, spacing: 2) {
                Text("Statistics").font(.headline)
                Text(selectedKind == .hair
                     ? "Hair touches per day and when they happened."
                     : "Face touches per day and when they happened.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var summaryCards: some View {
        HStack(spacing: 12) {
            summaryCard(
                title: "Today",
                value: "\(todayDisplayCount)",
                subtitle: "catches"
            )
            summaryCard(
                title: "Last 7 days",
                value: "\(history.totalCount(inLastDays: 7, kind: selectedKind))",
                subtitle: "catches"
            )
            summaryCard(
                title: "Last 30 days",
                value: "\(history.totalCount(inLastDays: 30, kind: selectedKind))",
                subtitle: "catches"
            )
        }
    }

    private var todayDisplayCount: Int {
        let stored = history.count(on: Date(), kind: selectedKind)
        let legacy = selectedKind == .hair ? notifications.todayHairCount : notifications.todayFaceCount
        return max(stored, legacy)
    }

    private func summaryCard(title: String, value: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold))
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private var dayList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("By day")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            ForEach(history.daySummaries(kind: selectedKind)) { day in
                DayRow(summary: day, kind: selectedKind)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No touches recorded yet")
                .font(.headline)
            Text(selectedKind == .hair
                 ? "Stats appear after HairWatcher catches you touching your hair."
                 : "Stats appear after HairWatcher catches you touching your face.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var privacyNote: some View {
        Text("Touch times are stored on this Mac only. No photos or video are saved.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private struct DayRow: View {
    let summary: DaySummary
    let kind: TouchKind
    @ObservedObject private var history = TouchHistoryStore.shared

    private var events: [Date] {
        history.events(on: summary.date, kind: kind)
    }

    private var hourlyBuckets: [Int] {
        history.hourlyBuckets(on: summary.date, kind: kind)
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 14) {
                if summary.hasUntimestampedCatches {
                    Text("Some earlier catches today weren't time-stamped.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if events.isEmpty && summary.hasUntimestampedCatches {
                    Text("No exact times recorded yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    hourlyChart
                    exactTimesList
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Text(dayLabel)
                    .font(.callout)
                Spacer()
                Text("\(summary.count)")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(summary.count == 1 ? "catch" : "catches")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private var dayLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(summary.date) { return "Today" }
        if cal.isDateInYesterday(summary.date) { return "Yesterday" }
        return summary.date.formatted(date: .abbreviated, time: .omitted)
    }

    private var hourlyChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("By hour")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            Chart(hourlyData) { item in
                BarMark(
                    x: .value("Hour", item.hour),
                    y: .value("Count", item.count)
                )
                .foregroundStyle(Color.accentColor.opacity(0.75))
            }
            .chartYAxis {
                AxisMarks(position: .leading)
            }
            .chartXAxis {
                AxisMarks(values: [0, 6, 12, 18]) { value in
                    if let hour = value.as(Int.self) {
                        AxisValueLabel(hourAxisLabel(hour))
                    }
                }
            }
            .frame(height: 140)
        }
    }

    private var hourlyData: [HourBucket] {
        (0..<24).map { hour in
            HourBucket(hour: hour, count: hourlyBuckets[hour])
        }
    }

    private func hourAxisLabel(_ hour: Int) -> String {
        switch hour {
        case 0: return "12a"
        case 6: return "6a"
        case 12: return "12p"
        case 18: return "6p"
        default: return ""
        }
    }

    private var exactTimesList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Exact times")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            if events.isEmpty {
                Text("—")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(events, id: \.timeIntervalSince1970) { event in
                        HStack(spacing: 6) {
                            Image(systemName: "clock")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(event.formatted(date: .omitted, time: .shortened))
                                .font(.callout)
                        }
                    }
                }
            }
        }
    }
}

private struct HourBucket: Identifiable {
    let hour: Int
    let count: Int

    var id: Int { hour }
}
