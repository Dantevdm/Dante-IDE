import AppKit
import AVFoundation
import Carbon.HIToolbox
import DanteKit
import Observation
import Speech

/// Talking to Claude through the orb. ⌃⌥Space (anywhere), the panel's mic or, when it's on,
/// "Hey Dante" starts listening; it sends after a pause, or on the key again. Speech is
/// recognised on this Mac. A few phrases Dante handles itself (stop, yes, no, switch to a
/// project, full screen, minimise, status, usage, thanks); anything else goes to Claude in the
/// frontmost project. Claude's reply is read out sentence by sentence as it streams, and in a
/// conversation Dante listens again when it has finished speaking.
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
    /// 0…1, the voice's loudness (yours while listening, Dante's while speaking), for the orb.
    private(set) var level: Double = 0
    /// The sentence being read out.
    private(set) var saying: String?
    /// In a spoken conversation: after a reply, Dante listens again without the key.
    private(set) var conversing = false
    /// Listening in the background for "Hey Dante".
    private(set) var wakeListening = false
    /// Why "Hey Dante" can't work on this Mac, for Settings.
    private(set) var wakeProblem: String?

    var isSpeaking: Bool { saying != nil }

    private enum Mode { case off, command, wake }

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var recognizer = SFSpeechRecognizer()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var mode: Mode = .off
    /// Bumped for each recognition task, so a cancelled task's late results are ignored.
    @ObservationIgnored private var generation = 0
    /// The command started inside a wake task: what's heard is what follows the wake phrase.
    @ObservationIgnored private var afterWake = false
    @ObservationIgnored private var followUp = false
    @ObservationIgnored private var silenceTimer: Timer?
    @ObservationIgnored private var wakeTimer: Timer?
    @ObservationIgnored private var wakeFailures = 0
    @ObservationIgnored private var levelTimer: Timer?
    @ObservationIgnored private let speaker = AVSpeechSynthesizer()
    @ObservationIgnored private let speech = SpeechDelegate()
    @ObservationIgnored private var hotKey: EventHotKeyRef?
    @ObservationIgnored private weak var answering: Session?
    /// Items already in the transcript when the spoken request went in; later replies are read.
    @ObservationIgnored private var answeredFrom = 0
    @ObservationIgnored private var streams: [String: SpokenStream] = [:]
    @ObservationIgnored private var spokeThisTurn = false

    /// The talk key, shown in menus and tooltips.
    static let keyLabel = "⌃⌥Space"
    /// How long a pause ends what you're saying.
    static let pause: TimeInterval = 1.6
    /// How long Dante waits for a follow-up before the conversation ends.
    static let followUpWait: TimeInterval = 6

    private init() {
        speaker.delegate = speech
    }

    // MARK: The talk key

    /// Registers ⌃⌥Space system-wide (Carbon hot keys need no Accessibility permission) and
    /// starts listening for "Hey Dante" if that's on.
    func install() {
        guard hotKey == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { VoiceController.shared.toggle() } }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x44414E54), id: 1) // "DANT"
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
        updateWakeListening()
    }

    func toggle() {
        switch state {
        case .listening: finish()
        default: start()
        }
    }

    // MARK: Listening

    func start() {
        stopSpeaking()
        Task { await begin() }
    }

    private func begin(followUp: Bool = false) async {
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
        guard startRecognition(.command, recognizer: recognizer) else { return }
        self.followUp = followUp
        if followUp { NSSound(named: "Tink")?.play() }
        heard = ""
        state = .listening
        PresenceController.shared.voiceChanged()
        armSilence()
    }

    /// Starts the microphone and a recognition task. False (with the reason shown) when the
    /// microphone won't start.
    private func startRecognition(_ mode: Mode, recognizer: SFSpeechRecognizer) -> Bool {
        stopAudio()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        request.addsPunctuation = true
        request.contextualStrings = Sessions.all.compactMap { $0.workspace?.name } + ["Claude", "Dante", "Hey Dante", "commit", "pull request", "refactor"]
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(request: request))
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.request = nil
            if mode == .command {
                state = .unavailable("Couldn’t start the microphone: \(error.localizedDescription)")
                PresenceController.shared.voiceChanged()
            }
            return false
        }
        self.mode = mode
        afterWake = false
        generation += 1
        let current = generation
        task = recognizer.recognitionTask(with: request) { @Sendable result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in VoiceController.shared.recognised(text, final: final, failed: failed, generation: current) }
        }
        return true
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

    private func recognised(_ text: String?, final: Bool, failed: Bool, generation: Int) {
        guard generation == self.generation else { return }
        switch mode {
        case .off:
            return
        case .wake:
            if let text, let rest = WakeWord.command(in: text) {
                woke(saying: rest)
            } else if final || failed {
                wakeEnded(failed: failed)
            }
        case .command:
            guard state == .listening else { return }
            let said = afterWake ? text.flatMap(WakeWord.command(in:)) ?? heard : text ?? heard
            if said != heard {
                heard = said
                armSilence()
            }
            if final || failed { finish() }
        }
    }

    /// Sends once you've paused; with nothing said, gives up after a while.
    private func armSilence() {
        silenceTimer?.invalidate()
        let wait = heard.isEmpty ? (followUp ? Self.followUpWait : 6) : Self.pause
        silenceTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { _ in
            MainActor.assumeIsolated { VoiceController.shared.finish() }
        }
    }

    /// Stops listening and acts on what was heard.
    func finish() {
        guard state == .listening else { return }
        let text = heard
        stopAudio()
        state = answering == nil ? .idle : .waiting
        level = 0
        PresenceController.shared.voiceChanged()
        act(on: VoiceCommand.parse(text, projects: Sessions.all.compactMap { $0.workspace?.name }))
        updateWakeListening()
    }

    func cancel() {
        stopAudio()
        stopSpeaking()
        conversing = false
        answering = nil
        state = .idle
        level = 0
        PresenceController.shared.voiceChanged()
        updateWakeListening()
    }

    private func stopAudio() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        wakeTimer?.invalidate()
        wakeTimer = nil
        mode = .off
        wakeListening = false
        generation += 1
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    // MARK: Hey Dante

    /// Listens for the wake word when it's on and nothing else is using the microphone or
    /// speaker; stops when that changes.
    func updateWakeListening() {
        let wanted = Preferences.shared.listensForWakeWord && !isSpeaking && (state == .idle || state == .waiting)
            && !(conversing && answering == nil)
        if wanted, !wakeListening, mode == .off {
            Task { await startWake() }
        } else if !wanted, wakeListening {
            stopAudio()
        }
    }

    private func startWake() async {
        // Only once permission is given: turning the setting on asks for it.
        guard await Self.authorised() else {
            wakeProblem = "Dante needs the microphone and speech recognition. Allow them in System Settings › Privacy & Security."
            return
        }
        guard let recognizer, recognizer.isAvailable else { return }
        // Listening all the time is only acceptable if nothing leaves the Mac.
        guard recognizer.supportsOnDeviceRecognition else {
            wakeProblem = "This Mac can’t recognise speech offline, so Dante won’t listen in the background."
            return
        }
        guard Preferences.shared.listensForWakeWord, mode == .off, !isSpeaking, state == .idle || state == .waiting else { return }
        wakeProblem = nil
        guard startRecognition(.wake, recognizer: recognizer) else {
            wakeProblem = "Couldn’t start the microphone."
            return
        }
        wakeListening = true
        // Recognition tasks wind down after a minute or so; start a fresh one before that.
        wakeTimer = Timer.scheduledTimer(withTimeInterval: 50, repeats: false) { _ in
            MainActor.assumeIsolated {
                let voice = VoiceController.shared
                guard voice.mode == .wake else { return }
                voice.stopAudio()
                voice.updateWakeListening()
            }
        }
    }

    /// "Hey Dante" heard: the same recognition carries on as a command, so nothing said
    /// straight after is lost.
    private func woke(saying rest: String) {
        wakeTimer?.invalidate()
        wakeTimer = nil
        wakeFailures = 0
        wakeListening = false
        mode = .command
        afterWake = true
        followUp = false
        NSSound(named: "Tink")?.play()
        heard = rest
        state = .listening
        PresenceController.shared.voiceChanged()
        armSilence()
    }

    private func wakeEnded(failed: Bool) {
        stopAudio()
        wakeFailures = failed ? wakeFailures + 1 : 0
        // Back off when recognition keeps failing, so a broken setup doesn't spin.
        let delay = failed ? min(30, pow(2, Double(wakeFailures))) : 0.2
        Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated { VoiceController.shared.updateWakeListening() }
        }
    }

    // MARK: Acting

    /// The session spoken to: the frontmost project's, else one where Claude is busy or waiting.
    private var target: Session? {
        ActiveProject.shared.session
            ?? Sessions.all.first { $0.waitingConversation != nil }
            ?? Sessions.all.first { $0.claude?.state == .working }
            ?? Sessions.all.first { $0.workspace != nil }
    }

    private func act(on command: VoiceCommand) {
        switch command {
        case .cancel:
            // Silence after a reply ends the conversation quietly.
            if followUp { conversing = false }
        case .goodbye:
            conversing = false
            say(["Anytime.", "Sure.", "Okay."].randomElement() ?? "Okay.")
        case .stop:
            for claude in Sessions.all.flatMap(\.allConversations) where claude.state == .working { claude.interrupt() }
            answering = nil
            if state == .waiting { state = .idle }
            say("Stopped.")
        case .show(let project):
            guard let session = Sessions.all.first(where: { $0.workspace?.name == project }) else { return }
            NSApp.activate()
            session.window?.makeKeyAndOrderFront(nil)
            say("Here’s \(project).")
        case .approve:
            guard let session = target, let claude = session.waitingConversation?.claude else { return say("Nothing’s waiting.") }
            for tool in claude.pendingApprovals { claude.approve(tool.id) }
            // Replies are read out from the main conversation; a job carries on by itself.
            guard claude === session.claude else { return say("Okay, the job carries on.") }
            conversing = Preferences.shared.keepsConversation
            listenForReply(in: session, from: claude.items.count)
        case .decline:
            guard let claude = target?.waitingConversation?.claude else { return say("Nothing’s waiting.") }
            for tool in claude.pendingApprovals { claude.decline(tool.id) }
            say("Okay, I won’t.")
        case .stage(let open):
            if open {
                StageController.shared.open()
            } else {
                StageController.shared.close()
                conversing = false
            }
        case .status:
            say(VoiceStatus.summary(PresenceController.shared.model.presence.sources))
        case .usage:
            let model = PresenceController.shared.model
            say(VoiceStatus.usage(share: model.windowShare, resets: model.usageResets,
                                  limitReached: Sessions.all.contains { $0.claude?.limitReachedAt != nil }))
        case .ask(let text):
            guard let session = target else { return say("Open a project first.") }
            let from = session.claude?.items.count ?? 0
            session.askClaude(text)
            conversing = Preferences.shared.keepsConversation
            listenForReply(in: session, from: from)
        }
    }

    /// Reads the reply out as it streams, and says what's waiting for an answer.
    private func listenForReply(in session: Session, from index: Int) {
        answering = session
        answeredFrom = index
        streams = [:]
        spokeThisTurn = false
        state = .waiting
        watch()
    }

    private func watch() {
        guard let session = answering, let claude = session.claude else {
            if state == .waiting { state = .idle }
            return
        }
        let (working, waiting, replies) = withObservationTracking {
            (claude.state == .working, claude.pendingApprovals.first, replies(in: claude))
        } onChange: {
            Task { @MainActor in VoiceController.shared.watch() }
        }
        guard answering === session else { return }
        let lastIndex = replies.last?.index
        for reply in replies {
            // A reply is complete once something follows it or the turn is over.
            let final = !working || waiting != nil || reply.index != lastIndex || reply.index < claude.items.count - 1
            var stream = streams[reply.id] ?? SpokenStream(limit: spokeThisTurn ? 400 : 700)
            let sentences = stream.feed(reply.text, final: final)
            streams[reply.id] = stream
            for sentence in sentences { say(sentence) }
        }
        if let waiting {
            answering = nil
            if state == .waiting { state = .idle }
            let what = [waiting.verb, waiting.target(in: session.workspace?.url ?? claude.root)].filter { !$0.isEmpty }.joined(separator: " ")
            say("Claude wants to \(what.prefix(1).lowercased() + what.dropFirst()). Say yes or no.")
            return
        }
        guard !working else { return }
        answering = nil
        if state == .waiting { state = .idle }
        if !spokeThisTurn { say("Done.") }
        updateWakeListening()
    }

    /// The assistant's text items since the spoken request, in order.
    private func replies(in claude: ClaudeSession) -> [(id: String, index: Int, text: String)] {
        let items = claude.items
        guard answeredFrom < items.count else { return [] }
        return items.indices[answeredFrom...].compactMap { index in
            if case .assistant(let text) = items[index].content, !text.isEmpty { return (items[index].id, index, text) }
            return nil
        }
    }

    // MARK: Speaking

    private func say(_ text: String) {
        guard !text.isEmpty else { return }
        if answering != nil { spokeThisTurn = true }
        guard Preferences.shared.speaksReplies else { return spoke() }
        // The microphone would hear Dante; wake listening pauses while it talks.
        if mode == .wake { stopAudio() }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = Float(min(0.62, max(0.4, Preferences.shared.speechRate)))
        utterance.voice = Self.voice()
        utterance.postUtteranceDelay = 0.08
        if saying == nil { saying = text }
        speaker.speak(utterance)
        PresenceController.shared.voiceChanged()
    }

    func stopSpeaking() {
        speaker.stopSpeaking(at: .immediate)
        saying = nil
        level = 0
        levelTimer?.invalidate()
        levelTimer = nil
    }

    /// Reads a line in the chosen voice, for Settings.
    func preview() {
        stopSpeaking()
        say("Hi, I’m Dante. Ask me anything about your code.")
    }

    /// The chosen voice, else the best English one installed.
    static func voice() -> AVSpeechSynthesisVoice? {
        let chosen = Preferences.shared.voiceIdentifier
        if !chosen.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: chosen) { return voice }
        return voices.first
    }

    /// English voices, best quality first (Premium, then Enhanced), novelty voices left out.
    static var voices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sorted { $0.quality.rawValue != $1.quality.rawValue ? $0.quality.rawValue > $1.quality.rawValue : $0.name < $1.name }
    }

    fileprivate func started(_ utterance: String) {
        saying = utterance
        PresenceController.shared.voiceChanged()
    }

    /// Each word gives the orb a little pulse, so it looks like it's the one talking.
    fileprivate func word() {
        level = 0.55 + Double.random(in: 0...0.35)
        PresenceController.shared.voiceChanged()
        guard levelTimer == nil else { return }
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { _ in
            MainActor.assumeIsolated {
                let voice = VoiceController.shared
                voice.level *= 0.82
                PresenceController.shared.voiceChanged()
            }
        }
    }

    /// The speaker went quiet: listen for a follow-up in a conversation, else go back to
    /// waiting for "Hey Dante".
    fileprivate func spoke() {
        guard !speaker.isSpeaking else { return }
        saying = nil
        level = 0
        levelTimer?.invalidate()
        levelTimer = nil
        PresenceController.shared.voiceChanged()
        if conversing, Preferences.shared.speaksReplies, answering == nil, state == .idle {
            Task { await begin(followUp: true) }
        } else {
            updateWakeListening()
        }
    }

    // MARK: Permissions

    private static func authorised() async -> Bool {
        guard await speechAuthorised() else { return false }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Nonisolated, because macOS answers on a background queue: a closure that inherited the
    /// main actor would trap there when Swift checks its isolation.
    private nonisolated static func speechAuthorised() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in continuation.resume(returning: status == .authorized) }
        }
    }
}

/// Passes the synthesiser's progress to the voice controller on the main actor.
private final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let text = utterance.speechString
        Task { @MainActor in VoiceController.shared.started(text) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        Task { @MainActor in VoiceController.shared.word() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in VoiceController.shared.spoke() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in VoiceController.shared.spoke() }
    }
}
