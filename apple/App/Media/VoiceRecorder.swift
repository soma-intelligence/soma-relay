import AVFoundation
import Foundation
import Observation

/// Hold-to-record voice notes: AAC-LC 32 kbps mono m4a, with live levels for the waveform.
@Observable
final class VoiceRecorder: NSObject {
    private(set) var recording = false
    private(set) var levels: [Float] = []
    private(set) var elapsed: TimeInterval = 0
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var meter: Task<Void, Never>?
    @ObservationIgnored private var url: URL?

    struct Note {
        var data: Data
        var durationMs: Int
        var levels: [Float]
    }

    func start() async -> Bool {
        guard await AVAudioApplication.requestRecordPermission() else { return false }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try? session.setActive(true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 24_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        guard let recorder = try? AVAudioRecorder(url: url, settings: settings) else { return false }
        recorder.isMeteringEnabled = true
        guard recorder.record(forDuration: 300) else { return false }
        self.recorder = recorder
        self.url = url
        levels = []
        elapsed = 0
        recording = true
        meter = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(80))
                guard let self, let r = self.recorder else { return }
                r.updateMeters()
                let db = r.averagePower(forChannel: 0)
                self.levels.append(max(0.04, min(1, pow(10, db / 40))))
                self.elapsed = r.currentTime
            }
        }
        return true
    }

    /// Stops and returns the note, or nil if it was shorter than half a second (or cancelled).
    func stop(cancel: Bool = false) -> Note? {
        meter?.cancel()
        let duration = recorder?.currentTime ?? 0
        recorder?.stop()
        recorder = nil
        recording = false
        defer { if let url { try? FileManager.default.removeItem(at: url) } }
        guard !cancel, duration >= 0.5, let url, let data = try? Data(contentsOf: url) else { return nil }
        return Note(data: data, durationMs: Int(duration * 1000), levels: Self.downsample(levels, to: 48))
    }

    static func downsample(_ values: [Float], to count: Int) -> [Float] {
        guard values.count > count else { return values + Array(repeating: 0.05, count: max(0, count - values.count)) }
        let step = Double(values.count) / Double(count)
        return (0..<count).map { i in
            let slice = values[Int(Double(i) * step)..<min(values.count, Int(Double(i + 1) * step))]
            return slice.max() ?? 0.05
        }
    }
}

/// Plays one sealed voice note at a time.
@Observable
final class VoicePlayer: NSObject, AVAudioPlayerDelegate {
    private(set) var playing: String?
    private(set) var progress: Double = 0
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    func toggle(id: String, data: Data?) {
        if playing == id {
            stop()
            return
        }
        stop()
        guard let data, let player = try? AVAudioPlayer(data: data) else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.delegate = self
        player.play()
        self.player = player
        playing = id
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, let p = self.player, p.duration > 0 else { return }
                self.progress = p.currentTime / p.duration
            }
        }
    }

    func stop() {
        ticker?.cancel()
        player?.stop()
        player = nil
        playing = nil
        progress = 0
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}
