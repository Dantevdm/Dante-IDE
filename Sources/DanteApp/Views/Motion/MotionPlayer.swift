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
    /// What the progress over the stage says.
    private(set) var renderTitle = ""
    /// No narration: the right-hand piece when comparing two versions.
    var muted = false
    private(set) var lastRender: URL?
    private(set) var renderError: String?
    /// What an export couldn't carry, or another note about the last file written.
    private(set) var exportNote: String?
    /// What Dante's lint finds in the scene.
    private(set) var lint: [MotionLint.Finding] = []
    /// Preview in Dante, or presenting on the Stage (a deck holds at each stop).
    private(set) var mode = MotionRuntime.Mode.preview

    @ObservationIgnored private(set) var web: WKWebView?
    @ObservationIgnored private var audio: AVAudioPlayer?
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var audioStop: Task<Void, Never>?
    @ObservationIgnored private var refused: (String) -> Bool = { _ in false }
    @ObservationIgnored private lazy var messages = MotionMessages { [weak self] body in self?.handle(body) }
    /// The host view, told to lay the web view out again.
    @ObservationIgnored var onWebView: ((WKWebView) -> Void)?

    var duration: Double { source?.piece.duration ?? 0 }

    /// Loads (or reloads) the piece, keeping the time.
    func load(_ source: MotionSource, refused: @escaping (String) -> Bool, mode: MotionRuntime.Mode = .preview) {
        let keep = self.source?.folder == source.folder ? time : 0
        guard source != self.source || mode != self.mode else { return }
        self.refused = refused
        self.source = source
        self.mode = mode
        lint = MotionLint.check(MotionLint.sceneFiles(in: source.folder), brand: source.brand)
        ready = false
        errors = []
        playing = false
        audio?.stop()
        let web = source.makeWebView(mode: mode, pixelRatio: Double(NSScreen.main?.backingScaleFactor ?? 2), refused: refused, messages: messages)
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
            // Presenting, a slide holds while the line being said finishes.
            if mode == .present { finishLine() } else { stopAudio() }
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

    /// Presenting: plays on to the next stop (a deck) or plays and pauses (anything else);
    /// back goes to the slide before.
    func advance(_ forward: Bool) {
        guard ready, let piece = source?.piece else { return }
        guard piece.kind == .deck else {
            if forward { togglePlay() } else { go(max(0, time - 5)) }
            return
        }
        if forward {
            guard time < duration - 0.01 else { return }
            playing = true
            web?.evaluateJavaScript("dante.next()")
            startAudio(at: time)
        } else {
            let back = piece.stops.filter { $0 < time - 0.05 }.last ?? 0
            pause()
            go(back)
        }
    }

    /// The slide being shown and how many there are, for a deck.
    var slide: (index: Int, count: Int)? {
        guard let piece = source?.piece, piece.kind == .deck else { return nil }
        let holds = piece.stops.filter { $0 > 0.05 && $0 < piece.duration - 0.05 } + [piece.duration]
        let index = holds.firstIndex { time <= $0 + 0.01 } ?? holds.count - 1
        return (index + 1, holds.count)
    }

    /// For a deck: the next or previous stop.
    func step(_ forward: Bool) {
        guard let piece = source?.piece else { return }
        pause()
        go(forward ? piece.nextStop(after: time) : piece.previousStop(before: time))
    }

    // MARK: Narration

    private func prepareNarration() {
        guard !muted, let piece = source?.piece, !piece.narration.isEmpty, NaturalVoice.isInstalled() else { narration = nil; return }
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
        audioStop?.cancel()
        guard let audio, t < audio.duration else { return }
        audio.currentTime = t
        audio.play()
    }

    private func stopAudio() {
        audioStop?.cancel()
        audio?.pause()
    }

    /// Lets the line being said at a hold finish, then stops.
    private func finishLine() {
        guard let piece = source?.piece, let audio, audio.isPlaying else { return }
        let lengths = narration?.lengths ?? []
        let index = piece.narration.lastIndex { $0.at <= time }
        let end = index.map { piece.narration[$0].at + (lengths[safe: $0] ?? 0) } ?? time
        let wait = max(0, end - audio.currentTime)
        audioStop?.cancel()
        audioStop = Task {
            try? await Task.sleep(for: .seconds(wait))
            if !Task.isCancelled, !self.playing { self.audio?.pause() }
        }
    }

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
        renderTitle = "Rendering \(quality.rawValue), frame by frame"
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

    /// Writes the piece as one HTML file that plays in any browser.
    func exportWebPage() {
        guard let source else { return }
        renderError = nil
        exportNote = nil
        do {
            let (file, missing) = try MotionExporter.webPage(source: source, refused: refused)
            lastRender = file
            if !missing.isEmpty { exportNote = "Not carried in the page: " + missing.prefix(4).joined(separator: ", ") + (missing.count > 4 ? " and \(missing.count - 4) more" : "") }
        } catch {
            renderError = error.localizedDescription
        }
    }

    /// Writes a PDF: a deck's slides, or a storyboard.
    func exportPDF() {
        guard let source, rendering == nil else { return }
        pause()
        renderError = nil
        exportNote = nil
        rendering = (.hd, 0)
        renderTitle = source.piece.kind == .deck ? "Drawing the slides" : "Drawing the storyboard"
        let refused = self.refused
        let lengths = narration?.lengths ?? []
        renderTask = Task {
            do {
                lastRender = try await MotionExporter.pdf(source: source, lengths: lengths, refused: refused) { value in self.rendering = (.hd, value) }
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
