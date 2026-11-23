import SwiftUI

// MARK: - ScheduleMatrixView — "Whole week" + per-day tabs (loadScheduleMatrix in app.js).
// prayer_schedule.day_of_week: 0 = Monday … 6 = Sunday.
// Two scopes share this UI:
// - .playback → the athan schedule matrix (server or local audio playback)
// - .ios      → the iOS notification matrix (local only — which athans alert
//               this iPhone; never synced, unaffected by the playback matrix)

struct ScheduleMatrixView: View {
    enum Scope { case playback, ios }

    @EnvironmentObject var store: AppStore
    let theme: AppTheme
    var scope: Scope = .playback
    @State private var tab: Int = -1   // -1 = Whole week, 0..6 = Mon..Sun

    private let tabNames = ["Whole week", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    /// Accessibility id prefix: "sched" (playback) / "iossched" (iOS alerts).
    private var idp: String { scope == .ios ? "iossched" : "sched" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Tab bar
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(-1..<7, id: \.self) { i in
                        Button { tab = i } label: {
                            Text(tabNames[i + 1])
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .foregroundStyle(tab == i ? .white : Color(hex: 0x2A6DD1))
                                .background(tab == i ? Color(hex: 0x2A6DD1) : .clear)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(Color(hex: 0x2A6DD1), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("\(idp)Tab-\(i)")
                    }
                }
            }

            if tab == -1 {
                wholeWeekContent
            } else {
                dayContent(tab)
            }
        }
        .task { await store.loadSchedule() }
        // No identifier on the root VStack: an id set on a container is
        // inherited by every descendant and would clobber the row ids
        // (sched-week-*, iossched-*) applied on the WebToggles below.
    }

    // MARK: Whole week tab

    private var wholeWeekContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("By weekdays")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(hex: 0x2A6DD1))
                .padding(.bottom, 8)

            matrixRow("All athans", id: "\(idp)-all", isOn: allEnabled) { v in
                if scope == .ios {
                    for d in 0..<7 { store.bulkIOSScheduleDay(d, v) }
                } else {
                    Task { for d in 0..<7 { await store.bulkScheduleDay(d, v) } }
                }
            }
            divider

            ForEach(AC.mainPrayers, id: \.self) { prayer in
                matrixRow(AC.displayPrayerName(prayer), id: "\(idp)-week-\(prayer)",
                          isOn: prayerAllDays(prayer)) { v in
                    setPrayer(prayer, v)
                }
            }
        }
    }

    // MARK: Single day tab

    private func dayContent(_ day: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(AC.weekdayNames[day])
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(hex: 0x2A6DD1))
                .padding(.bottom, 8)

            matrixRow("Whole day", id: "\(idp)-day-all", isOn: dayAllEnabled(day)) { v in
                setDay(day, v)
            }
            divider

            ForEach(AC.mainPrayers, id: \.self) { prayer in
                matrixRow(AC.displayPrayerName(prayer), id: "\(idp)-\(day)-\(prayer)",
                          isOn: cellEnabled(prayer, day)) { v in
                    setCell(prayer, day, v)
                }
            }
        }
    }

    // MARK: Scope routing — reads

    private var rows: [ScheduleEntry] {
        scope == .ios ? store.iosSchedule : store.schedule
    }
    private func cellOn(_ p: String, _ d: Int) -> Bool {
        scope == .ios ? store.iosScheduleEnabled(p, d) : (store.scheduleEnabled(p, d) ?? true)
    }

    // MARK: Scope routing — writes

    private func setCell(_ p: String, _ d: Int, _ v: Bool) {
        if scope == .ios {
            store.setIOSSchedule(p, d, v)
        } else {
            Task { await store.setSchedule(p, d, v) }
        }
    }
    private func setPrayer(_ p: String, _ v: Bool) {
        if scope == .ios {
            store.bulkIOSSchedulePrayer(p, v)
        } else {
            Task { await store.bulkSchedulePrayer(p, v) }
        }
    }
    private func setDay(_ d: Int, _ v: Bool) {
        if scope == .ios {
            store.bulkIOSScheduleDay(d, v)
        } else {
            Task { await store.bulkScheduleDay(d, v) }
        }
    }

    // MARK: Helpers

    private var divider: some View {
        Rectangle().fill(Color(hex: 0x2A6DD1).opacity(0.4)).frame(height: 1)
            .padding(.vertical, 4)
    }

    private var allEnabled: Binding<Bool> {
        Binding(
            get: { rows.filter { AC.mainPrayers.contains($0.prayer_name) }.allSatisfy { $0.enabled == 1 } },
            set: { _ in })
    }
    private func prayerAllDays(_ p: String) -> Binding<Bool> {
        Binding(
            get: { rows.filter { $0.prayer_name == p }.allSatisfy { $0.enabled == 1 } },
            set: { _ in })
    }
    private func dayAllEnabled(_ day: Int) -> Binding<Bool> {
        Binding(
            get: { rows.filter { $0.day_of_week == day && AC.mainPrayers.contains($0.prayer_name) }.allSatisfy { $0.enabled == 1 } },
            set: { _ in })
    }
    private func cellEnabled(_ p: String, _ day: Int) -> Binding<Bool> {
        Binding(get: { cellOn(p, day) }, set: { _ in })
    }

    private func matrixRow(_ title: String, id: String, isOn: Binding<Bool>,
                           action: @escaping (Bool) -> Void) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.sheetText)
            Spacer()
            WebToggle(theme: theme, isOn: Binding(
                get: { isOn.wrappedValue },
                set: { v in action(v) }))
            .accessibilityIdentifier(id)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(hex: 0x2A6DD1).opacity(0.2)).frame(height: 1)
        }
    }
}
