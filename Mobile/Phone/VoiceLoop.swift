import AVFoundation
import MediaPlayer
import Observation
import Speech

/// The walk: talk to the agents on the Mac and hear them back. Recognition runs on this phone
/// (on-device when it can). Natural speech is rendered on the Mac and played here.
/// Talk starts on the big button or a headset's play/pause button, and ends on another
/// press or two seconds of quiet. Walk mode holds the audio session, playing silence, so the
/// loop keeps running with the screen locked and headset controls keep reaching Dante.
@MainActor @Observable
final class VoiceLoop {
    enum State: Equatable { case idle, listening, sending, speaking }

    private(set) var state: State = .idle
    /// What's being heard, live.
    private(set) var heard = ""
    private(set) var lastSpoken = ""
    private(set) var walking = false
    private(set) var problem: String?
    private(set) var audioRoute = ""
    private(set) var headsetControlsReady = false
    private(set) var headsetPresses = 0
    /// The project spoken messages go to (`CompanionSnapshot.Project.id`).
    var focus: String?

    let connection: CompanionConnection
    /// The step a "yes" or "no" answers: the one most recently read out.
    private var pending: (project: String, approval: CompanionSnapshot.Approval)?
    private var talkKey = PushToTalk()
    private let engine = AVAudioEngine()
    // An AVPlayer-backed Now Playing session gives iOS an explicit owner for
    // headset controls. An engine playing silence alone doesn't establish one.
    private let walkPlayer = AVQueuePlayer()
    private var walkLooper: AVPlayerLooper?
    private var walkSession: MPNowPlayingSession?
    private let walkSessionDelegate = WalkSessionDelegate()
    private let synthesizer = AVSpeechSynthesizer()
    private let speechDelegate = SpeechDelegate()
    private let audioDelegate = AudioDelegate()
    private var audioPlayer: AVAudioPlayer?
    private var speechQueue = SpeechQueue()
    private var speechTask: Task<Void, Never>?
    private var speakingChunk = false
    private var speechGeneration = 0
    private var playback: ObjectIdentifier?
    private let recognizer = SFSpeechRecognizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var quiet: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var recognitionTicket: Int?
    private var walkGeneration = 0
    private var audioInterrupted = false
    private var audioObservers: [NSObjectProtocol] = []
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private var lastHeadsetPress: TimeInterval = -.infinity
    private var routeSignature = ""
    private var walkDiagnostics: [String] = []

    /// Bounded, local control-state diagnostics. Never include speech or project content.
    private func traceWalk(_ event: String) {
        let line = "\(Int(ProcessInfo.processInfo.systemUptime)) \(event)"
        walkDiagnostics.append(line)
        walkDiagnostics = Array(walkDiagnostics.suffix(60))
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        if let url = folder?.appendingPathComponent("walk-controls.log") {
            try? Data(walkDiagnostics.joined(separator: "\n").utf8).write(to: url, options: .atomic)
        }
    }

    init(connection: CompanionConnection) {
        self.connection = connection
        synthesizer.delegate = speechDelegate
        speechDelegate.onFinish = Self.finishedSpeaking(self)
        audioDelegate.onFinish = Self.finishedSpeaking(self)
        walkSessionDelegate.onActiveChange = { [weak self] id, active in
            Task { @MainActor in
                guard let self, self.walking, let session = self.walkSession, ObjectIdentifier(session) == id else { return }
                self.headsetControlsReady = active
                self.traceWalk("session active changed: \(active)")
            }
        }
        connection.onEvents = { [weak self] events, snapshot in self?.hear(events, in: snapshot) }
        connection.onResult = { [weak self] ok, message in if !ok { self?.say(message) } }
        connection.onApprovalModeChanged = { [weak self] mode in
            let reply: String = switch mode {
            case .ask: "I’ll ask before making changes in this conversation."
            case .edits: "I’ll apply file edits automatically and ask before running commands."
            case .everything: "Auto-approve is on for this conversation. I’ll keep the work moving."
            }
            self?.say(reply)
        }
        observeAudio()
    }

    var project: CompanionSnapshot.Project? {
        let projects = connection.snapshot?.projects ?? []
        return projects.first { $0.id == focus } ?? projects.first
    }

    // MARK: Walk mode

    func setWalking(_ on: Bool) {
        traceWalk("Walk mode requested: \(on)")
        walkGeneration += 1
        let generation = walkGeneration
        if on {
            Task {
                guard await Self.authorize(), generation == walkGeneration else {
                    if generation == walkGeneration { problem = "Allow microphone and speech recognition access in Settings to use Walk mode." }
                    return
                }
                do {
                    audioInterrupted = false
                    cancelListening()
                    stopSpeaking()
                    walkPlayer.pause()
                    engine.stop()
                    try activateSession()
                    try startWalkPlayback()
                    installRemoteCommands()
                    walking = true
                    headsetPresses = 0
                    problem = nil
                    updateNowPlaying()
                    await claimHeadsetControls()
                    guard walking, generation == walkGeneration else { return }
                    say(headsetControlsReady
                        ? "Walk mode is on. Press your headset’s play or pause button to talk."
                        : "Walk mode is on. Headset controls haven’t connected yet; you can tap the microphone.")
                } catch {
                    setWalking(false)
                    problem = "Walk mode couldn’t start. Try reconnecting your headset."
                }
            }
        } else {
            walking = false
            headsetControlsReady = false
            cancelListening()
            stopSpeaking()
            walkPlayer.pause()
            walkLooper?.disableLooping()
            walkLooper = nil
            walkPlayer.removeAllItems()
            engine.stop()
            for (command, target) in remoteTargets { command.removeTarget(target) }
            remoteTargets.removeAll()
            walkSession?.nowPlayingInfoCenter.nowPlayingInfo = nil
            walkSession = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func activateSession(recording: Bool = false) throws {
        let session = AVAudioSession.sharedInstance()
        // Leave the headset in its normal media mode between requests. Only select
        // the call-style Bluetooth microphone route while actually recording.
        let category: AVAudioSession.Category = recording ? .playAndRecord : .playback
        if session.category != category {
            try session.setCategory(category, mode: .default, options: recording ? [.allowBluetoothHFP, .defaultToSpeaker] : [])
        }
        try session.setActive(true)
        if recording, let headset = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }), session.preferredInput?.uid != headset.uid {
            try session.setPreferredInput(headset)
        }
        updateAudioRoute()
    }

    private func updateAudioRoute() {
        let session = AVAudioSession.sharedInstance()
        routeSignature = currentRouteSignature
        audioRoute = session.currentRoute.outputs.map(\.portName).joined(separator: ", ")
        traceWalk("audio: \(session.category.rawValue), input=\(session.currentRoute.inputs.map { $0.portType.rawValue }), output=\(session.currentRoute.outputs.map { $0.portType.rawValue })")
    }

    private func startWalkPlayback() throws {
        if walkSession == nil {
            let session = MPNowPlayingSession(players: [walkPlayer])
            session.automaticallyPublishesNowPlayingInfo = false
            session.delegate = walkSessionDelegate
            walkSession = session
        }
        if walkLooper == nil {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("dante-walk-silence.wav")
            guard let wav = CompanionAudio.wav(samples: Array(repeating: 0, count: 48_000), sampleRate: 24_000) else {
                throw CocoaError(.coderInvalidValue)
            }
            try wav.write(to: url, options: .atomic)
            walkLooper = AVPlayerLooper(player: walkPlayer, templateItem: AVPlayerItem(url: url))
        }
        walkPlayer.play()
    }

    private func installRemoteCommands() {
        guard remoteTargets.isEmpty else { return }
        guard let center = walkSession?.remoteCommandCenter else { return }
        for command in [center.togglePlayPauseCommand, center.playCommand, center.pauseCommand] {
            command.isEnabled = true
            let target = command.addTarget(handler: Self.headsetPress(self))
            remoteTargets.append((command, target))
        }
        traceWalk("headset handlers installed")
    }

    private nonisolated static func headsetPress(_ loop: VoiceLoop) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { [weak loop] _ in
            Task { @MainActor in
                guard let loop else { return }
                loop.traceWalk("button arrived: walking=\(loop.walking), interrupted=\(loop.audioInterrupted), state=\(loop.state)")
                guard loop.walking, !loop.audioInterrupted else { return }
                let now = ProcessInfo.processInfo.systemUptime
                // Some headsets report both a playback action and a toggle for one press.
                guard now - loop.lastHeadsetPress > 0.25 else { return }
                loop.lastHeadsetPress = now
                loop.headsetPresses += 1
                loop.headsetControlsReady = true
                loop.talk()
            }
            return .success
        }
    }

    /// A deliberate user action can reclaim controls after another audio app uses them.
    func reconnectHeadsetControls() {
        guard walking else { return }
        Task {
            do {
                audioInterrupted = false
                try activateSession()
                try startWalkPlayback()
                updateNowPlaying()
                await claimHeadsetControls()
            } catch {
                problem = "I couldn’t connect the headset controls. Turn Walk mode off and on again."
            }
        }
    }

    private func claimHeadsetControls() async {
        guard let session = walkSession else { return }
        // The local loop's player item needs a moment to become eligible. A failed
        // first attempt must not leave Walk mode silently claiming the buttons work.
        for _ in 0..<30 {
            guard walking, walkSession === session, !Task.isCancelled else { return }
            if session.canBecomeActive { break }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
        let active = await session.becomeActiveIfPossible()
        guard walking, walkSession === session else { return }
        headsetControlsReady = active
        traceWalk("control claim: active=\(active), eligible=\(session.canBecomeActive), playerRate=\(walkPlayer.rate), itemStatus=\(walkPlayer.currentItem?.status.rawValue ?? -1)")
        if !active {
            problem = "Headset controls haven’t connected to Dante. Tap Reconnect controls, then check that Control Center shows Dante."
        }
    }

    private var currentRouteSignature: String {
        let session = AVAudioSession.sharedInstance()
        return (session.currentRoute.inputs + session.currentRoute.outputs).map(\.uid).joined(separator: "|") + "|\(session.sampleRate)"
    }

    private func observeAudio() {
        let center = NotificationCenter.default
        audioObservers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.walking, !self.audioInterrupted, self.currentRouteSignature != self.routeSignature else { return }
                // Changing to the microphone route is intentional. Wait until it
                // settles before starting the engine instead of cancelling the talk.
                if case .starting = self.talkKey.phase { self.updateAudioRoute(); return }
                if self.state == .listening || self.state == .sending {
                    self.recoverWalkingAudio()
                } else {
                    self.updateAudioRoute()
                    if self.walkPlayer.rate == 0 { self.recoverWalkingAudio() }
                }
            }
        })
        audioObservers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.resumeWalking() }
        })
        audioObservers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in
                guard let self, self.walking else { return }
                self.traceWalk("audio interruption: type=\(type ?? 999), options=\(options)")
                if type == AVAudioSession.InterruptionType.began.rawValue {
                    self.audioInterrupted = true
                    self.cancelListening()
                    self.stopSpeaking()
                    self.walkPlayer.pause()
                    self.headsetControlsReady = false
                    self.engine.stop()
                } else if type == AVAudioSession.InterruptionType.ended.rawValue {
                    self.audioInterrupted = false
                    if AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) {
                        self.recoverWalkingAudio()
                    } else {
                        self.setWalking(false)
                        self.problem = "Walk mode paused. Turn it on when you’re ready."
                    }
                }
            }
        })
    }

    func resumeWalking() {
        guard walking, !audioInterrupted else { return }
        if case .starting = talkKey.phase { return }
        connection.resume()
        if state == .listening || state == .sending {
            if currentRouteSignature != routeSignature || (state == .listening && !engine.isRunning) { recoverWalkingAudio() }
        } else {
            if currentRouteSignature != routeSignature { updateAudioRoute() }
            if walkPlayer.rate == 0 { recoverWalkingAudio() }
        }
    }

    private func recoverWalkingAudio() {
        cancelListening()
        stopSpeaking()
        walkPlayer.pause()
        engine.stop()
        do {
            try activateSession()
            try startWalkPlayback()
            updateNowPlaying()
            Task { await claimHeadsetControls() }
        } catch {
            setWalking(false)
            problem = "The audio connection changed. Reconnect your headset and turn Walk mode on again."
        }
    }

    private func cancelListening() {
        quiet?.cancel()
        deadline?.cancel()
        recognitionTicket = nil
        talkKey.cancel()
        if request != nil { engine.inputNode.removeTap(onBus: 0) }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        if state == .listening || state == .sending { state = .idle }
    }

    private func updateNowPlaying() {
        guard walking else { return }
        walkSession?.nowPlayingInfoCenter.nowPlayingInfo = [
            MPMediaItemPropertyTitle: "Dante",
            MPMediaItemPropertyArtist: project.map { "\($0.lead) · \($0.name)" } ?? (connection.pairing?.name ?? "Mac"),
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
    }

    // MARK: Listening

    /// The button and headset control: start listening, or send what's been said.
    func talk() {
        if state == .listening { finish() } else { Task { await start() } }
    }

    private func start() async {
        guard let ticket = talkKey.press() else { return }
        stopSpeaking()
        if wakeTask != nil { stopWake() }
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
        do {
            try activateSession(recording: true)
            let session = AVAudioSession.sharedInstance()
            var ready = false
            for _ in 0..<40 {
                guard talkKey.canStart(ticket), !Task.isCancelled else { return }
                let selected = session.preferredInput?.uid
                if session.sampleRate > 0, session.currentRoute.inputs.contains(where: { selected == nil || $0.uid == selected }) {
                    ready = true
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard ready else { throw CocoaError(.coderInvalidValue) }
            updateAudioRoute()
        } catch {
            talkKey.cancel()
            try? activateSession()
            problem = "Couldn’t open the microphone: \(error.localizedDescription)"
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        request.addsPunctuation = true
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            talkKey.cancel()
            try? activateSession()
            problem = "Your microphone isn’t ready. Reconnect your headset and try again."
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat, block: Self.tap(request))
        do {
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
        } catch {
            input.removeTap(onBus: 0)
            talkKey.cancel()
            try? activateSession()
            problem = "Couldn’t start listening: \(error.localizedDescription)"
            return
        }
        self.request = request
        recognitionTicket = ticket
        task = recognizer.recognitionTask(with: request, resultHandler: Self.results(self, ticket: ticket))
        talkKey.started(ticket)
        problem = nil
        heard = ""
        state = .listening
        traceWalk("microphone listening")
        AudioServicesPlaySystemSound(1113)
        listenForQuiet()
    }

    private nonisolated static func tap(_ request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        { buffer, _ in request.append(buffer) }
    }

    private nonisolated static func results(_ loop: VoiceLoop, ticket: Int) -> (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { [weak loop] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in
                guard loop?.recognitionTicket == ticket else { return }
                loop?.recognized(text, final: final, failed: failed)
            }
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
        guard state == .listening || state == .sending else { return }
        if let text, !text.isEmpty {
            heard = text
            if state == .listening { listenForQuiet() }
        }
        if final || failed {
            if state == .listening { finish() }
            deliver()
        }
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
        recognitionTicket = nil
        talkKey.cancel()
        state = .idle
        engine.stop()
        try? activateSession()
        let text = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        handle(text)
        pumpSpeech()
    }

    // MARK: Hey Dante (the wall)

    /// While the wall is up: an on-device recognition task listening for "Hey Dante",
    /// restarted every 50 seconds and stopped while Dante speaks or the button is used.
    /// Nothing heard leaves the iPad until the wake phrase is said.
    private(set) var listensForWakeWord = false
    /// What was said after "Hey Dante" so far; nil while waiting for it.
    private(set) var wakeCommand: String?
    private var wakeTask: SFSpeechRecognitionTask?
    private var wakeRequest: SFSpeechAudioBufferRecognitionRequest?
    private var wakeLoop: Task<Void, Never>?
    private var wakeQuiet: Task<Void, Never>?
    private var wakeStarted = Date.distantPast
    private var wakeGeneration = 0

    var isWaitingForWakeWord: Bool { wakeTask != nil && wakeCommand == nil }

    func setWakeWord(_ on: Bool) {
        guard on != listensForWakeWord else { return }
        listensForWakeWord = on
        wakeLoop?.cancel()
        wakeLoop = nil
        if on {
            wakeLoop = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.tendWake()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        } else {
            stopWake()
        }
    }

    /// Starts listening when nothing else is going on, and restarts a long-running task
    /// (on-device recognition stops by itself after about a minute).
    private func tendWake() async {
        let pressed: Bool = if case .idle = talkKey.phase { false } else { true }
        if state != .idle || speakingChunk || pressed {
            if wakeTask != nil, wakeCommand == nil { stopWake() }
            return
        }
        if wakeTask != nil, wakeCommand == nil, Date.now.timeIntervalSince(wakeStarted) > 50 { stopWake() }
        if wakeTask == nil { await startWake() }
    }

    private func startWake() async {
        guard await Self.authorize() else {
            problem = "Hey Dante needs the microphone and speech recognition: Settings › Dante."
            return setWakeWord(false)
        }
        guard let recognizer, recognizer.supportsOnDeviceRecognition else {
            problem = "This device can’t recognise speech offline, so Hey Dante stays off."
            return setWakeWord(false)
        }
        guard listensForWakeWord, recognizer.isAvailable, state == .idle, wakeTask == nil else { return }
        do { try activateSession(recording: true) } catch { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(request))
        do {
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
        } catch {
            input.removeTap(onBus: 0)
            return
        }
        wakeGeneration += 1
        wakeRequest = request
        wakeStarted = .now
        wakeTask = recognizer.recognitionTask(with: request, resultHandler: Self.wakeResults(self, generation: wakeGeneration))
    }

    private nonisolated static func wakeResults(_ loop: VoiceLoop, generation: Int) -> (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { [weak loop] result, error in
            let text = result?.bestTranscription.formattedString ?? ""
            let ended = error != nil || (result?.isFinal ?? false)
            Task { @MainActor in loop?.wakeRecognized(text, ended: ended, generation: generation) }
        }
    }

    private func wakeRecognized(_ text: String, ended: Bool, generation: Int) {
        guard generation == wakeGeneration, wakeTask != nil else { return }
        if let command = WakeWord.command(in: text) {
            if wakeCommand == nil { AudioServicesPlaySystemSound(1113) }
            wakeCommand = command
            heard = command
            // A pause ends the request; "Hey Dante" alone waits a little longer for the rest.
            wakeQuiet?.cancel()
            wakeQuiet = Task { [weak self] in
                try? await Task.sleep(for: .seconds(command.isEmpty ? 4 : 1.5))
                guard !Task.isCancelled else { return }
                self?.wakeFinished()
            }
        }
        if ended {
            if wakeCommand != nil { wakeFinished() } else { stopWake() }
        }
    }

    private func wakeFinished() {
        let command = (wakeCommand ?? "").trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        stopWake()
        heard = ""
        if command.isEmpty {
            // "Hey Dante" alone: listen for the request as if the button were pressed.
            talk()
        } else {
            AudioServicesPlaySystemSound(1114)
            handle(command)
        }
    }

    private func stopWake() {
        wakeQuiet?.cancel()
        wakeQuiet = nil
        wakeCommand = nil
        wakeGeneration += 1
        wakeTask?.cancel()
        wakeTask = nil
        wakeRequest?.endAudio()
        wakeRequest = nil
        guard state == .idle else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? activateSession()
    }

    // MARK: Acting on what was said

    func handle(_ text: String) {
        guard let snapshot = connection.snapshot else {
            say("I’m not connected to your Mac.")
            return
        }
        if let pending, !snapshot.projects.contains(where: { $0.id == pending.project && $0.approvals.contains(where: { $0.id == pending.approval.id }) }) {
            self.pending = nil
        }
        let command = CompanionForeman.parse(text, projects: snapshot.projects.map(\.name) + (snapshot.recent ?? []).map(\.name))
        // With nothing open, a message goes to the most recent project, which the Mac opens.
        let target = snapshot.target(focus: focus)
        // A question waiting for an answer takes whatever was said as the answer.
        let changesApprovals: Bool = if case .approvals = command { true } else { false }
        if let pending, let question = pending.approval.questions.first, !changesApprovals, ![.stop, .cancel, .status, .repeatLast, .briefing].contains(command) {
            let answer = question.options.first { text.localizedCaseInsensitiveContains($0) } ?? text
            connection.answer(pending.approval, project: pending.project, allow: true, answers: [question.question: answer])
            self.pending = nil
            say("Told them: \(answer).")
            return
        }
        switch command {
        case .approvals(let mode):
            guard let project else { return say("Open a project on your Mac first.") }
            connection.setApprovals(mode, project: project.id)
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
            stopSpeaking()
            if let project { connection.stop(project: project.id) }
        case .status:
            say(CompanionForeman.status(snapshot))
        case .briefing:
            briefing()
        case .repeatLast:
            say(lastSpoken.isEmpty ? "I haven’t said anything yet." : lastSpoken)
        case .goodbye:
            say("Talk soon.")
        case .cancel:
            break
        case .switchProject(let name):
            if let open = snapshot.projects.first(where: { $0.name == name }) {
                focus = open.id
                updateNowPlaying()
                say("Now in \(name).")
            } else if let recent = snapshot.recent?.first(where: { $0.name == name }) {
                focus = recent.id
                connection.openProject(recent.id)
                say("Opening \(name) on your Mac.")
            }
        case .startJob(let brief):
            guard let target else { return say("There are no projects on your Mac yet.") }
            connection.startJob(brief, project: target.id, awayMinutes: nil)
            say((target.isOpen ? "" : "Opening \(target.name). ") + "Starting a job in \(target.name): \(brief).")
        case .reply(let reply):
            say("Writing it.")
            Task { say(await connection.replyMail(reply)) }
        case .ask(let message):
            guard let target else { return say("There are no projects on your Mac yet.") }
            connection.ask(message, project: target.id, spoken: true)
            if !target.isOpen { say("Opening \(target.name) on your Mac.") }
            AudioServicesPlaySystemSound(1004)
        }
    }

    /// Asks the Mac for the morning update and reads it; says the kept one when the Mac can't answer.
    func briefing() {
        say("Let me check.")
        Task {
            switch await connection.requestBriefing() {
            case .success(let briefing):
                say(briefing.spoken)
            case .failure(let failure):
                if let kept = connection.briefing {
                    say("I can’t reach your Mac, so this is from \(kept.date.formatted(date: .omitted, time: .shortened)). " + kept.spoken)
                } else {
                    say(failure.message)
                }
            }
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
        speechQueue.add(text)
        pumpSpeech()
    }

    private func pumpSpeech() {
        guard !speakingChunk, state != .listening, state != .sending else { return }
        guard case .idle = talkKey.phase else { return }
        guard let text = speechQueue.next(outstanding: 0, capacity: 1) else {
            if state == .speaking { state = .idle }
            return
        }
        speakingChunk = true
        state = .speaking
        let generation = speechGeneration
        speechTask = Task { [weak self] in
            guard let self else { return }
            // On mobile data the device's own voice speaks, rather than audio from the Mac.
            let audio = DataSaver.shared.asksFirst ? nil : await connection.speech(text)
            guard !Task.isCancelled, generation == speechGeneration else { return }
            try? activateSession()
            if let audio, audio.count <= CompanionAudio.maximumBytes,
               let player = try? AVAudioPlayer(data: audio) {
                player.delegate = audioDelegate
                audioPlayer = player
                playback = ObjectIdentifier(player)
                if player.play() {
                    problem = nil
                    return
                }
                audioPlayer = nil
                playback = nil
            }
            problem = "Using the iPhone voice. " + (connection.voiceFailure ?? "The Mac audio couldn’t be played.")
            speakWithApple(text)
        }
    }

    private func speakWithApple(_ text: String) {
        try? activateSession()
        let utterance = AVSpeechUtterance(string: text)
        playback = ObjectIdentifier(utterance)
        utterance.voice = Self.voice
        state = state == .idle ? .speaking : state
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        speechGeneration += 1
        speechTask?.cancel()
        speechTask = nil
        speechQueue.reset()
        audioPlayer?.stop()
        audioPlayer = nil
        playback = nil
        synthesizer.stopSpeaking(at: .immediate)
        speakingChunk = false
        if state == .speaking { state = .idle }
    }

    /// The best installed voice for the phone's language: premium, then enhanced.
    private static let voice: AVSpeechSynthesisVoice? = {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == language }
        return voices.first { $0.quality == .premium } ?? voices.first { $0.quality == .enhanced } ?? AVSpeechSynthesisVoice(language: language)
    }()

    private nonisolated static func finishedSpeaking(_ loop: VoiceLoop) -> @Sendable (ObjectIdentifier) -> Void {
        { [weak loop] playback in
            Task { @MainActor in
                guard let loop, loop.playback == playback, loop.state == .speaking, !loop.synthesizer.isSpeaking,
                      loop.audioPlayer?.isPlaying != true else { return }
                loop.audioPlayer = nil
                loop.playback = nil
                loop.speakingChunk = false
                loop.pumpSpeech()
            }
        }
    }
}

private final class WalkSessionDelegate: NSObject, MPNowPlayingSessionDelegate, @unchecked Sendable {
    var onActiveChange: @Sendable (ObjectIdentifier, Bool) -> Void = { _, _ in }

    func nowPlayingSessionDidChangeActive(_ session: MPNowPlayingSession) {
        onActiveChange(ObjectIdentifier(session), session.isActive)
    }
}

private final class AudioDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    var onFinish: @Sendable (ObjectIdentifier) -> Void = { _ in }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { onFinish(ObjectIdentifier(player)) }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) { onFinish(ObjectIdentifier(player)) }
}

/// AVSpeechSynthesizer's delegate is called off the main actor.
private final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    var onFinish: @Sendable (ObjectIdentifier) -> Void = { _ in }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { onFinish(ObjectIdentifier(utterance)) }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {}
}
