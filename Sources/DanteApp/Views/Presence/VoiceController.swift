import AppKit
import AVFoundation
import Carbon.HIToolbox
import DanteKit
import DanteOpen
import Observation
import os
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
    /// Where the microphone's buffers go; the tap stays installed while recognition tasks
    /// come and go, so the microphone isn't reopened for each one.
    @ObservationIgnored private let tapTarget = TapTarget()
    @ObservationIgnored private var engineStarted = Date.distantPast
    @ObservationIgnored private var configurationObserver: NSObjectProtocol?
    @ObservationIgnored private var recognizer = SFSpeechRecognizer()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var mode: Mode = .off
    /// Bumped for each recognition task, so a cancelled task's late results are ignored.
    @ObservationIgnored private var generation = 0
    /// The command started inside a wake task: what's heard is what follows the wake phrase.
    @ObservationIgnored private var afterWake = false
    /// The command being acted on began with "Hey Dante".
    @ObservationIgnored private var wokeForThis = false
    @ObservationIgnored private var followUp = false
    @ObservationIgnored private var silenceTimer: Timer?
    @ObservationIgnored private var wakeTimer: Timer?
    @ObservationIgnored private var wakeFailures = 0
    /// Words the current wake session has heard, for the log.
    @ObservationIgnored private var wakeWords = 0
    @ObservationIgnored private var levelTimer: Timer?
    @ObservationIgnored private let speaker = AVSpeechSynthesizer()
    @ObservationIgnored private var speechQueue = SpeechQueue()
    /// Utterances handed to the synthesiser and not yet finished or cancelled.
    @ObservationIgnored private var outstanding: Set<ObjectIdentifier> = []
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
        // A headset connecting or going away stops the engine; start again on what's there now.
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { _ in
            MainActor.assumeIsolated { VoiceController.shared.audioConfigurationChanged() }
        }
    }

    /// `log stream --predicate 'subsystem == "dev.dante.ide" && category == "voice"'` shows
    /// each step. What was heard and said stays private; only lengths are public.
    static let log = Logger(subsystem: "dev.dante.ide", category: "voice")

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
        Self.log.info("talk key, state \(String(describing: self.state), privacy: .public)")
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
            Self.log.error("not authorised for the microphone or speech recognition")
            state = .unavailable("Dante needs the microphone and speech recognition. Allow them in System Settings › Privacy & Security.")
            PresenceController.shared.voiceChanged()
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            Self.log.error("speech recognition unavailable")
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
        endRecognition()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        request.addsPunctuation = true
        request.contextualStrings = Sessions.all.compactMap { $0.workspace?.name } + ["Claude", "Dante", "Hey Dante", "commit", "pull request", "refactor"]
        self.request = request

        if !engine.isRunning {
            let input = engine.inputNode
            input.removeTap(onBus: 0)
            if let microphone = Microphones.chosen(preferred: Preferences.shared.microphone) {
                do {
                    try input.auAudioUnit.setDeviceID(microphone.id)
                    Self.log.info("microphone: \(String(describing: microphone.transport), privacy: .public)")
                } catch {
                    Self.log.error("couldn't pick the microphone: \(error.localizedDescription, privacy: .public)")
                }
            }
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(into: tapTarget))
            do {
                engine.prepare()
                try engine.start()
                engineStarted = .now
            } catch {
                Self.log.error("microphone didn't start: \(error.localizedDescription, privacy: .public)")
                input.removeTap(onBus: 0)
                self.request = nil
                if mode == .command {
                    state = .unavailable("Couldn’t start the microphone: \(error.localizedDescription)")
                    PresenceController.shared.voiceChanged()
                }
                return false
            }
        }
        tapTarget.request = request
        self.mode = mode
        Self.log.info("listening (\(mode == .wake ? "wake word" : "command", privacy: .public))")
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

    /// The audio tap: feeds the current recognition request and measures loudness. Runs on
    /// the audio thread.
    private nonisolated static func tap(into target: TapTarget) -> AVAudioNodeTapBlock {
        return { buffer, _ in
            guard let request = target.request else { return }
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
            if failed { Self.log.error("wake recognition failed") }
            wakeWords = text?.split(separator: " ").count ?? wakeWords
            if let text, let rest = WakeWord.command(in: text) {
                Self.log.info("wake word heard")
                woke(saying: rest)
            } else if final || failed {
                Self.log.info("wake session ended: heard \(text?.split(separator: " ").count ?? 0, privacy: .public) words, no wake phrase: \(text ?? "", privacy: .private)")
                wakeEnded(failed: failed)
            }
        case .command:
            guard state == .listening else { return }
            // After the wake word the same recognition carries on. Once you pause, it starts a
            // new segment without "Hey Dante" in it, and then all of it is the command.
            let said = afterWake ? text.map { WakeWord.command(in: $0) ?? $0 } ?? heard : text ?? heard
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
        guard state == .listening else { return Self.log.info("finish ignored, state \(String(describing: self.state), privacy: .public)") }
        let text = heard
        wokeForThis = afterWake
        Self.log.info("heard \(text.split(separator: " ").count, privacy: .public) words: \(text, privacy: .private)")
        release()
        state = answering == nil ? .idle : .waiting
        level = 0
        PresenceController.shared.voiceChanged()
        let open = Sessions.all.compactMap { $0.workspace?.name }
        act(on: VoiceCommand.parse(text, projects: open + Self.recents().map(\.name).filter { !open.contains($0) }))
        updateWakeListening()
    }

    func cancel() {
        release()
        stopSpeaking()
        conversing = false
        answering = nil
        state = .idle
        level = 0
        PresenceController.shared.voiceChanged()
        updateWakeListening()
    }

    /// Ends the recognition task; the microphone keeps running for the next one.
    private func endRecognition() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        wakeTimer?.invalidate()
        wakeTimer = nil
        mode = .off
        wakeListening = false
        generation += 1
        tapTarget.request = nil
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    /// Ends recognition and closes the microphone.
    private func stopAudio() {
        endRecognition()
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    /// Done listening for now. With "Hey Dante" on the microphone stays open, since it'll be
    /// wanted again in a moment, and closing and reopening a headset's microphone is what
    /// makes it drop out.
    private func release() {
        if Preferences.shared.listensForWakeWord { endRecognition() } else { stopAudio() }
    }

    /// A different microphone was chosen: reopen on it.
    func microphoneChanged() {
        guard engine.isRunning, state != .listening else { return }
        stopAudio()
        updateWakeListening()
    }

    private func audioConfigurationChanged() {
        // Picking the device when the engine starts reports a change too.
        guard Date.now.timeIntervalSince(engineStarted) > 1 else { return }
        Self.log.info("audio devices changed")
        if state == .listening {
            finish()
        } else {
            stopAudio()
        }
        updateWakeListening()
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
            release()
        } else if !Preferences.shared.listensForWakeWord, mode == .off, engine.isRunning {
            stopAudio()
        }
    }

    private func startWake() async {
        // Only once permission is given: turning the setting on asks for it.
        guard await Self.authorised() else {
            wakeProblem = "Dante needs the microphone and speech recognition. Allow them in System Settings › Privacy & Security."
            Self.log.error("wake: not authorised")
            return
        }
        guard let recognizer, recognizer.isAvailable else { return Self.log.error("wake: recognition unavailable") }
        // Listening all the time is only acceptable if nothing leaves the Mac.
        guard recognizer.supportsOnDeviceRecognition else {
            Self.log.error("wake: no on-device recognition")
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
        wakeWords = 0
        // Recognition tasks wind down after a minute or so; start a fresh one before that.
        wakeTimer = Timer.scheduledTimer(withTimeInterval: 50, repeats: false) { _ in
            MainActor.assumeIsolated {
                let voice = VoiceController.shared
                guard voice.mode == .wake else { return }
                Self.log.info("wake session restarted: heard \(voice.wakeWords, privacy: .public) words, no wake phrase")
                voice.endRecognition()
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
        if failed { stopAudio() } else { endRecognition() }
        wakeFailures = failed ? wakeFailures + 1 : 0
        // Back off when recognition keeps failing, so a broken setup doesn't spin.
        let delay = failed ? min(30, pow(2, Double(wakeFailures))) : 0.2
        Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated { VoiceController.shared.updateWakeListening() }
        }
    }

    // MARK: Acting

    /// The session spoken to: the frontmost project's, else one where Claude is busy or waiting.
    /// Never the launch screen's, which has no project and no conversation.
    private var target: Session? {
        ActiveProject.shared.session.flatMap { $0.workspace != nil ? $0 : nil }
            ?? Sessions.all.first { $0.waitingConversation != nil }
            ?? Sessions.all.first { $0.claude?.state == .working }
            ?? Sessions.all.first { $0.workspace != nil }
    }

    private func act(on command: VoiceCommand) {
        Self.log.info("command \(Self.kind(command), privacy: .public), \(Sessions.all.count, privacy: .public) windows, target \(self.target?.workspace?.name ?? "none", privacy: .private)")
        switch command {
        case .cancel:
            // Silence after a reply ends the conversation quietly; after "Hey Dante" it gets a word.
            if followUp {
                conversing = false
            } else if wokeForThis {
                say("Sorry, I didn’t catch that.")
            }
        case .goodbye:
            conversing = false
            say(["Anytime.", "Sure.", "Okay."].randomElement() ?? "Okay.")
        case .stop:
            for claude in Sessions.all.flatMap(\.allConversations) where claude.state == .working { claude.interrupt() }
            answering = nil
            if state == .waiting { state = .idle }
            say("Stopped.")
        case .show(let project):
            if let session = Sessions.all.first(where: { $0.workspace?.name == project }) {
                NSApp.activate()
                session.window?.makeKeyAndOrderFront(nil)
                return say("Here’s \(project).")
            }
            // A recent project that isn't open: opened like `dante <folder>`.
            guard let recent = Self.recents().first(where: { $0.name == project }) else { return say("I can’t find \(project).") }
            NSApp.activate()
            Self.open(recent.path)
            say("Opening \(project).")
        case .openProject:
            NSApp.activate()
            let names = Self.recents().filter { recent in !Sessions.all.contains { $0.workspace?.url.standardizedFileURL.path == recent.path } }.prefix(3).map(\.name)
            say(names.isEmpty ? "Pick a folder." : "Pick a folder, or say open and a name, like \(Self.list(Array(names))).")
            // After speaking starts: the panel waits for an answer. The folder opens like
            // `dante <folder>`, in a new window unless one is free.
            DispatchQueue.main.async {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.prompt = "Open"
                panel.message = "Choose a project folder"
                if panel.runModal() == .OK, let url = panel.url {
                    Self.open(url.path)
                }
            }
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
                StageController.shared.open(fullScreen: true)
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
            guard let session = target, session.claude != nil else {
                let names = Self.recents().prefix(3).map(\.name)
                return say("I need a project open to ask \(Preferences.shared.agentEngine.title) that. "
                           + (names.isEmpty ? "Open a folder first." : "Say open and its name, like \(Self.list(Array(names))).")) }
            let from = session.claude?.items.count ?? 0
            session.askClaude(text)
            conversing = Preferences.shared.keepsConversation
            listenForReply(in: session, from: from)
        }
    }

    /// Opens a folder like `dante <folder>` does, through this copy of Dante.
    static func open(_ path: String) {
        NSWorkspace.shared.open([OpenRequest(items: [.init(path: path)]).url], withApplicationAt: Bundle.main.bundleURL,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    /// A command's name for the log, without what was said.
    static func kind(_ command: VoiceCommand) -> String {
        switch command {
        case .ask: "ask"
        case .show: "show"
        default: String(describing: command)
        }
    }

    /// Projects opened before, most recent first, for opening by name.
    static func recents() -> [RecentProject] {
        RecentProjects().items.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// "a, b or c", for saying.
    static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " or " + names.last!
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
        Self.log.info("say (\(Preferences.shared.speaksReplies ? "aloud" : "muted", privacy: .public)) \(text.split(separator: " ").count, privacy: .public) words: \(text, privacy: .private)")
        if answering != nil { spokeThisTurn = true }
        guard Preferences.shared.speaksReplies else { return quiet() }
        // The microphone would hear Dante; wake listening pauses while it talks.
        if mode == .wake { endRecognition() }
        speechQueue.add(text)
        if saying == nil { saying = text }
        pump()
        PresenceController.shared.voiceChanged()
    }

    /// Hands the synthesiser the next chunk when there's room.
    private func pump() {
        guard let chunk = speechQueue.next(outstanding: outstanding.count) else { return }
        let utterance = AVSpeechUtterance(string: chunk)
        utterance.rate = Float(min(0.62, max(0.4, Preferences.shared.speechRate)))
        utterance.voice = Self.voice()
        outstanding.insert(ObjectIdentifier(utterance))
        speaker.speak(utterance)
    }

    func stopSpeaking() {
        speechQueue.reset()
        outstanding.removeAll()
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
    fileprivate func spoke(_ utterance: ObjectIdentifier) {
        guard outstanding.remove(utterance) != nil else { return }
        pump()
        guard outstanding.isEmpty else { return }
        quiet()
    }

    /// Nothing more to say: listen for a follow-up in a conversation, else go back to waiting
    /// for "Hey Dante".
    private func quiet() {
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
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in VoiceController.shared.spoke(id) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in VoiceController.shared.spoke(id) }
    }
}

/// The recognition request the microphone's tap feeds, swapped on the main actor and read on
/// the audio thread.
private final class TapTarget: @unchecked Sendable {
    private let lock = NSLock()
    private var current: SFSpeechAudioBufferRecognitionRequest?

    var request: SFSpeechAudioBufferRecognitionRequest? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}
