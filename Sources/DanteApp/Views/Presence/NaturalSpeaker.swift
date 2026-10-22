import AVFoundation
import DanteKit
import os

/// Speaks with the natural voice: text goes to the Kokoro server (`NaturalVoice.script`, one
/// process kept warm for ten minutes after it's last used) and the audio that comes back is
/// queued on one player node, so chunks follow each other without a gap. The orb's pulse
/// comes from the real loudness of what's playing.
@MainActor
final class NaturalSpeaker {
    static let shared = NaturalSpeaker()

    /// A chunk began playing.
    var onStart: (@MainActor (Int, String) -> Void)?
    /// A chunk finished playing.
    var onFinish: (@MainActor (Int) -> Void)?
    /// A chunk couldn't be made; say it some other way.
    var onFailure: (@MainActor (Int, String) -> Void)?
    /// The loudness of what's playing, 0…1, about 20 times a second.
    var onLevel: (@MainActor (Double) -> Void)?

    private static let log = Logger(subsystem: "dev.dante.ide", category: "voice")

    // The server.
    private var process: Process?
    private var stdin: FileHandle?
    private var received = Data()
    private var ready = false
    private var readyWaiters: [CheckedContinuation<Bool, Never>] = []
    private var replies: [Int: CheckedContinuation<NaturalVoice.Reply?, Never>] = [:]
    private var nextID = 1
    private var idleTimer: Timer?

    // Playing.
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var connectedFormat: AVAudioFormat?
    private var tapped = false
    /// Chunks waiting for their audio, in speaking order.
    private var order: [Int] = []
    private var made: [Int: (buffer: AVAudioPCMBuffer, text: String)] = [:]
    /// Chunks handed to the player, the one playing first.
    private var playing: [(token: Int, text: String)] = []
    private var generation = 0
    private var engineTimer: Timer?

    private init() {}

    var isAvailable: Bool { Preferences.shared.usesNaturalVoice && NaturalVoice.isInstalled() }

    /// Starts the server ahead of time (when you start talking), so the reply isn't kept waiting.
    func prewarm() {
        guard isAvailable else { return }
        _ = startServer()
    }

    func speak(token: Int, text: String) {
        order.append(token)
        let generation = generation
        let voice = NaturalVoice.voice(Preferences.shared.naturalVoice)
        let speed = NaturalVoice.speed(forRate: Preferences.shared.speechRate)
        Task {
            let buffer = await synthesize(text, voice: voice, speed: speed, generation: generation)
            guard generation == self.generation else { return }
            guard let buffer else {
                order.removeAll { $0 == token }
                onFailure?(token, text)
                scheduleReady()
                return
            }
            made[token] = (buffer, text)
            scheduleReady()
        }
    }

    func stop() {
        generation += 1
        order.removeAll()
        made.removeAll()
        playing.removeAll()
        if player.engine != nil { player.stop() }
        scheduleEngineStop()
    }

    // MARK: Playing

    /// Hands the player every chunk whose audio is ready, in order.
    private func scheduleReady() {
        while let first = order.first, let chunk = made.removeValue(forKey: first) {
            order.removeFirst()
            play(chunk.buffer, token: first, text: chunk.text)
        }
    }

    private func play(_ buffer: AVAudioPCMBuffer, token: Int, text: String) {
        guard prepareEngine(for: buffer.format) else {
            onFailure?(token, text)
            return
        }
        let generation = generation
        let first = playing.isEmpty
        Self.log.info("natural voice: playing \(Double(buffer.frameLength) / buffer.format.sampleRate, format: .fixed(precision: 1), privacy: .public) s")
        playing.append((token, text))
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack, completionHandler: Self.played(token, generation: generation))
        if !player.isPlaying { player.play() }
        if first { onStart?(token, text) }
    }

    private func played(_ token: Int, generation: Int) {
        guard generation == self.generation, let index = playing.firstIndex(where: { $0.token == token }) else { return }
        playing.remove(at: index)
        onFinish?(token)
        if let next = playing.first { onStart?(next.token, next.text) }
        if playing.isEmpty, order.isEmpty { scheduleEngineStop() }
    }

    private func prepareEngine(for format: AVAudioFormat) -> Bool {
        engineTimer?.invalidate()
        engineTimer = nil
        if player.engine == nil { engine.attach(player) }
        if connectedFormat != format {
            if engine.isRunning { engine.stop() }
            engine.connect(player, to: engine.mainMixerNode, format: format)
            connectedFormat = format
        }
        // For testing: the whole way through, in silence.
        if ProcessInfo.processInfo.environment["DANTE_VOICE_MUTE"] == "1" { engine.mainMixerNode.outputVolume = 0 }
        if !tapped {
            tapped = true
            engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil, block: Self.levelTap())
        }
        guard !engine.isRunning else { return true }
        do {
            engine.prepare()
            try engine.start()
            return true
        } catch {
            Self.log.error("natural voice: output didn't start: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Lets go of the output a moment after the last word, so nothing holds the device open.
    private func scheduleEngineStop() {
        engineTimer?.invalidate()
        engineTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in
            MainActor.assumeIsolated {
                let speaker = NaturalSpeaker.shared
                guard speaker.playing.isEmpty, speaker.order.isEmpty else { return }
                speaker.player.stop()
                speaker.engine.stop()
            }
        }
    }

    // MARK: Callbacks from other threads

    // Made outside the main actor: a closure written in a main-actor method is checked to run
    // there, and the audio and pipe threads that call these would trap.

    private nonisolated static func played(_ token: Int, generation: Int) -> AVAudioPlayerNodeCompletionHandler {
        { _ in Task { @MainActor in NaturalSpeaker.shared.played(token, generation: generation) } }
    }

    /// The loudness of what's playing, from the mixer.
    private nonisolated static func levelTap() -> AVAudioNodeTapBlock {
        { buffer, _ in
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
            let rms = sqrt(sum / Float(buffer.frameLength))
            let level = Double(min(1, max(0, (20 * log10(max(rms, 1e-6)) + 42) / 34)))
            Task { @MainActor in NaturalSpeaker.shared.onLevel?(level) }
        }
    }

    private nonisolated static func reader() -> @Sendable (FileHandle) -> Void {
        { handle in
            let data = handle.availableData
            // Empty at the end of the output; stop listening or it's called again and again.
            if data.isEmpty { handle.readabilityHandler = nil }
            Task { @MainActor in NaturalSpeaker.shared.read(data) }
        }
    }

    private nonisolated static func terminated() -> @Sendable (Process) -> Void {
        { _ in Task { @MainActor in NaturalSpeaker.shared.ended() } }
    }

    // MARK: The server

    private func startServer() -> Bool {
        if process != nil { return true }
        guard NaturalVoice.isInstalled() else { return false }
        let folder = NaturalVoice.folder
        do {
            try NaturalVoice.writeScript(in: folder)
        } catch {
            Self.log.error("natural voice: couldn't write the server: \(error.localizedDescription, privacy: .public)")
            return false
        }
        let process = Process()
        process.executableURL = NaturalVoice.python(in: folder)
        process.arguments = ["-I", NaturalVoice.server(in: folder).path, folder.path]
        process.currentDirectoryURL = folder
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        let logURL = folder.appending(path: "server.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        process.standardError = (try? FileHandle(forWritingTo: logURL)) ?? FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = Self.reader()
        process.terminationHandler = Self.terminated()
        do {
            try process.run()
        } catch {
            Self.log.error("natural voice: server didn't start: \(error.localizedDescription, privacy: .public)")
            return false
        }
        Self.log.info("natural voice: server starting")
        self.process = process
        stdin = input.fileHandleForWriting
        ready = false
        received = Data()
        Task {
            try? await Task.sleep(for: .seconds(45))
            self.giveUpWaiting(for: process)
        }
        touch()
        return true
    }

    private func read(_ data: Data) {
        guard !data.isEmpty else { return }
        received.append(data)
        while let newline = received.firstIndex(of: 0x0A) {
            let line = String(decoding: received[received.startIndex..<newline], as: UTF8.self)
            received.removeSubrange(received.startIndex...newline)
            guard let reply = NaturalVoice.Reply.parse(line) else { continue }
            if reply.ready == true {
                Self.log.info("natural voice: ready")
                ready = true
                let waiters = readyWaiters
                readyWaiters.removeAll()
                for waiter in waiters { waiter.resume(returning: true) }
            } else if let id = reply.id, let waiter = replies.removeValue(forKey: id) {
                waiter.resume(returning: reply)
            }
        }
    }

    private func ended() {
        Self.log.info("natural voice: server stopped")
        process = nil
        stdin = nil
        ready = false
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: false) }
        let pending = replies
        replies.removeAll()
        for waiter in pending.values { waiter.resume(returning: nil) }
    }

    /// The server never said it was ready: stop it, and say these some other way.
    private func giveUpWaiting(for process: Process) {
        guard self.process === process, !ready else { return }
        Self.log.error("natural voice: server took too long to start")
        process.terminate()
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: false) }
    }

    /// Stops the server after ten minutes without a word, to give its memory back.
    private func touch() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: false) { _ in
            MainActor.assumeIsolated {
                let speaker = NaturalSpeaker.shared
                guard speaker.replies.isEmpty else { return speaker.touch() }
                try? speaker.stdin?.close()
                speaker.process?.terminate()
            }
        }
    }

    private func synthesize(_ text: String, voice: String, speed: Double, generation: Int) async -> AVAudioPCMBuffer? {
        guard generation == self.generation else { return nil }
        guard startServer() else { return nil }
        if !ready {
            let ok = await withCheckedContinuation { readyWaiters.append($0) }
            guard ok else { return nil }
        }
        // Stop/interrupt may have happened while the model was warming up. Don't queue
        // cancelled speech ahead of the user's next reply.
        guard generation == self.generation else { return nil }
        let started = ContinuousClock.now
        let id = nextID
        nextID += 1
        touch()
        guard let stdin else { return nil }
        let reply: NaturalVoice.Reply? = await withCheckedContinuation { continuation in
            replies[id] = continuation
            do {
                try stdin.write(contentsOf: Data(NaturalVoice.request(id: id, text: text, voice: voice, speed: speed).utf8))
            } catch {
                replies.removeValue(forKey: id)?.resume(returning: nil)
                return
            }
            // A request that never comes back shouldn't hold up everything after it.
            Task {
                try? await Task.sleep(for: .seconds(30))
                self.replies.removeValue(forKey: id)?.resume(returning: nil)
            }
        }
        guard let reply, let path = reply.path, let rate = reply.rate else {
            if let error = reply?.error { Self.log.error("natural voice: \(error, privacy: .public)") }
            return nil
        }
        Self.log.info("natural voice: generated \(text.count, privacy: .public) characters in \(String(describing: started.duration(to: .now)), privacy: .public)")
        let url = URL(filePath: path)
        let samples = await Task.detached(priority: .userInitiated) { () -> [Float]? in
            defer { try? FileManager.default.removeItem(at: url) }
            return NaturalVoice.samples(at: url)
        }.value
        guard let samples, !samples.isEmpty,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }
}
