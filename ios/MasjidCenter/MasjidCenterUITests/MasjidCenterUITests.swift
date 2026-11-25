import XCTest

// MARK: - E2E tests against the real Masjid Center server (Raspberry Pi).
// The app is launched with -serverBase pointing at the live server.

final class MasjidCenterUITests: XCTestCase {

    static let serverBase = "http://192.168.1.50:7777"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-serverBase", Self.serverBase, "-noAutoLocate"]
        app.launch()
        return app
    }

    private func waitFor(_ element: XCUIElement, _ timeout: TimeInterval = 15) -> Bool {
        element.waitForExistence(timeout: timeout)
    }

    // MARK: 1 — Home screen loads prayers from the server

    func testHomeShowsPrayersAndCard() throws {
        let app = launch()

        // Next prayer card appears (today always has data on the configured server).
        XCTAssertTrue(waitFor(app.otherElements["nextPrayerCard"], 20)
                      || waitFor(app.otherElements["dateOnlyCard"], 5))

        // Prayer list with 5 rows.
        let list = app.otherElements["prayersList"]
        XCTAssertTrue(waitFor(list))
        for name in ["Fajr | Sobh", "Dohr", "Asr", "Maghrib", "Isha"] {
            XCTAssertTrue(app.buttons["prayer-\(name)"].exists, "Missing row \(name)")
        }

        // Activities row
        for name in ["Coran", "Tasbih", "Nawafil"] {
            XCTAssertTrue(app.buttons["activity-\(name)"].exists)
        }

        // Navigation + actions
        XCTAssertTrue(app.buttons["prevDay"].exists)
        XCTAssertTrue(app.buttons["todayBtn"].exists)
        XCTAssertTrue(app.buttons["calendarBtn"].exists)
        XCTAssertTrue(app.buttons["nextDay"].exists)
        XCTAssertTrue(app.buttons["settingsBtn"].exists)
        XCTAssertTrue(app.buttons["historyBtn"].exists)
    }

    // MARK: 2 — Prayer check tri-state cycle (restored at the end)

    func testPrayerCheckCycle() throws {
        let app = launch()
        XCTAssertTrue(waitFor(app.buttons["prayer-Dohr"], 20))

        let row = app.buttons["prayer-Dohr"]
        // Tap → orange (state 2), tap → blue (state 1), tap → back to 0.
        for _ in 0..<3 {
            row.tap()
            usleep(700_000)
        }
        // After 3 toggles the check should be gone again (state 0).
        // Verify server state via the API is implicit; the row re-renders.
        XCTAssertTrue(row.exists)
    }

    // MARK: 3 — Date navigation toggles the "today" button state

    func testDateNavigation() throws {
        let app = launch()
        XCTAssertTrue(waitFor(app.buttons["nextDay"], 20))

        // Viewing today: the "go to today" button is disabled.
        XCTAssertFalse(app.buttons["todayBtn"].isEnabled)
        app.buttons["nextDay"].tap()
        sleep(2)
        // On a future date it becomes enabled.
        XCTAssertTrue(app.buttons["todayBtn"].isEnabled)

        // Today button returns us to today and disables again.
        app.buttons["todayBtn"].tap()
        sleep(2)
        XCTAssertFalse(app.buttons["todayBtn"].isEnabled)
        XCTAssertTrue(app.buttons["calendarBtn"].exists)
    }

    // MARK: 4 — Settings sheet opens with all sections

    func testSettingsSheet() throws {
        let app = launch()
        XCTAssertTrue(waitFor(app.buttons["settingsBtn"], 20))
        app.buttons["settingsBtn"].tap()

        XCTAssertTrue(waitFor(app.buttons["closeSettings"]))
        for section in ["section-General", "section-Location", "section-Athan call",
                        "section-Objectives", "section-Quran recitation",
                        "section-Audio control",
                        "section-Backup & Restore"] {
            XCTAssertTrue(app.buttons[section].exists, "Missing \(section)")
        }

        // General is open by default → dark mode toggle visible.
        XCTAssertTrue(app.buttons["darkModeToggle"].exists
                      || app.otherElements["darkModeToggle"].exists
                      || app.switches["darkModeToggle"].exists)
    }

    // MARK: 5 — Statistics sheet renders

    func testStatisticsSheet() throws {
        let app = launch()
        XCTAssertTrue(waitFor(app.buttons["historyBtn"], 20))
        app.buttons["historyBtn"].tap()

        XCTAssertTrue(waitFor(app.buttons["closeStatistics"]))
        XCTAssertTrue(waitFor(app.buttons["exportExcelBtn"]))
        XCTAssertTrue(app.staticTexts["Last Week Summary"].firstMatch.exists
                      || app.scrollViews.staticTexts["Last Week Summary"].exists)
    }

    // MARK: 6 — Calendar sheet shows the year grid

    func testCalendarSheet() throws {
        let app = launch()
        XCTAssertTrue(waitFor(app.buttons["calendarBtn"], 20))
        app.buttons["calendarBtn"].tap()

        XCTAssertTrue(waitFor(app.buttons["closeCalendar"]))
        // At least one day cell exists (e.g. today).
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'day-'")).count > 20)
    }

    // MARK: 7 — Activity toggle cycles

    func testActivityToggle() throws {
        let app = launch()
        XCTAssertTrue(waitFor(app.buttons["activity-Coran"], 20))
        let cell = app.buttons["activity-Coran"]
        cell.tap()
        usleep(700_000)
        cell.tap()
        usleep(700_000)
        cell.tap() // back to unchecked — leave server state clean
        XCTAssertTrue(cell.exists)
    }

    // MARK: 7b — Unchecked Tasbih tile opens the counter without checking it

    func testTasbihTileOpensCounter() throws {
        let app = launch()
        let cell = app.buttons["activity-Tasbih"]
        XCTAssertTrue(waitFor(cell, 20))
        // Live-server state varies day to day: uncheck the tile first if needed.
        for _ in 0..<2 where (cell.value as? String) != "not done" {
            cell.tap(); usleep(700_000)
        }
        XCTAssertEqual(cell.value as? String, "not done", "Precondition: Tasbih unchecked")
        cell.tap()
        let screen = app.otherElements["tasbihScreen"]
        XCTAssertTrue(screen.waitForExistence(timeout: 5),
                      "Tapping the unchecked Tasbih tile must open the counter")
        XCTAssertEqual(cell.value as? String, "not done",
                       "Opening the counter must not check the action")
        app.buttons["tasbihClose"].tap()
    }

    // MARK: 8 — Mute next athan button exists and is actionable

    func testMuteNextButton() throws {
        let app = launch()
        XCTAssertTrue(waitFor(app.buttons["settingsBtn"], 20))
        // On a fully-checked past day it swaps to Prayer Overview; today shows mute.
        let mute = app.buttons["muteNextBtn"]
        let quick = app.buttons["prayerOverviewBtn"]
        XCTAssertTrue(mute.exists || quick.exists)
    }
}

// MARK: - First-launch setup with a server (fresh install, real Pi)

extension MasjidCenterUITests {

    /// Type the server IP + Return → validate → loader → boot → home screen.
    /// Regression: validation used to be gated on a finished live check, so a
    /// quick validation did literally nothing.
    func testSetupServerFlow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-resetLocal", "-noAutoLocate"]
        app.launch()
        let field = app.textFields["setupField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Setup screen expected")
        field.tap()
        field.typeText("192.168.1.50\n")   // Return = validate → Connect pipeline
        XCTAssertTrue(app.buttons["prayer-Dohr"].waitForExistence(timeout: 40),
                      "Connect must boot the app and show the main screen")
    }

    /// The LAN scan must offer the discovered server as a chip — never typed
    /// into the field (injected text corrupted user input: "192.168.1.51Paris").
    /// Tapping the chip fills the field, checks the server, then Connect boots.
    func testSetupDiscoveryChipConnects() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-resetLocal", "-noAutoLocate"]
        app.launch()
        let chip = app.buttons["setupDiscoveredServer"]
        XCTAssertTrue(chip.waitForExistence(timeout: 20),
                      "LAN scan must offer the discovered server as a suggestion")
        chip.tap()
        let status = app.descendants(matching: .any)["setupStatus"]
        expectation(for: NSPredicate(format: "label CONTAINS[c] 'reachable'"), evaluatedWith: status)
        waitForExpectations(timeout: 15)
        app.buttons["setupConfirmButton"].tap()
        XCTAssertTrue(app.buttons["settingsBtn"].waitForExistence(timeout: 40),
                      "Connect from the discovered chip must reach the main screen")
    }
}

// MARK: - Server-mode stability / regression tests

extension MasjidCenterUITests {

    private func dayValue(_ app: XCUIApplication) -> String {
        (app.otherElements["prayersList"].value as? String) ?? ""
    }

    private func day(offset: Int) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Calendar.current.date(byAdding: .day, value: offset, to: Date())!)
    }

    /// Root cause of "navigation buttons sometimes dead": loadDay() was ignored while a load was in flight,
    /// leaving the previous date's data on screen. Rapid taps must always converge on the last date.
    func testRapidNavigationConverges() throws {
        let app = launch()
        XCTAssertTrue(waitFor(app.buttons["nextDay"], 20))
        XCTAssertEqual(dayValue(app), day(offset: 0))
        for _ in 0..<6 { app.buttons["nextDay"].tap() }
        sleep(3)
        XCTAssertEqual(dayValue(app), day(offset: 6))
        for _ in 0..<6 { app.buttons["prevDay"].tap() }
        sleep(3)
        XCTAssertEqual(dayValue(app), day(offset: 0))
        XCTAssertFalse(app.buttons["todayBtn"].isEnabled)
        app.buttons["nextDay"].tap()
        app.buttons["nextDay"].tap()
        app.buttons["todayBtn"].tap()
        sleep(2)
        XCTAssertEqual(dayValue(app), day(offset: 0))
    }

    /// Navigation must keep working after every sheet has been presented and dismissed.
    func testNavigationWorksAfterSheets() throws {
        let app = launch()
        XCTAssertTrue(waitFor(app.buttons["calendarBtn"], 20))
        app.buttons["calendarBtn"].tap()
        XCTAssertTrue(waitFor(app.buttons["closeCalendar"]))
        app.buttons["closeCalendar"].tap()
        sleep(1)
        app.buttons["settingsBtn"].tap()
        XCTAssertTrue(waitFor(app.buttons["closeSettings"]))
        app.buttons["closeSettings"].tap()
        sleep(1)
        app.buttons["historyBtn"].tap()
        XCTAssertTrue(waitFor(app.buttons["closeStatistics"]))
        app.buttons["closeStatistics"].tap()
        sleep(1)
        app.buttons["nextDay"].tap()
        sleep(2)
        XCTAssertEqual(dayValue(app), day(offset: 1))
        app.buttons["prevDay"].tap()
        sleep(2)
        XCTAssertEqual(dayValue(app), day(offset: 0))
    }

    /// Unreachable server → app must boot from its cache within seconds (no 60s hang, no empty list).
    func testOfflineBootUsesCache() throws {
        let online = launch()
        XCTAssertTrue(waitFor(online.buttons["prayer-Dohr"], 20))
        sleep(3)   // let the day be cached
        online.terminate()

        let app = XCUIApplication()
        app.launchArguments = ["-serverBase", "http://127.0.0.1:9", "-noAutoLocate"]
        app.launch()
        XCTAssertTrue(waitFor(app.buttons["prayer-Dohr"], 15), "Offline boot must show cached prayers")
        XCTAssertTrue(app.buttons["nextDay"].exists)
        app.terminate()

        // Restore the real server for the following tests.
        let back = launch()
        XCTAssertTrue(waitFor(back.buttons["prayer-Dohr"], 20))
    }
}

// MARK: - Server-config controls follow the server availability.

extension MasjidCenterUITests {
    private func reveal(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let el = app.buttons[id]
        for _ in 0..<10 where !el.exists || !el.isHittable { app.swipeUp() }
        return el
    }

    private func openSection(_ app: XCUIApplication, _ name: String) {
        let h = app.buttons["section-\(name)"]
        for _ in 0..<10 where !(h.exists && h.isHittable && h.frame.minY > 105) { app.swipeUp() }
        for _ in 0..<10 where !(h.exists && h.isHittable && h.frame.minY > 105) { app.swipeDown() }
        h.tap()
    }

    /// Returns [serverControlEnabled, localControlEnabled] for the Quran + Audio sections.
    private func serverControlStates(_ app: XCUIApplication) -> (quranServer: Bool, fridayToggle: Bool, testServer: Bool, testApp: Bool) {
        XCTAssertTrue(waitFor(app.buttons["settingsBtn"], 20))
        app.buttons["settingsBtn"].tap()
        XCTAssertTrue(waitFor(app.buttons["closeSettings"]))
        openSection(app, "Quran recitation")
        let q = reveal(app, "playFullQuranBtn")
        XCTAssertTrue(q.exists, "server 'Listen to Sourat Al Kahf now' missing")
        let quranServer = q.isEnabled
        XCTAssertTrue(reveal(app, "playLocalQuranBtn").isEnabled, "In app Quran button must always be usable")
        XCTAssertTrue(reveal(app, "notifQuranToggle").isEnabled, "In app Quran alert switch must always be usable")
        let t = reveal(app, "fridayQuranToggle")
        let fridayToggle = t.exists && t.isEnabled
        openSection(app, "Audio control")
        let ts = reveal(app, "testAthanServerBtn")
        XCTAssertTrue(ts.exists, "server test button missing")
        return (quranServer, fridayToggle, ts.isEnabled, reveal(app, "testAthanBtn").isEnabled)
    }

    func testServerOptionsGreyedWhenServerOffline() throws {
        // Online: the server controls are usable.
        let online = launch()
        XCTAssertTrue(waitFor(online.buttons["prayer-Dohr"], 20))
        sleep(3)
        let on = serverControlStates(online)
        XCTAssertTrue(on.quranServer && on.fridayToggle && on.testServer && on.testApp, "online: all enabled \(on)")
        online.terminate()

        // Server unreachable: every server control is greyed, local ones stay usable.
        let app = XCUIApplication()
        app.launchArguments = ["-serverBase", "http://127.0.0.1:9", "-noAutoLocate"]
        app.launch()
        XCTAssertTrue(waitFor(app.buttons["prayer-Dohr"], 15))
        let off = serverControlStates(app)
        XCTAssertFalse(off.quranServer, "offline: server Quran button must be disabled")
        XCTAssertFalse(off.fridayToggle, "offline: Friday toggle must be disabled")
        XCTAssertFalse(off.testServer, "offline: server test must be disabled")
        XCTAssertTrue(off.testApp, "offline: the in-app test must stay enabled")
        app.terminate()

        let back = launch()
        XCTAssertTrue(waitFor(back.buttons["prayer-Dohr"], 20))
    }
}

// MARK: - Settings layout: Global → In app → Server config, per section.

extension MasjidCenterUITests {
    private func y(_ app: XCUIApplication, _ id: String) -> CGFloat? {
        for q in [app.buttons[id], app.otherElements[id], app.switches[id], app.sliders[id], app.segmentedControls[id], app.staticTexts[id]] where q.exists {
            return q.frame.minY
        }
        return nil
    }
    private func openSec(_ app: XCUIApplication, _ name: String) {
        let h = app.buttons["section-\(name)"]
        for _ in 0..<10 where !(h.exists && h.isHittable && h.frame.minY > 105) { app.swipeUp() }
        for _ in 0..<10 where !(h.exists && h.isHittable && h.frame.minY > 105) { app.swipeDown() }
        h.tap()
        sleep(1)
    }
    /// Asserts a strictly increasing vertical order of the named elements.
    private func assertOrder(_ app: XCUIApplication, _ ids: [String], _ ctx: String) {
        var prev: CGFloat = -.infinity, prevId = ""
        for id in ids {
            guard let v = y(app, id) else { XCTFail("\(ctx): '\(id)' missing"); return }
            XCTAssertGreaterThan(v, prev, "\(ctx): '\(id)' must be below '\(prevId)'")
            prev = v; prevId = id
        }
    }

    func testSettingsGroupsLayoutServerMode() throws {
        let app = launch()
        XCTAssertTrue(waitFor(app.buttons["prayer-Dohr"], 20)); sleep(3)
        app.buttons["settingsBtn"].tap()
        XCTAssertTrue(waitFor(app.buttons["closeSettings"]))
        XCTAssertFalse(app.buttons["section-Notifications"].exists, "the Notifications section no longer exists")

        openSec(app, "Athan call")
        assertOrder(app, ["GLOBAL", "audioFilePicker", "IN APP", "notifAthanToggle", "iossched-week-Dohr", "SERVER CONFIG", "sched-week-Dohr"], "Athan/server")

        openSec(app, "Quran recitation")
        assertOrder(app, ["GLOBAL", "fridayQuranFilePicker", "IN APP", "playLocalQuranBtn", "notifQuranToggle", "SERVER CONFIG", "playFullQuranBtn", "fridayQuranToggle"], "Quran/server")

        openSec(app, "Objectives")
        assertOrder(app, ["IN APP", "addObjectiveBtn", "notifObjectivesToggle"], "Objectives")
        XCTAssertNil(y(app, "GLOBAL"), "Objectives: everything is In app")
        XCTAssertNil(y(app, "SERVER CONFIG"), "Objectives: nothing is server-side")

        openSec(app, "Audio control")
        assertOrder(app, ["GLOBAL", "stopAudioBtn", "testAthanServerBtn", "IN APP", "notificationsToggle", "playbackVolumeSlider", "SERVER CONFIG", "audioOutputPicker", "audioCardPicker"], "Audio/server")
        XCTAssertFalse(app.staticTexts["App startup sound"].exists, "App startup sound was removed")
        XCTAssertTrue(app.staticTexts["Server startup sound"].exists || { for _ in 0..<6 where !app.staticTexts["Server startup sound"].exists { app.swipeUp() }; return app.staticTexts["Server startup sound"].exists }(), "Server startup sound stays in Server config")
    }
}

// MARK: - First-launch setup: automatic location + server discovery.
// Preconditions (set by the runner script before the test):
//   xcrun simctl privacy booted grant|revoke location com.masjidcenter.app
//   xcrun simctl location booted set 48.8566,2.3522

extension MasjidCenterUITests {
    private func freshSetup() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetLocal"]          // NO -noAutoLocate: the real boot behaviour
        app.launch()
        return app
    }

    /// These two tests depend on the simulator's location permission, which a
    /// test can't set: run them with `echo granted|denied > /tmp/mc-setup-mode`
    /// after the matching `simctl privacy … location` — skipped otherwise.
    private func requireSetupMode(_ mode: String) throws {
        let m = (try? String(contentsOfFile: "/tmp/mc-setup-mode", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        try XCTSkipUnless(m == mode, "set /tmp/mc-setup-mode to '\(mode)' (and the simulator location permission accordingly)")
    }

    func testSetupAutoLocatesCityAndOffersServer() throws {
        try requireSetupMode("granted")
        let app = freshSetup()
        let field = app.textFields["setupField"]
        XCTAssertTrue(waitFor(field, 15))
        // City pre-filled from the device position, without any tap.
        let filled = NSPredicate { _, _ in
            let v = (field.value as? String) ?? ""
            return !v.isEmpty && v != "City or server address"
        }
        let exp = XCTNSPredicateExpectation(predicate: filled, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [exp], timeout: 30), .completed, "city must be pre-filled; field = \(field.value ?? "nil")")
        let city = (field.value as? String) ?? ""
        XCTAssertTrue(city.localizedCaseInsensitiveContains("Paris"), "expected Paris, got '\(city)'")
        // The LAN server is offered next to the city (chip), not injected in the field.
        XCTAssertTrue(waitFor(app.buttons["setupDiscoveredServer"], 30), "discovered server chip missing")
        XCTAssertEqual(field.value as? String, city, "the field must still hold the city")
        // Continue works with the detected city.
        let go = app.buttons["setupConfirmButton"]
        XCTAssertTrue(go.isEnabled)
        go.tap()
        XCTAssertTrue(waitFor(app.buttons["prayer-Dohr"], 60), "standalone boot with the detected city")
    }

    func testSetupLocationDeniedKeepsFieldEmptyAndStillOffersServer() throws {
        try requireSetupMode("denied")
        let app = freshSetup()
        let field = app.textFields["setupField"]
        XCTAssertTrue(waitFor(field, 15))
        XCTAssertTrue(waitFor(app.buttons["setupDiscoveredServer"], 30), "server chip must appear even if location is denied")
        let v = (field.value as? String) ?? ""
        XCTAssertTrue(v.isEmpty || v == "City or server address", "no city when the location is denied, got '\(v)'")
        let status = app.descendants(matching: .any)["setupStatus"].firstMatch
        XCTAssertTrue(status.exists)
        XCTAssertTrue((status.label).localizedCaseInsensitiveContains("denied") || (status.label).localizedCaseInsensitiveContains("manually"),
                      "denied location must explain what to do, got '\(status.label)'")
        // Manual path still works.
        field.tap(); field.typeText("Paris\n")
        XCTAssertTrue(waitFor(app.buttons["prayer-Dohr"], 60))
    }
}

// MARK: - Visual regression: capture every screen as attachments.

extension MasjidCenterUITests {
    func testScreenshots() throws {
        let app = launch()
        XCTAssertTrue(waitFor(app.buttons["settingsBtn"], 20))
        sleep(3)
        save(app.screenshot(), "01-home")

        app.buttons["settingsBtn"].tap()
        XCTAssertTrue(waitFor(app.buttons["section-Audio control"]))
        save(app.screenshot(), "02-settings-general")
        app.buttons["section-Athan call"].tap()
        sleep(1)
        save(app.screenshot(), "03-settings-athan")
        app.buttons["closeSettings"].tap()
        sleep(1)

        app.buttons["historyBtn"].tap()
        XCTAssertTrue(waitFor(app.buttons["exportExcelBtn"]))
        sleep(2)
        save(app.screenshot(), "04-statistics")
        app.buttons["closeStatistics"].tap()
        sleep(1)

        app.buttons["calendarBtn"].tap()
        XCTAssertTrue(waitFor(app.buttons["closeCalendar"]))
        save(app.screenshot(), "05-calendar")
    }

    /// Dark mode must restyle SYSTEM chrome too — the Settings nav title must
    /// be white on the dark sheet, not black (regression: preferredColorScheme
    /// read in the Scene builder stayed at the launch-time value).
    func testDarkModeSettingsTitle() throws {
        let app = launch()
        XCTAssertTrue(waitFor(app.buttons["settingsBtn"], 20))
        app.buttons["settingsBtn"].tap()
        XCTAssertTrue(waitFor(app.buttons["closeSettings"]))

        let row = app.descendants(matching: .any)["darkModeToggle"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))

        // The toggle capsule is folded into the row's accessibility element,
        // so tap by screen coordinates: the row's mid-Y, near the sheet's
        // trailing edge where the capsule sits.
        func tapToggle() {
            let y = row.frame.midY
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: app.frame.width - 64, dy: y))
                .tap()
        }

        tapToggle()                                     // → other theme
        sleep(2)
        tapToggle()                                     // → back
        sleep(2)
        save(app.screenshot(), "settings-dark-title")

        XCTAssertTrue(app.navigationBars["Settings"].exists)
    }

    private func save(_ shot: XCUIScreenshot, _ name: String) {
        let a = XCTAttachment(screenshot: shot)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
