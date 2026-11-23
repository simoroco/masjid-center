import Foundation
import AVFoundation

// MARK: - NotificationSoundMaker — turns any audio file into an
// iOS-notification-ready sound.
// UNNotificationSound only accepts Linear PCM / IMA4 in .aif/.wav/.caf,
// under 30 seconds, located in the app bundle or Library/Sounds.
// Configured feature sounds are .mp3 (bundled or fetched from the server),
// so they are decoded with AVAssetReader and re-encoded as 16-bit mono LPCM
// in a .caf, trimmed to maxSeconds.

enum NotificationSoundMaker {

    /// Library/Sounds — the only writable location the notification center
    /// searches for custom sounds.
    static var soundsDirectory: URL {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let dir = lib.appendingPathComponent("Sounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func soundExists(_ name: String) -> Bool {
        !name.isEmpty && FileManager.default.fileExists(
            atPath: soundsDirectory.appendingPathComponent(name).path)
    }

    static func delete(_ name: String) {
        guard !name.isEmpty else { return }
        try? FileManager.default.removeItem(at: soundsDirectory.appendingPathComponent(name))
    }

    /// Decodes `source` (mp3/m4a/wav/…) and writes a notification-ready .caf
    /// at `destination` (LPCM 16-bit mono 44.1 kHz, at most `maxSeconds`).
    /// Returns true when a non-empty file was produced.
    static func make(from source: URL, to destination: URL, maxSeconds: Double = 29) async -> Bool {
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: destination)
            let asset = AVURLAsset(url: source)
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
                  let reader = try? AVAssetReader(asset: asset) else { return false }

            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            guard reader.canAdd(output) else { return false }
            reader.add(output)

            guard let writer = try? AVAssetWriter(outputURL: destination, fileType: .caf) else { return false }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { return false }
            writer.add(input)

            guard reader.startReading(), writer.startWriting() else { return false }
            writer.startSession(atSourceTime: .zero)

            let limit = CMTime(seconds: maxSeconds, preferredTimescale: 600)
            var reachedLimit = false
            while reader.status == .reading {
                guard let buffer = output.copyNextSampleBuffer() else { break }
                if CMSampleBufferGetPresentationTimeStamp(buffer) >= limit { reachedLimit = true; break }
                // A not-ready input would silently drop the sample — wait
                // briefly instead so the decoded track is written intact.
                while !input.isReadyForMoreMediaData {
                    if reader.status != .reading { break }
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                input.append(buffer)
            }
            input.markAsFinished()
            await writer.finishWriting()
            reader.cancelReading()

            guard writer.status == .completed || reachedLimit,
                  let size = try? FileManager.default.attributesOfItem(
                      atPath: destination.path)[.size] as? Int, size > 44 else {
                try? FileManager.default.removeItem(at: destination)
                return false
            }
            return true
        }.value
    }
}
