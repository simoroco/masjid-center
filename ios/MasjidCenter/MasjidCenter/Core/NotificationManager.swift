import Foundation
import UserNotifications

// MARK: - NotificationManager — local notifications, planned in one pass.
// Three independent types, each gated by its own switch AND the master
// "iOS notifications" switch: athan alerts (iOS-only matrix), objective
// reminders, and the Friday Al Kahf recitation alert.

@MainActor
final class NotificationManager: ObservableObject {
    static let shared = NotificationManager()
    private let center = UNUserNotificationCenter.current()
    private let foregroundDelegate = ForegroundDelegate()

    private init() { center.delegate = foregroundDelegate }

    /// Water-drop sound bundled in the app (Settings → Tasbih & Objectives reminders).
    static let reminderSound = UNNotificationSoundName("water_drop.wav")

    /// iOS keeps the 64 soonest pending requests — every type shares it.
    nonisolated private static let maxReminderRequests = 30
    nonisolated private static let totalBudget = 60

    /// Everything needed to build the pending request list — pure data in, so
    /// `buildRequests` stays testable without a notification center.
    struct Plan {
        var prayers: [String: [Prayer]] = [:]
        /// iOS-only athan notification matrix — NOT the playback matrix.
        /// (prayer_name, day_of_week 0=Mon…6=Sun) -> enabled.
        var athanSlotEnabled: (String, Int) -> Bool = { _, _ in false }
        /// Per-type switch: athan alerts.
        var athanAlerts: Bool = false
        /// Server weekday mute — jsDay (0=Sun) -> 1 silences that weekday's alerts.
        var mutedWeekdays: [Int: Int] = [:]
        /// "Mute next athan" active. One-shot on the server (the very next
        /// athan, whenever it comes); whole rest of the day in standalone.
        var skipNext: Bool = false
        var skipNextOneShot: Bool = false
        var reminders: [(id: String, name: String, times: [(hour: Int, minute: Int)])] = []
        /// Per-type switch: objective reminders.
        var remindersEnabled: Bool = false
        /// Friday Al Kahf alert — non-nil when the per-type switch AND the
        /// Friday recitation setting are both on.
        var quranFriday: (hour: Int, minute: Int)? = nil
        /// Notification sound per type: "" = iOS default alert, otherwise a
        /// file name in the app bundle or Library/Sounds (UNNotificationSound).
        var athanSoundName: String = ""
        var reminderSoundName: String = ""
        var quranSoundName: String = ""
        /// Master switch ("iOS notifications").
        var masterEnabled: Bool = false
        /// Injectable clock (tests).
        var now: Date = Date()
    }

    #if DEBUG
    /// E2E trace (Debug builds only): stdout + Documents/e2e.log, pulled by the device test script.
    nonisolated static func e2eLog(_ s: String) {
        let line = "E2E \(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        print(line, terminator: "")
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = dir.appendingPathComponent("e2e.log")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }

    /// Logs the notifications iOS actually delivered (with delivery time) and
    /// the ones still pending.
    func e2eDumpState(_ tag: String) async {
        let delivered = await center.deliveredNotifications()
        let pending = await center.pendingNotificationRequests()
        let d = delivered.map { "\($0.request.identifier)@\(ISO8601DateFormatter().string(from: $0.date))" }.joined(separator: ",")
        Self.e2eLog("\(tag) delivered=[\(d)] pendingCount=\(pending.count)")
    }
    #endif

    /// Requests authorization. Returns true when granted.
    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func currentAuthorization() async -> Bool {
        let s = await center.notificationSettings()
        return s.authorizationStatus == .authorized
    }

    /// Clears every pending request then installs the ones the plan produces.
    /// Returns the scheduled requests (debug / e2e introspection).
    @discardableResult
    func reschedule(_ plan: Plan) -> [UNNotificationRequest] {
        let requests = Self.buildRequests(plan)
        center.removeAllPendingNotificationRequests()
        for r in requests { center.add(r) }
        return requests
    }

    /// Pure request building — every gate is applied here:
    /// master switch → per-type switches → iOS matrix → weekday mute → skip-next.
    /// nonisolated: pure function, callable synchronously from anywhere (tests).
    nonisolated static func buildRequests(_ p: Plan) -> [UNNotificationRequest] {
        guard p.masterEnabled else { return [] }
        let cal = Calendar.current
        var requests: [UNNotificationRequest] = []

        // Objective reminders: one daily repeating trigger per configured
        // time (each repeats forever → counts once against the 64 budget).
        var reminderCount = 0
        if p.remindersEnabled {
            for r in p.reminders {
                var seen = Set<Int>()
                for (i, t) in r.times.enumerated() {
                    guard reminderCount < maxReminderRequests else { break }
                    guard seen.insert(t.hour * 60 + t.minute).inserted else { continue }
                    let content = UNMutableNotificationContent()
                    content.title = r.name
                    content.body = "It's time to reach your objective"
                    content.sound = p.reminderSoundName.isEmpty
                        ? .default : UNNotificationSound(named: UNNotificationSoundName(p.reminderSoundName))
                    let trigger = UNCalendarNotificationTrigger(
                        dateMatching: DateComponents(hour: t.hour, minute: t.minute), repeats: true)
                    requests.append(UNNotificationRequest(
                        identifier: "objrem-\(r.id)-\(i)", content: content, trigger: trigger))
                    reminderCount += 1
                }
            }
        }

        // Friday Al Kahf alert — one weekly repeating trigger (iOS weekday:
        // 1 = Sunday … 6 = Friday).
        if let q = p.quranFriday {
            let content = UNMutableNotificationContent()
            content.title = "Al Kahf Sourat"
            content.body = "Friday recitation starts now"
            content.sound = p.quranSoundName.isEmpty
                ? .default : UNNotificationSound(named: UNNotificationSoundName(p.quranSoundName))
            let trigger = UNCalendarNotificationTrigger(
                dateMatching: DateComponents(hour: q.hour, minute: q.minute, weekday: 6), repeats: true)
            requests.append(UNNotificationRequest(
                identifier: "quran-friday", content: content, trigger: trigger))
        }

        // Athan alerts — one dated request per iOS-matrix-enabled slot.
        if p.athanAlerts {
            var slots: [(date: Date, id: String, name: String, time: String)] = []
            for dateStr in p.prayers.keys.sorted() {
                guard let day = DateUtil.dayFmt.date(from: dateStr) else { continue }
                let dow = DateUtil.scheduleDay(day)
                let muted = p.mutedWeekdays[DateUtil.jsDay(day)] == 1
                for pr in p.prayers[dateStr] ?? [] where AC.mainPrayers.contains(pr.prayer_name) {
                    guard !muted, p.athanSlotEnabled(pr.prayer_name, dow) else { continue }
                    let t = pr.prayer_time.split(separator: ":").compactMap { Int($0) }
                    guard t.count == 2,
                          let fire = cal.date(bySettingHour: t[0], minute: t[1], second: 0, of: day),
                          fire > p.now else { continue }   // past slots waste the 64-request budget
                    slots.append((fire, "athan-\(dateStr)-\(pr.prayer_name)", pr.prayer_name, pr.prayer_time))
                }
            }
            slots.sort { $0.date < $1.date }
            if p.skipNext {
                if p.skipNextOneShot {
                    // Server semantics: the flag is consumed by the very next
                    // athan — drop the earliest playable slot, whatever its day.
                    if !slots.isEmpty { slots.removeFirst() }
                } else {
                    // Standalone semantics: the flag is date-scoped → the rest
                    // of today's athans are muted.
                    slots.removeAll { cal.isDate($0.date, inSameDayAs: p.now) }
                }
            }
            // iOS keeps only the 64 soonest pending requests: schedule the
            // soonest athan slots within the budget left by the other types.
            for slot in slots.prefix(max(0, totalBudget - requests.count)) {
                let content = UNMutableNotificationContent()
                content.title = AC.displayPrayerName(slot.name)
                content.body = "It's time to pray — \(slot.time)"
                content.sound = p.athanSoundName.isEmpty
                    ? .default : UNNotificationSound(named: UNNotificationSoundName(p.athanSoundName))
                let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: slot.date)
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                requests.append(UNNotificationRequest(
                    identifier: slot.id, content: content, trigger: trigger))
            }
        }
        return requests
    }
}

/// Without a delegate iOS drops every notification that fires while the app
/// is in the foreground. Athan alerts show as a banner only (the app already
/// plays the athan audio itself); the other types also play their sound.
private final class ForegroundDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let opts: UNNotificationPresentationOptions =
            notification.request.identifier.hasPrefix("athan-") ? [.banner, .list] : [.banner, .list, .sound]
        #if DEBUG
        NotificationManager.e2eLog("willPresent id=\(notification.request.identifier) title=\(notification.request.content.title) options=\(opts.rawValue)")
        #endif
        return opts
    }
}
