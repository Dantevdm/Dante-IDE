import AVFoundation
import DanteKit
import Speech
import SwiftUI

/// A mic beside a text box: click to say it, click again (or pause) to stop. What's heard is
/// added to the text as it's recognised, on this Mac, never sent anywhere.
struct DictationButton: View {
    @Environment(\.theme) private var theme
    @Binding var text: String
    @State private var dictation = Dictation()

    var body: some View {
        Button {
            if dictation.isListening { dictation.stop() } else { dictation.start(into: $text) }
        } label: {
            Image(systemName: dictation.isListening ? "mic.fill" : "mic")
                .font(.dante(size: 12, weight: .medium))
                .foregroundStyle(dictation.isListening ? theme.accent.color : theme.text2.color)
                .frame(width: 26, height: 26)
                .background(Circle().fill(dictation.isListening ? theme.accentTint.color : theme.raised.color))
                .overlay(Circle().strokeBorder(dictation.isListening ? theme.accentLine.color : theme.line.color))
                .scaleEffect(dictation.isListening ? 1 + CGFloat(dictation.level) * 0.25 : 1)
                .animation(.snappy(duration: 0.12), value: dictation.level)
        }
        .buttonStyle(.plain)
        .help(dictation.problem ?? (dictation.isListening ? "Stop dictating" : "Say it instead of typing"))
        .onDisappear { dictation.stop() }
    }
}

@MainActor @Observable
final class Dictation {
    private(set) var isListening = false
    private(set) var level: Float = 0
    private(set) var problem: String?

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var target: Binding<String>?
    /// The text before this dictation began, and what it said so far.
    @ObservationIgnored private var before = ""
    @ObservationIgnored private var silence: Task<Void, Never>?

    func start(into text: Binding<String>) {
        guard !isListening else { return }
        Task {
            guard await Self.speechAuthorised(), await AVCaptureDevice.requestAccess(for: .audio) else {
                problem = "Dante needs the microphone and speech recognition: System Settings › Privacy & Security."
                return
            }
            guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
                problem = "Speech recognition isn't available on this Mac."
                return
            }
            begin(recognizer, into: text)
        }
    }

    private func begin(_ recognizer: SFSpeechRecognizer, into text: Binding<String>) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        if let microphone = Microphones.chosen(preferred: Preferences.shared.microphone) {
            try? input.auAudioUnit.setDeviceID(microphone.id)
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0), block: Self.tap(request, dictation: self))
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            problem = "Couldn't start the microphone: \(error.localizedDescription)"
            return
        }
        self.request = request
        target = text
        let existing = text.wrappedValue
        before = existing.isEmpty || existing.hasSuffix(" ") || existing.hasSuffix("\n") ? existing : existing + " "
        problem = nil
        isListening = true
        task = recognizer.recognitionTask(with: request, resultHandler: Self.handler(self))
        stopAfterSilence()
    }

    func stop() {
        guard isListening else { return }
        isListening = false
        level = 0
        silence?.cancel()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
    }

    fileprivate func heard(_ said: String?, final: Bool, failed: Bool) {
        if let said, let target, !said.isEmpty {
            target.wrappedValue = before + said
            stopAfterSilence()
        }
        if final || failed { stop() }
    }

    fileprivate func metered(_ value: Float) { level = value }

    /// Three quiet seconds end it, as dictation does elsewhere on the Mac.
    private func stopAfterSilence() {
        silence?.cancel()
        silence = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    // Closures audio and recognition threads call, made outside the main actor.
    private nonisolated static func tap(_ request: SFSpeechAudioBufferRecognitionRequest, dictation: Dictation) -> AVAudioNodeTapBlock {
        let owner = dictation
        return { buffer, _ in
            request.append(buffer)
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var sum: Float = 0
            for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
            let level = min(1, sqrt(sum / Float(buffer.frameLength)) * 8)
            Task { @MainActor in owner.metered(level) }
        }
    }

    private nonisolated static func handler(_ dictation: Dictation) -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        let owner = dictation
        return { result, error in
            let said = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in owner.heard(said, final: final, failed: failed) }
        }
    }

    private nonisolated static func speechAuthorised() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in continuation.resume(returning: status == .authorized) }
        }
    }
}
