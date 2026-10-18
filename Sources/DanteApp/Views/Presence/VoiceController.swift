import AppKit
import AVFoundation
import Carbon.HIToolbox
import DanteKit
import Observation
import Speech

/// Talking to Claude through the orb. ⌃⌥Space (anywhere) or the panel's mic starts
/// listening; it sends after a pause, or on the key again. Speech is recognised on this Mac.
/// A few phrases are commands (stop, yes, no, switch to a project, full screen, minimise); anything else goes to
/// Claude in the frontmost project, and the reply is read out when the turn ends.
@MainActor
@Observable
final class VoiceController {
    static let shared = VoiceController()

    enum State: Equatable {
        case idle
        case listening
        /// Sent; waiting to read the reply out.
        case waiting
        case unavailable(String)
    }

    private(set) var state: State = .idle
    /// What's been heard so far.
    private(set) var heard = ""
    /// 0…1, the voice's loudness, for the orb.
    private(set) var level: Double = 0

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var recognizer = SFSpeechRecognizer()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var silenceTimer: Timer?
    @ObservationIgnored private let speaker = AVSpeechSynthesizer()
    @ObservationIgnored private var hotKey: EventHotKeyRef?
    @ObservationIgnored private weak var answering: Session?

    /// The talk key, shown in menus and tooltips.
    static let keyLabel = "⌃⌥Space"
    /// How long a pause ends what you're saying.
    static let pause: TimeInterval = 1.6

    // MARK: The talk key

    /// Registers ⌃⌥Space system-wide. Carbon hot keys need no Accessibility permission.
    func install() {
        guard hotKey == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { VoiceController.shared.toggle() } }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x44414E54), id: 1) // "DANT"
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
    }

    func toggle() {
        switch state {
        case .listening: finish()
        default: start()
        }
    }

    // MARK: Listening

    func start() {
        speaker.stopSpeaking(at: .immediate)
        Task { await begin() }
    }

    private func begin() async {
        guard await Self.authorised() else {
            state = .unavailable("Dante needs the microphone and speech recognition. Allow them in System Settings › Privacy & Security.")
            PresenceController.shared.voiceChanged()
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            state = .unavailable("Speech recognition isn’t available right now.")
            PresenceController.shared.voiceChanged()
            return
        }
        stopAudio()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        request.addsPunctuation = true
        request.contextualStrings = Sessions.all.compactMap { $0.workspace?.name } + ["Claude", "Dante", "commit", "pull request", "refactor"]
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(request: request))
        do {
            engine.prepare()
            try engine.start()
        } catch {
            state = .unavailable("Couldn’t start the microphone: \(error.localizedDescription)")
            PresenceController.shared.voiceChanged()
            return
        }
        heard = ""
        state = .listening
        PresenceController.shared.voiceChanged()
        task = recognizer.recognitionTask(with: request) { result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in VoiceController.shared.recognised(text, final: final, failed: failed) }
        }
        armSilence()
    }

    /// The audio tap: feeds the recogniser and measures loudness. Runs on the audio thread.
    private nonisolated static func tap(request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        nonisolated(unsafe) let request = request
        return { buffer, _ in
            request.append(buffer)
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
            let rms = sqrt(sum / Float(buffer.frameLength))
            let level = Double(min(1, max(0, (20 * log10(max(rms, 1e-6)) + 50) / 40)))
            Task { @MainActor in VoiceController.shared.heard(level: level) }
        }
    }

    private func heard(level: Double) {
        guard state == .listening else { return }
        self.level += (level - self.level) * 0.5
        PresenceController.shared.voiceChanged()
    }

    private func recognised(_ text: String?, final: Bool, failed: Bool) {
        guard state == .listening else { return }
        if let text, text != heard {
            heard = text
            armSilence()
        }
        if final || failed { finish() }
    }

    /// Sends once you've paused.
    private func armSilence() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: heard.isEmpty ? 6 : Self.pause, repeats: false) { _ in
            MainActor.assumeIsolated { VoiceController.shared.finish() }
        }
    }

    /// Stops listening and acts on what was heard.
    func finish() {
        guard state == .listening else { return }
        let text = heard
        stopAudio()
        state = .idle
        level = 0
        PresenceController.shared.voiceChanged()
        act(on: VoiceCommand.parse(text, projects: Sessions.all.compactMap { $0.workspace?.name }))
    }

    func cancel() {
        stopAudio()
        speaker.stopSpeaking(at: .immediate)
        state = .idle
        level = 0
        PresenceController.shared.voiceChanged()
    }

    private func stopAudio() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    // MARK: Acting

    /// The session spoken to: the frontmost project's, else one where Claude is busy or waiting.
    private var target: Session? {
        ActiveProject.shared.session
            ?? Sessions.all.first { $0.claude?.pendingApprovals.isEmpty == false }
            ?? Sessions.all.first { $0.claude?.state == .working }
            ?? Sessions.all.first { $0.workspace != nil }
    }

    private func act(on command: VoiceCommand) {
        switch command {
        case .cancel:
            return
        case .stop:
            for session in Sessions.all where session.claude?.state == .working { session.claude?.interrupt() }
            say("Stopped.")
        case .show(let project):
            guard let session = Sessions.all.first(where: { $0.workspace?.name == project }) else { return }
            NSApp.activate()
            session.window?.makeKeyAndOrderFront(nil)
        case .approve:
            guard let session = target, let claude = session.claude, !claude.pendingApprovals.isEmpty else { return say("Nothing’s waiting.") }
            for tool in claude.pendingApprovals { claude.approve(tool.id) }
            listenForReply(in: session)
        case .decline:
            guard let session = target, let claude = session.claude, !claude.pendingApprovals.isEmpty else { return say("Nothing’s waiting.") }
            for tool in claude.pendingApprovals { claude.decline(tool.id) }
        case .stage(let open):
            if open { StageController.shared.open() } else { StageController.shared.close() }
        case .ask(let text):
            guard let session = target else { return say("Open a project first.") }
            session.askClaude(text)
            listenForReply(in: session)
        }
    }

    /// Reads the reply out when the turn ends, or says what's waiting for an answer.
    private func listenForReply(in session: Session) {
        answering = session
        state = .waiting
        watch()
    }

    private func watch() {
        guard let session = answering, let claude = session.claude else { state = .idle; return }
        let (working, waiting) = withObservationTracking {
            (claude.state == .working, claude.pendingApprovals.first)
        } onChange: {
            Task { @MainActor in VoiceController.shared.watch() }
        }
        if let waiting {
            answering = nil
            state = .idle
            let what = [waiting.verb, waiting.target(in: session.workspace?.url ?? claude.root)].filter { !$0.isEmpty }.joined(separator: " ")
            say("Claude wants to \(what.prefix(1).lowercased() + what.dropFirst()). Say yes or no.")
            return
        }
        guard !working else { return }
        answering = nil
        state = .idle
        let reply = claude.items.last { if case .assistant = $0.content { true } else { false } }
        if case .assistant(let text)? = reply?.content { say(SpokenReply.text(from: text)) }
    }

    private func say(_ text: String) {
        guard Preferences.shared.speaksReplies, !text.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.52
        utterance.voice = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .max { $0.quality.rawValue < $1.quality.rawValue }
        speaker.speak(utterance)
    }

    // MARK: Permissions

    private static func authorised() async -> Bool {
        let speech: Bool = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }
}
