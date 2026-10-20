import AppKit
import AVFoundation
import DanteKit
import Observation
import WebKit

/// Plays a motion piece in Dante: the scene in a web view scaled to fit, its clock driven by
/// the runtime, the narration track in step with it, and renders in the background.
@MainActor @Observable
final class MotionPlayer {
    private(set) var source: MotionSource?
    private(set) var time = 0.0
    private(set) var playing = false
    private(set) var ready = false
    private(set) var errors: [String] = []
    /// The narration as one sound file, with each line's length, once spoken.
    private(set) var narration: NarrationTrack.Result?
    private(set) var speakingNarration = false
    var showsCaptions = true
    /// A render in progress: quality and 0…1.
    private(set) var rendering: (quality: MotionRenderer.Quality, progress: Double)?
    private(set) var lastRender: URL?
    private(set) var renderError: String?

    @ObservationIgnored private(set) var web: WKWebView?
    @ObservationIgnored private var audio: AVAudioPlayer?
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var refused: (String) -> Bool = { _ in false }
    @ObservationIgnored private lazy var messages = MotionMessages { [weak self] body in self?.handle(body) }
    /// The host view, told to lay the web view out again.
    @ObservationIgnored var onWebView: ((WKWebView) -> Void)?

    var duration: Double { source?.piece.duration ?? 0 }

    /// Loads (or reloads) the piece, keeping the time.
    func load(_ source: MotionSource, refused: @escaping (String) -> Bool) {
        let keep = self.source?.folder == source.folder ? time : 0
        guard source != self.source else { return }
        self.refused = refused
        self.source = source
        ready = false
        errors = []
        playing = false
        audio?.stop()
        let web = source.makeWebView(mode: .preview, pixelRatio: Double(NSScreen.main?.backingScaleFactor ?? 2), refused: refused, messages: messages)
        self.web = web
        web.load(URLRequest(url: source.url))
        time = min(keep, source.piece.duration)
        onWebView?(web)
        prepareNarration()
    }

    private func handle(_ body: [String: Any]) {
        switch body["type"] as? String {
        case "ready":
            ready = true
            if time > 0 { go(time) }
        case "time":
            time = (body["t"] as? Double) ?? time
            if let playing = body["playing"] as? Bool, !playing { stopAudio() }
        case "paused":
            time = (body["t"] as? Double) ?? time
            playing = false
            stopAudio()
        case "error":
            let message = MotionRenderer.describe(body)
            if !errors.contains(message) { errors.append(message) }
        default: break
        }
    }

    func togglePlay() { playing ? pause() : play() }

    func play() {
        guard ready else { return }
        if time >= duration - 0.01 { time = 0 }
        playing = true
        web?.evaluateJavaScript("dante.play(\(time))")
        startAudio(at: time)
    }

    func pause() {
        playing = false
        web?.evaluateJavaScript("dante.pause()")
        stopAudio()
    }

    func go(_ t: Double) {
        time = min(max(0, t), duration)
        web?.evaluateJavaScript("dante.go(\(time))")
        if playing { startAudio(at: time) }
    }

    /// For a deck: the next or previous stop.
    func step(_ forward: Bool) {
        guard let piece = source?.piece else { return }
        pause()
        go(forward ? piece.nextStop(after: time) : piece.previousStop(before: time))
    }

    // MARK: Narration

    private func prepareNarration() {
        guard let piece = source?.piece, !piece.narration.isEmpty, NaturalVoice.isInstalled() else { narration = nil; return }
        let voice = source?.brand.voice.nonEmpty ?? NaturalVoice.voice(Preferences.shared.naturalVoice)
        let speed = NaturalVoice.speed(forRate: Preferences.shared.speechRate)
        speakingNarration = true
        Task {
            let track = await NarrationTrack.make(piece, voice: voice, speed: speed)
            guard self.source?.piece == piece else { return }
            narration = track
            speakingNarration = false
            audio = track.flatMap { try? AVAudioPlayer(contentsOf: $0.url) }
            audio?.prepareToPlay()
            if playing { startAudio(at: time) }
        }
    }

    private func startAudio(at t: Double) {
        guard let audio, t < audio.duration else { return }
        audio.currentTime = t
        audio.play()
    }

    private func stopAudio() { audio?.pause() }

    /// The line being spoken now.
    var caption: String? {
        guard let piece = source?.piece else { return nil }
        return piece.line(at: time, lengths: narration?.lengths ?? piece.narration.map { Double($0.text.split(separator: " ").count) / 2.5 })?.text
    }

    // MARK: Rendering

    /// Renders an MP4 into the piece's `renders/` folder.
    func render(_ quality: MotionRenderer.Quality) {
        guard let source, rendering == nil else { return }
        pause()
        renderError = nil
        rendering = (quality, 0)
        let output = source.folder.appending(path: "renders/\(source.folder.lastPathComponent)-\(quality.rawValue).mp4")
        let refused = self.refused
        renderTask = Task {
            do {
                let narration = self.narration?.url
                try await MotionRenderer.video(source: source, quality: quality, narration: narration, to: output, refused: refused) { value in
                    self.rendering = (quality, value)
                }
                lastRender = output
            } catch is CancellationError {
            } catch {
                renderError = error.localizedDescription
            }
            rendering = nil
        }
    }

    func cancelRender() {
        renderTask?.cancel()
    }

    func stop() {
        pause()
        renderTask?.cancel()
        web = nil
    }
}
