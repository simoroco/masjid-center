import Foundation
import AVFoundation
import Combine
import MediaPlayer
import UIKit

// MARK: - AudioManager — AVPlayer equivalent of the web app's <audio> element.
// `volume` (Settings → Audio control → In app) scales every playback made on the iPhone.
// Every playback is mirrored in iOS's native player (Control Center, lock
// screen, headset buttons): Now Playing info + remote commands.

@MainActor
final class AudioManager: ObservableObject {
    /// What is playing — drives the native player's title.
    enum Kind {
        case athan, quran
        var title: String { self == .athan ? "Athan call" : "Sourat Al Kahf" }
    }

    @Published var isPlaying = false              // a local player exists (playing OR paused)
    @Published var isPaused = false               // …and it is currently paused
    @Published var bannerText: String? = nil      // nil = hidden
    @Published var playingIsPrayer = false        // prayer audio keeps card pulsing
    @Published var serverPlaying = false          // audio currently playing on the Pi (stop = API call)

    /// True while ANY audio (local playback or server playback) is active → a stop control must be visible.
    var isActive: Bool { isPlaying || serverPlaying || bannerText != nil }
    private var serverBannerTask: Task<Void, Never>?

    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private var rateObserver: NSKeyValueObservation?
    private var stopTimer: Task<Void, Never>?
    private var kind: Kind = .athan
    private var artist = "Masjid Center"

    /// Master gate wired to "iOS notifications" (Settings → General): when it
    /// returns false the app emits no sound at all, whatever is configured in
    /// Athan call / Tasbih & Objectives / Quran recitation.
    var playbackGate: (() -> Bool)?

    /// Playback volume 0…1 (relative to the iPhone's own volume); live-applied.
    var volume: Float = 1.0 {
        didSet { player?.volume = volume }
    }

    private static let skipInterval: TimeInterval = 15
    private var remoteCommands: [MPRemoteCommand] = []

    /// Commands are only advertised while a player exists, so the app never
    /// competes with Music/podcasts for headset buttons when it is silent.
    private func setRemoteCommandsEnabled(_ on: Bool) {
        remoteCommands.forEach { $0.isEnabled = on }
    }

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        setupRemoteCommands()
        observeSession()
    }

    /// Play an audio URL (remote or bundled). `limit30s` trims like the web 30s
    /// previews; `startAt` resumes mid-file (continuing a notification sound).
    func play(url: URL, banner: String, kind: Kind = .athan, limit30s: Bool = false,
              isPrayer: Bool = false, startAt: TimeInterval = 0, force: Bool = false) {
        // `force`: an explicit tap on a play button always sounds — the master
        // switch only mutes what the app starts by itself.
        guard force || (playbackGate?() ?? true) else { return }
        stopLocal(deactivateSession: false)
        try? AVAudioSession.sharedInstance().setActive(true)
        self.kind = kind
        artist = Self.displayName(of: url)
        bannerText = banner
        playingIsPrayer = isPrayer
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        player = p
        p.volume = volume
        if startAt > 0 { p.seek(to: CMTime(seconds: startAt, preferredTimescale: 600)) }
        p.play()
        isPlaying = true
        isPaused = false
        setRemoteCommandsEnabled(true)
        updateNowPlaying()

        if limit30s {
            stopTimer?.cancel()
            stopTimer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.stopLocal()
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleEnded() }
        }
        statusObserver = item.observe(\.status) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                if item.status == .failed { self.handleEnded() }
                else if item.status == .readyToPlay { self.updateNowPlaying() }   // duration known
            }
        }
        // Single source of truth for pause/play, whoever triggers it (our
        // buttons, Control Center, a phone call, unplugged headphones).
        rateObserver = p.observe(\.timeControlStatus) { [weak self] p, _ in
            Task { @MainActor in
                guard let self, self.player === p else { return }
                let paused = p.timeControlStatus == .paused
                guard paused != self.isPaused else { return }
                self.isPaused = paused
                self.updateNowPlaying()
            }
        }
    }

    private func handleEnded() {
        stopTimer?.cancel()
        isPlaying = false
        isPaused = false
        playingIsPrayer = false
        bannerText = nil
        cleanupPlayer()
        releaseSession()
    }

    /// Stop only local playback (equivalent of audioElement.pause()).
    func stopLocal(deactivateSession: Bool = true) {
        serverBannerTask?.cancel()
        serverPlaying = false
        stopTimer?.cancel()
        player?.pause()
        cleanupPlayer()
        isPlaying = false
        isPaused = false
        playingIsPrayer = false
        bannerText = nil
        if deactivateSession { releaseSession() }
    }

    private func cleanupPlayer() {
        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
        endObserver = nil
        statusObserver = nil
        rateObserver = nil
        player = nil
        setRemoteCommandsEnabled(false)
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
    }

    /// Lets other apps' audio (Music, podcasts…) resume once ours is over.
    private func releaseSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Transport (shared by the in-app UI and the native player)

    func pause() {
        guard let player, !isPaused else { return }
        player.pause()
        isPaused = true
        updateNowPlaying()
    }

    func resume() {
        guard let player, isPaused else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        player.volume = volume
        player.play()
        isPaused = false
        updateNowPlaying()
    }

    func seek(to seconds: TimeInterval) {
        guard let player else { return }
        let t = max(0, seconds)
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.updateNowPlaying() }
        }
    }

    var currentTime: TimeInterval {
        guard let t = player?.currentTime().seconds, t.isFinite else { return 0 }
        return t
    }

    // MARK: Now Playing + remote commands

    /// File name without extension: "Intro & Athan - Omar Hisham Al Arabi".
    private static func displayName(of url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        return name == "default_athan" ? "Athan (Nice An-Nour Institute)" : name
    }

    /// Dark-blue tile with the white app logo (the logo asset is a template).
    private static let artwork: MPMediaItemArtwork = {
        let size = CGSize(width: 600, height: 600)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(red: 0x11 / 255, green: 0x4B / 255, blue: 0xB2 / 255, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            if let logo = UIImage(named: "logo")?.withTintColor(.white, renderingMode: .alwaysOriginal) {
                logo.draw(in: CGRect(x: 130, y: 130, width: 340, height: 340))
            }
        }
        return MPMediaItemArtwork(boundsSize: size) { _ in image }
    }()

    /// Publishes title / position / state to Control Center + lock screen.
    func updateNowPlaying() {
        guard let player, let item = player.currentItem else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: kind.title,
            MPMediaItemPropertyArtist: artist,
            MPMediaItemPropertyAlbumTitle: "Masjid Center",
            MPMediaItemPropertyArtwork: Self.artwork,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPaused ? 0.0 : 1.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        let d = item.duration.seconds
        if d.isFinite, d > 0 { info[MPMediaItemPropertyPlaybackDuration] = d }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = isPaused ? .paused : .playing
    }

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        // Handlers may run off the main thread: hop to the main actor, answer at once.
        func on(_ cmd: MPRemoteCommand, _ body: @escaping @MainActor (AudioManager) -> Void) {
            remoteCommands.append(cmd)
            cmd.addTarget { [weak self] _ in
                guard let self else { return .noActionableNowPlayingItem }
                Task { @MainActor in body(self) }
                return .success
            }
        }
        on(c.playCommand) { $0.resume() }
        on(c.pauseCommand) { $0.pause() }
        on(c.togglePlayPauseCommand) { $0.isPaused ? $0.resume() : $0.pause() }
        on(c.stopCommand) { $0.stopLocal() }

        c.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        c.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        on(c.skipForwardCommand) { $0.seek(to: $0.currentTime + Self.skipInterval) }
        on(c.skipBackwardCommand) { $0.seek(to: $0.currentTime - Self.skipInterval) }

        remoteCommands.append(c.changePlaybackPositionCommand)
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let e = event as? MPChangePlaybackPositionCommandEvent
            else { return .commandFailed }
            let t = e.positionTime
            Task { @MainActor in self.seek(to: t) }
            return .success
        }
        setRemoteCommandsEnabled(false)
    }

    /// Phone call / Siri / alarm → AVPlayer pauses itself (rateObserver picks it
    /// up); resume when iOS says so. Unplugged headphones → pause, never blast
    /// the athan on the speaker.
    private func observeSession() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let type = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let opts = (n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init)
            Task { @MainActor in
                guard let self else { return }
                if type == .began { self.pause() }
                else if type == .ended, opts?.contains(.shouldResume) == true { self.resume() }
            }
        }
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            let reason = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            if reason == .oldDeviceUnavailable { Task { @MainActor in self?.pause() } }
        }
    }

    func hideBanner() { bannerText = nil }

    /// Banner for audio played by the server; auto-clears (the Pi gives no end-of-playback event).
    func showServerBanner(_ text: String, duration: TimeInterval) {
        serverPlaying = true
        bannerText = text
        serverBannerTask?.cancel()
        serverBannerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.clearServerBanner()
        }
    }

    func clearServerBanner() {
        serverBannerTask?.cancel()
        guard serverPlaying else { return }
        serverPlaying = false
        if !isPlaying { bannerText = nil }
    }
}
