import AVFoundation
import MediaPlayer
import Observation
import Speech

/// The walk: talk to the agents on the Mac and hear them back. Recognition and speech run on
/// this phone (on-device when it can), so only text crosses to the Mac. Talk starts on the
/// big button or a press of an AirPods stem (it arrives as play/pause), and ends on another
/// press or two seconds of quiet. Walk mode holds the audio session, playing silence, so the
/// loop keeps running with the screen locked and the stem press keeps reaching Dante.
@MainActor @Observable
final class VoiceLoop {
    enum State: Equatable { case idle, listening, sending, speaking }

    private(set) var state: State = .idle
    /// What's being heard, live.
    private(set) var heard = ""
    private(set) var lastSpoken = ""
    private(set) var walking = false
    private(set) var problem: String?
    /// The project spoken messages go to (`CompanionSnapshot.Project.id`).
    var focus: String?

    let connection: CompanionConnection
    /// The step a "yes" or "no" answers: the one most recently read out.
    private var pending: (project: String, approval: CompanionSnapshot.Approval)?
    private var talkKey = PushToTalk()
    private let engine = AVAudioEngine()
    private let silence = AVAudioPlayerNode()
    private var silenceAttached = false
    private let synthesizer = AVSpeechSynthesizer()
    private let speechDelegate = SpeechDelegate()
    private let recognizer = SFSpeechRecognizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var quiet: Task<Void, Never>?
    private var deadline: Task<Void, Never>?

    init(connection: CompanionConnection) {
        self.connection = connection
        synthesizer.delegate = speechDelegate
        speechDelegate.onFinish = Self.finishedSpeaking(self)
        connection.onEvents = { [weak self] events, snapshot in self?.hear(events, in: snapshot) }
        connection.onResult = { [weak self] ok, message in if !ok { self?.say(message) } }
    }

    var project: CompanionSnapshot.Project? {
        let projects = connection.snapshot?.projects ?? []
        return projects.first { $0.id == focus } ?? projects.first
    }

    // MARK: Walk mode

    func setWalking(_ on: Bool) {
        if on {
            do {
                try activateSession()
                startSilence()
                installRemoteCommands()
                walking = true
                updateNowPlaying()
                say("Walk mode on. Press an AirPod to talk.")
            } catch {
                problem = "Couldn’t hold the audio session: \(error.localizedDescription)"
            }
        } else {
            walking = false
            silence.stop()
            if state == .idle { engine.stop() }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker])
        try session.setActive(true)
    }

    private func startSilence() {
        if !silenceAttached {
            engine.attach(silence)
            engine.connect(silence, to: engine.mainMixerNode, format: nil)
            silenceAttached = true
        }
        let format = silence.outputFormat(forBus: 0)
        if let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate)) {
            buffer.frameLength = buffer.frameCapacity
            silence.scheduleBuffer(buffer, at: nil, options: .loops)
        }
        if !engine.isRunning { try? engine.start() }
        silence.play()
    }

    private func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        for command in [center.togglePlayPauseCommand, center.playCommand, center.pauseCommand] {
            command.removeTarget(nil)
            command.isEnabled = true
            command.addTarget(handler: Self.stemPress(self))
        }
    }

    private nonisolated static func stemPress(_ loop: VoiceLoop) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { [weak loop] _ in
            Task { @MainActor in loop?.talk() }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard walking else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "Dante",
            MPMediaItemPropertyArtist: project.map { "\($0.lead) · \($0.name)" } ?? (connection.pairing?.name ?? "Mac"),
        ]
        MPNowPlayingInfoCenter.default().playbackState = .playing
    }

    // MARK: Listening

    /// The button and the stem press: start listening, or send what's been said.
    func talk() {
        if state == .listening { finish() } else { Task { await start() } }
    }

    private func start() async {
        guard let ticket = talkKey.press() else { return }
        synthesizer.stopSpeaking(at: .immediate)
        guard await Self.authorize() else {
            talkKey.cancel()
            problem = "Dante needs the microphone and speech recognition: Settings › Dante."
            return
        }
        guard talkKey.canStart(ticket), let recognizer, recognizer.isAvailable else {
            if talkKey.canStart(ticket) { problem = "Speech recognition isn’t available right now." }
            talkKey.cancel()
            return
        }
        do { try activateSession() } catch {
            talkKey.cancel()
            problem = "Couldn’t open the microphone: \(error.localizedDescription)"
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        request.addsPunctuation = true
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0), block: Self.tap(request))
        do {
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
        } catch {
            input.removeTap(onBus: 0)
            talkKey.cancel()
            problem = "Couldn’t start listening: \(error.localizedDescription)"
            return
        }
        self.request = request
        task = recognizer.recognitionTask(with: request, resultHandler: Self.results(self))
        talkKey.started(ticket)
        problem = nil
        heard = ""
        state = .listening
        AudioServicesPlaySystemSound(1113)
        listenForQuiet()
    }

    private nonisolated static func tap(_ request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        { buffer, _ in request.append(buffer) }
    }

    private nonisolated static func results(_ loop: VoiceLoop) -> (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { [weak loop] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in loop?.recognized(text, final: final, failed: failed) }
        }
    }

    private nonisolated static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    private func recognized(_ text: String?, final: Bool, failed: Bool) {
        if let text, !text.isEmpty {
            heard = text
            if state == .listening { listenForQuiet() }
        }
        if final || (failed && state == .sending) { deliver() }
    }

    /// Two seconds without new words sends what was said.
    private func listenForQuiet() {
        quiet?.cancel()
        quiet = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.state == .listening, !self.heard.isEmpty else { return }
            self.finish()
        }
    }

    private func finish() {
        guard talkKey.release() else { return }
        quiet?.cancel()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        state = .sending
        AudioServicesPlaySystemSound(1114)
        // The final result usually follows at once; don't wait on it for long.
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            self?.deliver()
        }
    }

    private func deliver() {
        guard state == .sending else { return }
        deadline?.cancel()
        task?.cancel()
        task = nil
        request = nil
        talkKey.cancel()
        state = .idle
        if !walking { engine.stop() }
        let text = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        handle(text)
    }

    // MARK: Acting on what was said

    func handle(_ text: String) {
        guard let snapshot = connection.snapshot else {
            say("I’m not connected to your Mac.")
            return
        }
        let command = CompanionForeman.parse(text, projects: snapshot.projects.map(\.name))
        // A question waiting for an answer takes whatever was said as the answer.
        if let pending, let question = pending.approval.questions.first, ![.stop, .cancel, .status, .repeatLast].contains(command) {
            let answer = question.options.first { text.localizedCaseInsensitiveContains($0) } ?? text
            connection.answer(pending.approval, project: pending.project, allow: true, answers: [question.question: answer])
            self.pending = nil
            say("Told them: \(answer).")
            return
        }
        switch command {
        case .approve, .decline:
            let allow = command == .approve
            guard let target = pending ?? waiting(in: snapshot).first else {
                say("Nothing’s waiting on you.")
                return
            }
            connection.answer(target.approval, project: target.project, allow: allow)
            pending = nil
            let next = waiting(in: snapshot).first { $0.approval.id != target.approval.id }
            if let next {
                pending = next
                let name = snapshot.projects.first { $0.id == next.project }
                say((allow ? "Done. " : "Declined. ") + CompanionForeman.ask(next.approval, project: name?.name ?? "", lead: name?.lead ?? "Claude"))
            } else {
                say(allow ? "Done." : "Declined.")
            }
        case .stop:
            synthesizer.stopSpeaking(at: .immediate)
            if let project { connection.stop(project: project.id) }
        case .status:
            say(CompanionForeman.status(snapshot))
        case .repeatLast:
            say(lastSpoken.isEmpty ? "I haven’t said anything yet." : lastSpoken)
        case .goodbye:
            say("Talk soon.")
        case .cancel:
            break
        case .switchProject(let name):
            focus = snapshot.projects.first { $0.name == name }?.id
            updateNowPlaying()
            say("Now in \(name).")
        case .startJob(let brief):
            guard let project else { return say("No project is open on your Mac.") }
            connection.startJob(brief, project: project.id, awayMinutes: nil)
            say("Starting a job in \(project.name): \(brief).")
        case .ask(let message):
            guard let project else { return say("No project is open on your Mac.") }
            connection.ask(message, project: project.id, spoken: true)
            AudioServicesPlaySystemSound(1004)
        }
    }

    private func waiting(in snapshot: CompanionSnapshot) -> [(project: String, approval: CompanionSnapshot.Approval)] {
        let ordered = snapshot.projects.sorted { a, _ in a.id == project?.id }
        return ordered.flatMap { project in project.approvals.map { (project.id, $0) } }
    }

    // MARK: Speaking

    private func hear(_ events: [CompanionForeman.Event], in snapshot: CompanionSnapshot) {
        for event in events {
            switch event {
            case .replied(let project, _, _) where project != self.project?.id:
                let name = snapshot.projects.first { $0.id == project }?.name ?? "Another project"
                say("\(name) has a reply.")
            case .waiting(let project, let approval):
                pending = (project, approval)
                say(CompanionForeman.spoken(event, in: snapshot))
            default:
                say(CompanionForeman.spoken(event, in: snapshot))
            }
        }
        updateNowPlaying()
    }

    func say(_ text: String) {
        guard !text.isEmpty else { return }
        lastSpoken = text
        try? activateSession()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice
        state = state == .idle ? .speaking : state
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// The best installed voice for the phone's language: premium, then enhanced.
    private static let voice: AVSpeechSynthesisVoice? = {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == language }
        return voices.first { $0.quality == .premium } ?? voices.first { $0.quality == .enhanced } ?? AVSpeechSynthesisVoice(language: language)
    }()

    private nonisolated static func finishedSpeaking(_ loop: VoiceLoop) -> @Sendable () -> Void {
        { [weak loop] in
            Task { @MainActor in
                guard let loop, loop.state == .speaking, !loop.synthesizer.isSpeaking else { return }
                loop.state = .idle
            }
        }
    }
}

/// AVSpeechSynthesizer's delegate is called off the main actor.
private final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    var onFinish: @Sendable () -> Void = {}

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { onFinish() }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { onFinish() }
}
