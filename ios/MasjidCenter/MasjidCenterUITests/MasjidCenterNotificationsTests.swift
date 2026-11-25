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
        app.launchArguments = ["-resetLocal", "-notifDebug", "-noAutoLocate"]
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
            // isHittable alone is unreliable: a row clipped by the nav bar can
            // report hittable=true at y≈48 and the tap lands on the bar.
            guard app.buttons["closeSettings"].exists else { return el }
            if el.exists {
                let f = el.frame
                if el.isHittable && f.minY > 105 && f.maxY < 770 { return el }
                f.midY < 440 ? app.swipeDown() : app.swipeUp()
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
        // An element deep in the accordion can report a plausible frame while
        // still clipped by the sheet — wait for a real hittable state so the
        // tap actually reaches the control.
        var el = scrollToButton(app, id)
        for _ in 0..<10 where !el.isHittable {
            sleep(1)
            el = scrollToButton(app, id)
        }
        XCTAssertTrue(el.isHittable, "not tappable \(id)", file: file, line: line)
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

    /// Opens the "Audio control" settings section — the "App notifications"
    /// master switch lives in its "In app" group (notification types are
    /// distributed into their own feature sections).
    private func openNotifications(_ app: XCUIApplication, file: StaticString = #file, line: UInt = #line) {
        ensureSection(app, "Audio control", probe: "notificationsToggle", file: file, line: line)
    }

    private func openAthanCall(_ app: XCUIApplication, file: StaticString = #file, line: UInt = #line) {
        ensureSection(app, "Athan call", probe: "notifAthanToggle", file: file, line: line)
    }
    private func openObjectives(_ app: XCUIApplication, file: StaticString = #file, line: UInt = #line) {
        ensureSection(app, "Objectives", probe: "notifObjectivesToggle", file: file, line: line)
    }
    private func openQuran(_ app: XCUIApplication, file: StaticString = #file, line: UInt = #line) {
        ensureSection(app, "Quran recitation", probe: "notifQuranToggle", file: file, line: line)
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
        openAthanCall(app)
        // Master off: nothing pending, but the "In app" controls stay usable
        // and a hint explains why no alert is sent.
        waitPending(app) { $0.isEmpty }
        XCTAssertTrue(toggleEnabled(app, "notifAthanToggle"), "In app switch must stay usable while master is off")
        XCTAssertTrue(toggleEnabled(app, "iossched-week-Dohr"), "In app matrix must stay usable while master is off")
        XCTAssertTrue(app.descendants(matching: .any)["masterOffHint"].firstMatch.waitForExistence(timeout: 3),
                      "master-off hint must be shown")

        enableMaster(app)
        openAthanCall(app)

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
        openObjectives(app)
        tapToggle(app, "notifObjectivesToggle")
        waitPending(app) {
            !$0.contains { $0.hasPrefix("objrem-") } && $0.contains { $0.hasPrefix("athan-") }
        }

        // Master OFF → everything cleared.
        openNotifications(app)
        tapToggle(app, "notificationsToggle")
        waitPending(app) { $0.isEmpty }
    }

    // MARK: 1b — standalone: server controls greyed, athan matrix kept as "Playback"

    func testStandaloneGreysServerOptions() throws {
        let app = launchStandalone()
        ensureSection(app, "Quran recitation", probe: "playLocalQuranBtn")
        XCTAssertTrue(app.buttons["playLocalQuranBtn"].exists || scrollToButton(app, "playLocalQuranBtn").exists,
                      "in-app Quran button must exist")
        XCTAssertFalse(toggleEnabled(app, "playFullQuranBtn"), "server Quran button must be greyed in standalone")
        XCTAssertFalse(toggleEnabled(app, "fridayQuranToggle"), "Friday toggle (server) must be greyed in standalone")
        XCTAssertTrue(toggleEnabled(app, "playLocalQuranBtn"), "the in-app Quran button must stay usable")
        // …and it really plays, even though "App notifications" is off.
        scrollToButton(app, "playLocalQuranBtn").tap()
        XCTAssertTrue(app.descendants(matching: .any)["audioBannerSheet"].firstMatch.waitForExistence(timeout: 8),
                      "in-app Quran playback must start with master off")
        app.buttons["stopAudioBannerSheet"].tap()

        // Athan: the matrix drives local playback → group renamed "Playback", matrix usable.
        ensureSection(app, "Athan call", probe: "audioFilePicker")
        XCTAssertTrue(app.staticTexts["PLAYBACK"].waitForExistence(timeout: 3) || { for _ in 0..<8 where !app.staticTexts["PLAYBACK"].exists { app.swipeUp() }; return app.staticTexts["PLAYBACK"].exists }(),
                      "standalone athan matrix group must be named Playback")
        XCTAssertFalse(app.staticTexts["SERVER CONFIG"].exists, "no 'Server config' group in standalone")
        XCTAssertTrue(toggleEnabled(app, "sched-week-Dohr"), "local playback matrix must stay usable")
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

        // iOS matrix (same section, "In app" group): turn Dohr OFF → its
        // alert disappears, others stay.
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
        relaunched.launchArguments = ["-notifDebug", "-noAutoLocate"]
        relaunched.launch()
        XCTAssertTrue(relaunched.buttons["settingsBtn"].waitForExistence(timeout: 15))
        waitPending(relaunched) { !$0.isEmpty }
        XCTAssertFalse(pendingIds(relaunched).contains { $0.hasSuffix("-Dohr") },
                       "iOS matrix choice must persist across relaunches")
    }

    // MARK: 3 — Friday recitation alert switch exists and is master-subordinate

    func testFridayAlertSwitchPresent() throws {
        let app = launchStandalone()
        openQuran(app)
        XCTAssertTrue(toggleEnabled(app, "notifQuranToggle"), "usable while master off")
        enableMaster(app)
        openQuran(app)
        XCTAssertTrue(toggleEnabled(app, "notifQuranToggle"), "usable once master is on")
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
        openAthanCall(app)
        tapSegment(app, "notifSoundAthan", 1)
        waitSounds(app) { $0.contains("athan=notif-athan-") }
        waitPending(app) { $0.contains { $0.hasPrefix("athan-") } }

        // Quran → configured Friday recitation file → notif-quran.caf.
        openQuran(app)
        tapSegment(app, "notifSoundQuran", 1)
        waitSounds(app) { $0.contains("quran=notif-quran-") }

        // Athan back to "Notify" — the quran choice is untouched.
        openAthanCall(app)
        tapSegment(app, "notifSoundAthan", 0)
        waitSounds(app) { $0.contains("athan=water_drop.wav") && $0.contains("quran=notif-quran-") }
    }
}


// MARK: - Notification taps + playback volume (simulator; Debug -notifFireIn hook).
// A slot due within ~2 min is delivered while the app is in the background /
// terminated; the banner is then tapped from SpringBoard.

extension MasjidCenterNotificationsTests {

    private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    /// Fresh standalone install with the master switch ON (and optionally the
    /// real athan sound), then terminated so the next launch starts clean.
    private func firstLaunchConfigured(athanSound: Bool) -> XCUIApplication {
        let app = launchStandalone()
        enableMaster(app)
        if athanSound {
            ensureSection(app, "Athan call", probe: "notifSoundAthan")
            tapSegment(app, "notifSoundAthan", 1)
            waitSounds(app) { $0.contains("athan=notif-athan-") }
        }
        app.terminate()
        return app
    }

    private func relaunch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-notifDebug", "-noAutoLocate"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["settingsBtn"].waitForExistence(timeout: 15))
        return app
    }

    private func tapBanner(_ text: String) {
        let b = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
        XCTAssertTrue(b.waitForExistence(timeout: 150), "banner '\(text)' not delivered")
        b.tap()
    }

    func testTasbihReminderTapOpensTasbih_background() throws {
        _ = firstLaunchConfigured(athanSound: false)
        let app = relaunch(["-notifFireIn", "40", "-notifFireKind", "tasbih"])
        XCUIDevice.shared.press(.home)
        tapBanner("reach your objective")
        XCTAssertTrue(app.descendants(matching: .any)["tasbihScreen"].firstMatch.waitForExistence(timeout: 10),
                      "Tasbih view must open on tap (app was backgrounded)")
    }

    func testTasbihReminderTapOpensTasbih_coldLaunch() throws {
        _ = firstLaunchConfigured(athanSound: false)
        let app = relaunch(["-notifFireIn", "40", "-notifFireKind", "tasbih"])
        sleep(2)
        app.terminate()
        tapBanner("reach your objective")
        let relaunched = XCUIApplication()
        XCTAssertTrue(relaunched.descendants(matching: .any)["tasbihScreen"].firstMatch.waitForExistence(timeout: 20),
                      "Tasbih view must open on tap (app was terminated)")
    }

    func testAthanTapPlaysFullAudioInApp() throws {
        _ = firstLaunchConfigured(athanSound: true)
        let app = relaunch(["-notifFireIn", "40", "-notifFireKind", "athan"])
        XCUIDevice.shared.press(.home)
        tapBanner("time to pray")
        let bar = app.descendants(matching: .any)["audioBanner"].firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 15), "athan must start playing in the app after the tap")
        sleep(35)   // the notification sound is capped at 30 s — playback must go on
        XCTAssertTrue(bar.exists, "athan playback must not stop at 30 s")
    }

    func testPlaybackVolumeSlider() throws {
        _ = firstLaunchConfigured(athanSound: false)   // master ON (slider is master-subordinate)
        let app = relaunch([])
        app.buttons["settingsBtn"].tap()
        ensureSection(app, "Audio control", probe: "playbackVolumeSlider")
        let slider = app.sliders["playbackVolumeSlider"]
        for _ in 0..<10 where !slider.exists { app.swipeUp() }
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        XCTAssertEqual(slider.normalizedSliderPosition, 1.0, accuracy: 0.02, "default volume is 100%")
        for _ in 0..<6 where !(slider.isHittable && slider.frame.midY < 650) { app.swipeUp() }
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5))
            .press(forDuration: 0.2, thenDragTo: slider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        sleep(1)
        XCTAssertEqual(slider.normalizedSliderPosition, 0.5, accuracy: 0.06)
        let label = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Athan & recitation volume'")).firstMatch
        XCTAssertTrue(label.exists, "volume label shown")
        XCTAssertFalse(label.label.contains("100"), "label follows the slider: \(label.label)")
    }
}
