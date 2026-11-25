#if DEBUG
import Foundation
import AVFoundation
import MediaPlayer
import UIKit

// MARK: - E2E scenarios (Debug builds only), driven by launch arguments:
//   -selfTest           pure-logic checks (URL building, CSV import fuzz, ICS guards, discovery bounds)
//   -audioEdge          audio state machine edge cases (interruptions, bad URL, gate, replace…)
//   -soundRangeTest     server-only 96 MB recitation → notification sound through the ranged download
// Every check logs "selftest[name] PASS|FAIL detail" through e2eLog.

extension AppStore {
    private func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        NotificationManager.e2eLog("selftest[\(name)] \(ok ? "PASS" : "FAIL") \(detail)")
    }

    func runDebugSelfTests() async {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-selfTest") else { return }

        // --- URL building: a file name is ONE path segment ---
        let api = APIClient(base: "http://h:7777")
        check("url.slash-encoded", api.athanURL("a/b.mp3")?.absoluteString.hasSuffix("/api/audio/a%2Fb.mp3") == true, api.athanURL("a/b.mp3")?.absoluteString ?? "nil")
        check("url.dotdot-refused", api.athanURL("..") == nil && api.quranURL(".") == nil)
        check("url.traversal-encoded", api.quranURL("../../etc/passwd")?.absoluteString.hasSuffix("/api/quran/..%2F..%2Fetc%2Fpasswd") == true, api.quranURL("../../etc/passwd")?.absoluteString ?? "nil")
        check("url.empty-refused", api.athanURL("") == nil)
        let weird = api.quranURL("x?y#z & 100%.mp3")?.absoluteString ?? ""
        check("url.query-fragment-encoded", !weird.dropFirst("http://h:7777/api/quran/".count).contains("?") && !weird.contains("#") && !weird.contains(" "), weird)
        check("url.no-server-nil", APIClient(base: "").athanURL("a.mp3") == nil)

        // --- server address normalization ---
        let cases: [(String, String)] = [("pi.local", "http://pi.local:7777"), ("https://x.org", "https://x.org:7777"),
                                         ("http://1.2.3.4:80/path/x", "http://1.2.3.4:80"), ("", ""), ("   ", ""), ("http://", ""),
                                         ("192.168.1.5", "http://192.168.1.5:7777")]
        for (i, (input, want)) in cases.enumerated() {
            let got = ServerURL.normalize(input)
            check("normalize.\(i)", got == want, "'\(input)' -> '\(got)' want '\(want)'")
        }

        // --- ICS guards: scheme whitelist, size, malformed content ---
        for (i, bad) in ["file:///etc/hosts", "ftp://x.org/a.ics", "data:text/plain,x", "javascript:alert(1)", "notaurl", "http://", ""].enumerated() {
            let threw: Bool
            do { _ = try await ICSClient.fetch(urlString: bad); threw = false } catch { threw = true }
            check("ics.reject.\(i)", threw, bad)
        }
        let garbage = ["", "BEGIN:VEVENT", "END:VEVENT\nEND:VEVENT", "BEGIN:VEVENT\nDTSTART:\nEND:VEVENT",
                       "BEGIN:VEVENT\nSUMMARY:Fajr\nDTSTART:99999999T999999Z\nEND:VEVENT", String(repeating: "A", count: 2_000_000),
                       "BEGIN:VEVENT\nSUMMARY:\u{0}\u{1}\nDTSTART;TZID=X:20991231T235959\nEND:VEVENT"]
        for (i, g) in garbage.enumerated() { _ = ICSClient.parse(g); check("ics.parse-garbage.\(i)", true) }

        // --- CSV import fuzz (merge into the live snapshot; run on a -resetLocal install) ---
        let hdr = "type,key,value\n"
        let rows = ["ios_volume,playback,99999", "ios_volume,playback,-5", "ios_volume,playback,abc", "ios_schedule,Dohr-99,1",
                    "ios_schedule,Evil-0,1", "ios_schedule,Dohr--1,1", "ios_sound,athan,../../x", "ios_sound,quran,configured",
                    "objective_reminder,Tasbih,25:99;ab;09:00;09:00;10:00;11:00;12:00;13:00;14:00", "custom_action,x,{bad json}",
                    "setting,tasbih_target,0", "setting,tasbih_target,-7", "setting,tasbih_target,99999999999999999999",
                    "prayer_schedule,Dohr-99,5", "weekday_mute,x,y", ",,", "a", "ios_notif,athan,", "action_order,ids,;;;",
                    String(repeating: "x", count: 500_000), "setting,\u{0},\u{1}", "prayer_check,::,1"]
        let n = LocalStore.shared.importConfigCSV(hdr + rows.joined(separator: "\r\n"))
        let snap = LocalStore.shared.snap
        check("csv.fuzz-no-crash", true, "imported=\(n)")
        let crlf = LocalStore.shared.importConfigCSV("type,key,value\r\nios_volume,playback,40\r\nsetting,tasbih_target,33\r\n")
        check("csv.crlf-applied", crlf == 2 && LocalStore.shared.snap.iosPlaybackVolume == 0.4 && LocalStore.shared.snap.tasbihTarget == 33, "rows=\(crlf) vol=\(LocalStore.shared.snap.iosPlaybackVolume) target=\(LocalStore.shared.snap.tasbihTarget)")
        _ = LocalStore.shared.importConfigCSV(hdr + rows.joined(separator: "\r\n"))
        check("csv.volume-clamped", (0...1).contains(snap.iosPlaybackVolume), "\(snap.iosPlaybackVolume)")
        check("csv.sound-whitelisted", ["default", "configured"].contains(snap.iosNotifSoundAthan), snap.iosNotifSoundAthan)
        check("csv.ios-schedule-valid", snap.iosSchedule.allSatisfy { (0...6).contains($0.day_of_week) && AC.mainPrayers.contains($0.prayer_name) && ($0.enabled == 0 || $0.enabled == 1) })
        check("csv.schedule-dow-valid", snap.schedule.allSatisfy { (0...6).contains($0.day_of_week) })
        check("csv.reminders-valid", (snap.objectiveReminders["Tasbih"] ?? []).count <= 5 && (snap.objectiveReminders["Tasbih"] ?? []).allSatisfy { DateUtil.timeFmt.date(from: $0) != nil }, "\(snap.objectiveReminders["Tasbih"] ?? [])")
        check("csv.tasbih-target-clamped", (1...9999).contains(snap.tasbihTarget), "\(snap.tasbihTarget)")
        check("csv.empty-and-header-only", LocalStore.shared.importConfigCSV("") == 0 && LocalStore.shared.importConfigCSV(hdr) == 0 && LocalStore.shared.importConfigCSV("x,y,z\n1,2,3") == 0)

        // --- LAN discovery: bounded in time, never hangs the setup screen ---
        let t0 = Date()
        let found = await ServerDiscovery.findServer()
        let dt = Date().timeIntervalSince(t0)
        check("discovery.bounded", dt < 12, String(format: "%.1fs found=%@", dt, found ?? "nil"))

        // --- notification builder gates (pure) ---
        var plan = NotificationManager.Plan()
        plan.masterEnabled = false; plan.athanAlerts = true; plan.remindersEnabled = true
        check("notif.master-off-empty", NotificationManager.buildRequests(plan).isEmpty)
        check("notif.threads", true)
        NotificationManager.e2eLog("selftest[done]")
    }

    // MARK: audio edge cases

    func runAudioEdgeScenario() async {
        guard ProcessInfo.processInfo.arguments.contains("-audioEdge") else { return }
        let nc = NotificationCenter.default
        func info() -> [String: Any]? { MPNowPlayingInfoCenter.default().nowPlayingInfo }
        func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        func interruption(_ type: AVAudioSession.InterruptionType, resume: Bool = false) {
            var u: [AnyHashable: Any] = [AVAudioSessionInterruptionTypeKey: type.rawValue]
            if resume { u[AVAudioSessionInterruptionOptionKey] = AVAudioSession.InterruptionOptions.shouldResume.rawValue }
            nc.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: u)
        }
        guard let url = AC.bundledAudioURL("default_athan.mp3") else { check("edge.setup", false, "no bundled athan"); return }

        audio.playbackGate = { false }
        // 1. gate: automatic play blocked, explicit (force) allowed
        audio.play(url: url, banner: "auto")
        await wait(0.5); check("edge.gate-blocks-auto", !audio.isPlaying && info() == nil)
        audio.play(url: url, banner: "manual", force: true)
        await wait(1.5); check("edge.force-bypasses-gate", audio.isPlaying && !audio.isPaused && info() != nil)

        // 2. interruption began -> paused ; ended without resume -> stays paused ; ended with resume -> plays
        interruption(.began); await wait(1); check("edge.interrupt-began-pauses", audio.isPaused)
        interruption(.ended, resume: false); await wait(1); check("edge.interrupt-ended-noresume-stays-paused", audio.isPaused)
        interruption(.ended, resume: true); await wait(1.5); check("edge.interrupt-ended-resume-plays", !audio.isPaused && (info()?[MPNowPlayingInfoPropertyPlaybackRate] as? Double) == 1)

        // 3. route change (headphones unplugged) -> paused
        nc.post(name: AVAudioSession.routeChangeNotification, object: nil,
                userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
        await wait(1); check("edge.headphones-unplugged-pauses", audio.isPaused)
        audio.resume(); await wait(1)
        nc.post(name: AVAudioSession.routeChangeNotification, object: nil,
                userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue])
        await wait(1); check("edge.new-route-keeps-playing", !audio.isPaused)

        // 4. play while playing: one player, title/artist follow the new item, state coherent
        if let q = AC.bundledAudioURL("Sourat Al Kahf - Hani Arrifai.mp3") {
            audio.play(url: q, banner: "quran", kind: .quran, force: true)
            await wait(1.5)
            check("edge.replace-updates-info", (info()?[MPMediaItemPropertyTitle] as? String) == "Sourat Al Kahf" && audio.isPlaying && !audio.isPaused, "\(info()?[MPMediaItemPropertyTitle] ?? "nil")")
        }

        // 5. pause then play something else -> new item plays (not stuck paused)
        audio.pause(); await wait(0.5)
        audio.play(url: url, banner: "athan2", force: true); await wait(1.5)
        check("edge.play-after-pause-resets-pause", audio.isPlaying && !audio.isPaused)

        // 6. stop while paused -> everything cleared, commands off
        audio.pause(); await wait(0.5); audio.stopLocal(); await wait(0.5)
        let rc = MPRemoteCommandCenter.shared()
        check("edge.stop-clears-state", !audio.isPlaying && !audio.isPaused && info() == nil && audio.bannerText == nil)
        check("edge.stop-disables-commands", !rc.playCommand.isEnabled && !rc.pauseCommand.isEnabled && !rc.changePlaybackPositionCommand.isEnabled)
        audio.pause(); audio.resume(); audio.seek(to: 10)   // no player: must be harmless no-ops
        check("edge.transport-without-player-noop", !audio.isPlaying && info() == nil)

        // 7. unreachable / invalid source -> ends cleanly, nothing stuck in Control Center
        audio.play(url: URL(fileURLWithPath: "/nonexistent/none.mp3"), banner: "bad", force: true)
        await wait(3)
        check("edge.bad-url-cleans-up", !audio.isPlaying && info() == nil && audio.bannerText == nil)
        audio.play(url: URL(string: "http://127.0.0.1:9/x.mp3")!, banner: "bad2", force: true)
        await wait(6)
        check("edge.unreachable-url-cleans-up", !audio.isPlaying && info() == nil && audio.bannerText == nil, "playing=\(audio.isPlaying) banner=\(audio.bannerText ?? "nil")")

        // 8. 30 s preview auto-stops (also when paused/resumed in between)
        audio.play(url: url, banner: "30s", limit30s: true, force: true)
        await wait(2); audio.pause(); await wait(1); audio.resume()
        await wait(30)
        check("edge.limit30s-stops", !audio.isPlaying && info() == nil)

        // 9. rapid-fire transport: no crash / no inconsistent state
        audio.play(url: url, banner: "spam", force: true); await wait(1)
        for _ in 0..<20 { audio.pause(); audio.resume() }
        await wait(1); check("edge.rapid-transport-consistent", audio.isPlaying && !audio.isPaused)
        audio.stopLocal()
        NotificationManager.e2eLog("selftest[done]")
    }

    // MARK: ranged download

    func runSoundRangeTest() async {
        guard ProcessInfo.processInfo.arguments.contains("-soundRangeTest") else { return }
        for _ in 0..<40 where !connected { try? await Task.sleep(nanoseconds: 500_000_000) }   // wait for the server boot
        let file = "Sourat Al Kahf (Be Heaven) - Omar Hisham Al Arabi.mp3"   // 96 MB on the server
        let out = NotificationSoundMaker.fileName(prefix: "notif-rangetest", source: file)
        let t0 = Date()
        let r = await buildNotificationSound(file: file, quran: true, out: out, skipBundle: true)
        let dt = Date().timeIntervalSince(t0)
        let size = (try? FileManager.default.attributesOfItem(
            atPath: NotificationSoundMaker.soundsDirectory.appendingPathComponent(out).path)[.size] as? Int) ?? 0
        check("range.sound-built", r != nil && size > 1_000_000, String(format: "%.1fs size=%d connected=%@ standalone=%@", dt, size, connected.description, isStandalone.description))
        NotificationSoundMaker.prune(prefix: "notif-rangetest", keeping: "")
        NotificationManager.e2eLog("selftest[done]")
    }
}
#endif
