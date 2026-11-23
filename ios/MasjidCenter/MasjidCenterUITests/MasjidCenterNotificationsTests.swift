import XCTest

// MARK: - E2E tests for granular iOS notifications (standalone mode).
// The app is launched with -notifDebug: ContentView then exposes the pending
// notification identifiers through the "notifDebug" element's value, which
// these tests assert after each configuration change.
// Needs network once per test: the standalone setup geocodes the city and
// downloads the prayer times ICS — same as the other standalone tests.

final class MasjidCenterNotificationsTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: Helpers

    /// Fresh install → full standalone setup → home screen, -notifDebug on.
    private func launchStandalone(city: String = "Paris") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetLocal", "-notifDebug"]
        app.launch()
        XCTAssertTrue(app.buttons["useLocationButton"].waitForExistence(timeout: 10), "Setup screen expected")
        let field = app.textFields["setupField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(city + "\n")
        XCTAssertTrue(app.buttons["prayer-Dohr"].waitForExistence(timeout: 60), "Prayer times must load from the ICS link")
        return app
    }

    /// Scrolls the settings sheet until `id` is tappable. Direction-aware:
    /// an element materialized but clipped at an edge (the lazy stack keeps
    /// off-viewport rows in the tree, and XCUI won't auto-scroll a partially
    /// visible element — a raw tap then hits whatever actually covers its
    /// hit point) gets scrolled toward the middle instead of blind swipes.
    /// Stops if the sheet was dismissed (a swipeDown at scroll-top pulls it).
    private func scrollToButton(_ app: XCUIApplication, _ id: String, maxSwipes: Int = 10) -> XCUIElement {
        let el = app.buttons[id]
        for _ in 0..<(maxSwipes * 2) {
            if el.isHittable { return el }
            guard app.buttons["closeSettings"].exists else { return el }
            if el.exists {
                let f = el.frame
                if f.minY > 105 && f.maxY < 770 { return el }   // fully in view
                f.midY < 400 ? app.swipeDown() : app.swipeUp()
            } else {
                app.swipeUp()
            }
        }
        return el
    }

    /// Ensures `name` is the expanded accordion section. Only ONE section is
    /// open at a time and tapping an open header collapses it, so the probe
    /// (an element at the top of the section) tells us whether a tap is needed.
    private func ensureSection(_ app: XCUIApplication, _ name: String, probe: String,
                               file: StaticString = #file, line: UInt = #line) {
        if !app.buttons["closeSettings"].exists {
            app.buttons["settingsBtn"].tap()
            XCTAssertTrue(app.buttons["closeSettings"].waitForExistence(timeout: 10), file: file, line: line)
        }
        let header = scrollToButton(app, "section-\(name)")
        XCTAssertTrue(header.exists, "section-\(name) missing", file: file, line: line)
        let p = app.descendants(matching: .any)[probe].firstMatch
        if p.waitForExistence(timeout: 2) { return }   // already expanded
        header.tap()
        XCTAssertTrue(p.waitForExistence(timeout: 5), "section \(name) did not open",
                      file: file, line: line)
    }

    /// Taps the toggle inside a row identified by its accessibility id —
    /// SwiftUI propagates the row identifier onto the inner WebToggle button,
    /// so `app.buttons[id]` is the precise match.
    private func tapToggle(_ app: XCUIApplication, _ id: String, file: StaticString = #file, line: UInt = #line) {
        let el = scrollToButton(app, id)
        XCTAssertTrue(el.waitForExistence(timeout: 3), "missing \(id)", file: file, line: line)
        el.tap()
    }

    private func toggleEnabled(_ app: XCUIApplication, _ id: String) -> Bool {
        let el = scrollToButton(app, id)
        guard el.waitForExistence(timeout: 3) else { return false }
        return el.isEnabled
    }

    /// Pending notification identifiers (semicolon-joined), via the -notifDebug probe.
    private func pendingIds(_ app: XCUIApplication) -> [String] {
        let v = (app.descendants(matching: .any)["notifDebug"].firstMatch.value as? String) ?? ""
        return v.isEmpty ? [] : v.components(separatedBy: ";")
    }

    /// Per-type sound actually applied to requests ("athan=default;obj=…;quran=…"),
    /// via the -notifDebug sound probe.
    private func soundSummary(_ app: XCUIApplication) -> String {
        (app.descendants(matching: .any)["notifSounds"].firstMatch.value as? String) ?? ""
    }

    /// Polls the sound probe — configured sounds resolve asynchronously
    /// (download + mp3→caf transcode) before the reschedule applies them.
    private func waitSounds(_ app: XCUIApplication, timeout: TimeInterval = 20,
                            _ pred: (String) -> Bool,
                            file: StaticString = #file, line: UInt = #line) {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if pred(soundSummary(app)) { return }
            usleep(400_000)
        }
        XCTAssertTrue(pred(soundSummary(app)), "sound summary = \(soundSummary(app))",
                      file: file, line: line)
    }

    /// Taps segment `index` (0 = "Alert", 1 = the configured feature sound)
    /// of a notification-sound picker. The row identifier propagates onto
    /// both segments, so boundBy disambiguates them.
    private func tapSegment(_ app: XCUIApplication, _ id: String, _ index: Int,
                            file: StaticString = #file, line: UInt = #line) {
        var btn = app.buttons.matching(identifier: id).element(boundBy: index)
        for _ in 0..<10 where !btn.exists { app.swipeUp() }
        if !btn.exists {
            let ctrl = app.segmentedControls.matching(identifier: id).firstMatch
            if ctrl.exists { btn = ctrl.buttons.element(boundBy: index) }
        }
        XCTAssertTrue(btn.waitForExistence(timeout: 3),
                      "missing segment \(index) of \(id)", file: file, line: line)
        btn.tap()
    }

    /// Waits until the pending-id list satisfies a predicate (reschedules are sync,
    /// but boot/load timing needs a short poll).
    private func waitPending(_ app: XCUIApplication, timeout: TimeInterval = 15,
                             _ pred: ([String]) -> Bool,
                             file: StaticString = #file, line: UInt = #line) {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if pred(pendingIds(app)) { return }
            usleep(400_000)
        }
        XCTAssertTrue(pred(pendingIds(app)), "pending ids = \(pendingIds(app))",
                      file: file, line: line)
    }

    /// Opens the "Notifications" settings section (all iOS notification
    /// options are grouped there since the dedicated section was added).
    private func openNotifications(_ app: XCUIApplication, file: StaticString = #file, line: UInt = #line) {
        ensureSection(app, "Notifications", probe: "notificationsToggle", file: file, line: line)
    }

    /// Turns the master "iOS notifications" switch ON, accepting the system
    /// authorization prompt when it appears (only needed once per install).
    private func enableMaster(_ app: XCUIApplication) {
        addUIInterruptionMonitor(withDescription: "Notifications") { alert -> Bool in
            for label in ["Allow", "Autoriser"] {
                if alert.buttons[label].exists { alert.buttons[label].tap(); return true }
            }
            return false
        }
        openNotifications(app)
        tapToggle(app, "notificationsToggle")
        // Nudge the interruption monitor without touching any control —
        // a bare app.tap() hits the screen center (once collapsed the
        // "Notifications" accordion header).
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.11)).tap()
        waitPending(app) { $0.contains { $0.hasPrefix("athan-") } }
    }

    // MARK: 1 — Per-type switches gate each notification kind independently

    func testPerTypeSwitches() throws {
        let app = launchStandalone()
        openNotifications(app)
        // Master off: nothing pending, sub-switches disabled.
        waitPending(app) { $0.isEmpty }
        XCTAssertFalse(toggleEnabled(app, "notifAthanToggle"), "sub-switch must be disabled while master is off")

        enableMaster(app)

        // Athan alerts OFF → athan ids disappear; the switch is type-scoped.
        tapToggle(app, "notifAthanToggle")
        waitPending(app) { !$0.contains { $0.hasPrefix("athan-") } }
        tapToggle(app, "notifAthanToggle")
        waitPending(app) { $0.contains { $0.hasPrefix("athan-") } }

        // Add a Coran objective reminder → objrem id appears.
        ensureSection(app, "Objectives", probe: "selectObjective-Coran")
        let coran = scrollToButton(app, "selectObjective-Coran")
        XCTAssertTrue(coran.waitForExistence(timeout: 3))
        coran.tap()
        let add = scrollToButton(app, "reminderAdd-Coran")
        XCTAssertTrue(add.waitForExistence(timeout: 3))
        add.tap()
        waitPending(app) { $0.contains { $0.hasPrefix("objrem-") } && $0.contains { $0.hasPrefix("athan-") } }

        // Objective reminders OFF → objrem gone, athan alerts kept.
        openNotifications(app)
        tapToggle(app, "notifObjectivesToggle")
        waitPending(app) {
            !$0.contains { $0.hasPrefix("objrem-") } && $0.contains { $0.hasPrefix("athan-") }
        }

        // Master OFF → everything cleared.
        tapToggle(app, "notificationsToggle")
        waitPending(app) { $0.isEmpty }
    }

    // MARK: 2 — iOS notification matrix is independent from the athan schedule

    func testIOSMatrixIndependentFromPlaybackMatrix() throws {
        let app = launchStandalone()
        enableMaster(app)
        ensureSection(app, "Athan call", probe: "audioFilePicker")

        // Playback matrix: turn Dohr OFF (affects audio) — its iOS alert must
        // still be scheduled: the two matrices are independent.
        tapToggle(app, "sched-week-Dohr")
        sleep(1)   // let the async reschedule land before asserting
        waitPending(app) { $0.contains { $0.hasSuffix("-Dohr") } }

        // iOS matrix (in the "Notifications" section): turn Dohr OFF → its
        // alert disappears, others stay.
        openNotifications(app)
        tapToggle(app, "iossched-week-Dohr")
        waitPending(app) {
            !$0.contains { $0.hasSuffix("-Dohr") }
                && $0.contains { $0.hasSuffix("-Asr") }
        }

        // Back ON → Dohr alerts return.
        tapToggle(app, "iossched-week-Dohr")
        waitPending(app) { $0.contains { $0.hasSuffix("-Dohr") } }
        // Turn it back OFF for the persistence check below.
        tapToggle(app, "iossched-week-Dohr")
        waitPending(app) { !$0.contains { $0.hasSuffix("-Dohr") } }

        // The iOS choice survives a relaunch (no -resetLocal: data persists).
        app.terminate()
        let relaunched = XCUIApplication()
        relaunched.launchArguments = ["-notifDebug"]
        relaunched.launch()
        XCTAssertTrue(relaunched.buttons["settingsBtn"].waitForExistence(timeout: 15))
        waitPending(relaunched) { !$0.isEmpty }
        XCTAssertFalse(pendingIds(relaunched).contains { $0.hasSuffix("-Dohr") },
                       "iOS matrix choice must persist across relaunches")
    }

    // MARK: 3 — Friday recitation alert switch exists and is master-subordinate

    func testFridayAlertSwitchPresent() throws {
        let app = launchStandalone()
        openNotifications(app)
        XCTAssertFalse(toggleEnabled(app, "notifQuranToggle"), "disabled while master off")
        enableMaster(app)
        XCTAssertTrue(toggleEnabled(app, "notifQuranToggle"), "enabled once master is on")
        // No quran-friday request: the Friday recitation setting is off by
        // default in standalone, so the type switch alone must not schedule one.
        waitPending(app) { !$0.contains("quran-friday") }
    }

    // MARK: 4 — Per-type sound pickers (Alert vs the feature's own sound)

    /// Athan and quran each play either the "Notify" chime (water drop) or
    /// the same sound the feature uses — configured athan / Friday recitation
    /// file, transcoded to ≤30 s .caf under Library/Sounds.
    func testNotificationSoundChoices() throws {
        let app = launchStandalone()
        enableMaster(app)   // leaves us inside "Notifications" with master ON

        // Defaults: "Notify" chime for every type.
        waitSounds(app) {
            $0.contains("athan=water_drop.wav") && $0.contains("obj=water_drop.wav")
                && $0.contains("quran=water_drop.wav")
        }

        // Athan → configured file (bundled default_athan.mp3 → notif-athan.caf).
        tapSegment(app, "notifSoundAthan", 1)
        waitSounds(app) { $0.contains("athan=notif-athan.caf") }
        waitPending(app) { $0.contains { $0.hasPrefix("athan-") } }

        // Quran → configured Friday recitation file → notif-quran.caf.
        tapSegment(app, "notifSoundQuran", 1)
        waitSounds(app) { $0.contains("quran=notif-quran.caf") }

        // Athan back to "Notify" — the quran choice is untouched.
        tapSegment(app, "notifSoundAthan", 0)
        waitSounds(app) { $0.contains("athan=water_drop.wav") && $0.contains("quran=notif-quran.caf") }
    }
}
