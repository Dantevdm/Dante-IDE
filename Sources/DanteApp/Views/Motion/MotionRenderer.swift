import AppKit
import AVFoundation
import CryptoKit
import DanteKit
import OSLog
import WebKit

/// Renders a motion piece offline: an offscreen web view laid out at the design size, each
/// frame drawn by `dante.renderFrame(t)` and captured, then encoded (H.264 up to 1080p, HEVC
/// for 4K) with the narration mixed in. Frames are drawn on demand, not in real time, so
/// a heavy scene renders slower but never drops a frame.
@MainActor
final class MotionRenderer {
    enum Quality: String, CaseIterable, Identifiable {
        case hd = "1080p", uhd = "4K"
        var id: Self { self }

        /// The output width for a piece: its short side at 1080 or 2160 pixels, so a vertical
        /// piece renders 1080×1920 or 2160×3840.
        func width(for piece: MotionPiece) -> Int {
            let short = Double(self == .hd ? 1080 : 2160)
            let scale = short / Double(min(piece.width, piece.height))
            return Int((Double(piece.width) * scale / 2).rounded()) * 2
        }
    }

    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    private static let log = Logger(subsystem: "dev.dante.ide", category: "motion")

    let source: MotionSource
    let outputWidth: Int
    private let window: NSWindow
    private let web: WKWebView
    private var loaded: CheckedContinuation<Bool, Never>?
    private(set) var errors: [String] = []
    private var navigation: Navigation?

    /// `outputWidth` in pixels; the height follows the piece's aspect.
    init(source: MotionSource, outputWidth: Int, refused: @escaping (String) -> Bool) {
        self.source = source
        self.outputWidth = outputWidth
        let backing = NSScreen.main?.backingScaleFactor ?? 2
        // Lay the view out so WebKit draws exactly the output's pixels: points × backing.
        let points = Double(outputWidth) / backing
        let zoom = points / Double(source.piece.width)
        let size = NSSize(width: points, height: points * Double(source.piece.height) / Double(source.piece.width))
        window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        var errorSink: ((String) -> Void)?
        let messages = MotionMessages { body in
            if body["type"] as? String == "error" { errorSink?(MotionRenderer.describe(body)) }
        }
        web = source.makeWebView(mode: .render, pixelRatio: Double(outputWidth) / Double(source.piece.width), refused: refused, messages: messages)
        web.frame = NSRect(origin: .zero, size: size)
        web.pageZoom = zoom
        window.contentView = web
        errorSink = { [weak self] message in self?.errors.append(message) }
    }

    nonisolated static func describe(_ body: [String: Any]) -> String {
        let message = (body["message"] as? String) ?? "Script error"
        if let file = body["file"] as? String, !file.isEmpty, let line = body["line"] as? Int { return "\(file):\(line): \(message)" }
        return message
    }

    /// Loads the scene and waits until it says it's ready (or 20 s).
    func load() async throws {
        window.orderBack(nil)
        let navigation = Navigation { [weak self] ok in self?.loaded?.resume(returning: ok); self?.loaded = nil }
        self.navigation = navigation
        web.navigationDelegate = navigation
        let ok = await withCheckedContinuation { continuation in
            loaded = continuation
            web.load(URLRequest(url: source.url))
        }
        guard ok else { throw Failure(message: "The scene didn't load: \(source.piece.scene) is missing or unreadable.") }
        // renderFrame waits for setup itself; this only catches a scene that never registers.
        let registered = try? await web.callAsyncJavaScript(
            "for (let i = 0; i < 200; i++) { if (window.dante && dante.time !== undefined && (await Promise.race([dante.renderFrame(0).then(() => true), new Promise(r => setTimeout(() => r(false), 100))]))) return true; } return false;",
            contentWorld: .page)
        if (registered as? Bool) != true {
            throw Failure(message: errors.first.map { "The scene stopped with an error: \($0)" } ?? "The scene never called dante.scene({ setup, seek }).")
        }
    }

    /// Draws the frame for `t` and captures it.
    func frame(at t: Double) async throws -> CGImage {
        _ = try await web.callAsyncJavaScript("return await dante.renderFrame(t)", arguments: ["t": t], contentWorld: .page)
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        configuration.snapshotWidth = NSNumber(value: Double(web.frame.width))
        let image = try await web.takeSnapshot(configuration: configuration)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw Failure(message: "A frame couldn't be captured.") }
        return cgImage
    }

    func close() {
        web.navigationDelegate = nil
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }

    // MARK: Stills

    /// PNGs of the frames at `times`, for the agent to look at (motion_frames) and for posters.
    static func stills(source: MotionSource, times: [Double], width: Int, into folder: URL, refused: @escaping (String) -> Bool) async -> (files: [URL], errors: [String]) {
        let renderer = MotionRenderer(source: source, outputWidth: width, refused: refused)
        defer { renderer.close() }
        do {
            try await renderer.load()
        } catch {
            return ([], renderer.errors + [error.localizedDescription])
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var files: [URL] = []
        var shots: [(Double, CGImage)] = []
        for t in times {
            guard let image = try? await renderer.frame(at: min(max(0, t), source.piece.duration)) else { continue }
            shots.append((t, image))
            let url = folder.appending(path: String(format: "frame-%07.3f.png", t))
            let rep = NSBitmapImageRep(cgImage: image)
            if let png = rep.representation(using: .png, properties: [:]), (try? png.write(to: url)) != nil { files.append(url) }
        }
        if shots.count > 1, let sheet = contactSheet(shots, fps: source.piece.fps) {
            let url = folder.appending(path: "contact-sheet.png")
            if let png = NSBitmapImageRep(cgImage: sheet).representation(using: .png, properties: [:]), (try? png.write(to: url)) != nil {
                files.insert(url, at: 0)
            }
        }
        return (files, renderer.errors)
    }

    /// The frames in a grid, each labelled with its time and frame number, on a dark sheet.
    static func contactSheet(_ shots: [(Double, CGImage)], fps: Int) -> CGImage? {
        guard let first = shots.first?.1 else { return nil }
        let columns = shots.count <= 4 ? 2 : shots.count <= 9 ? 3 : 4
        let rows = Int((Double(shots.count) / Double(columns)).rounded(.up))
        let cell = CGSize(width: 520, height: 520 * CGFloat(first.height) / CGFloat(first.width))
        let label: CGFloat = 26, gap: CGFloat = 12
        let size = CGSize(width: CGFloat(columns) * (cell.width + gap) + gap, height: CGFloat(rows) * (cell.height + label + gap) + gap)
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 0.08, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.interpolationQuality = .high
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        for (index, shot) in shots.enumerated() {
            let column = index % columns, row = index / columns
            let x = gap + CGFloat(column) * (cell.width + gap)
            let top = size.height - gap - CGFloat(row) * (cell.height + label + gap)
            let frame = CGRect(x: x, y: top - label - cell.height, width: cell.width, height: cell.height)
            context.draw(shot.1, in: frame)
            context.setStrokeColor(CGColor(gray: 0.3, alpha: 1))
            context.stroke(frame.insetBy(dx: -0.5, dy: -0.5), width: 1)
            let text = String(format: "%.2f s · frame %d", shot.0, Int((shot.0 * Double(fps)).rounded()))
            (text as NSString).draw(at: CGPoint(x: x + 2, y: top - label + 6), withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor(white: 0.85, alpha: 1),
            ])
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    // MARK: Video

    /// Renders the whole piece to an MP4 at `quality`, with `narration` (a sound file timed
    /// from 0) mixed in. `progress` gets 0…1; cancelling the task stops it and removes the file.
    static func video(source: MotionSource, quality: Quality, narration: URL?, to output: URL, refused: @escaping (String) -> Bool,
                      progress: @escaping (Double) -> Void) async throws {
        let width = quality.width(for: source.piece)
        let renderer = MotionRenderer(source: source, outputWidth: width, refused: refused)
        defer { renderer.close() }
        try await renderer.load()
        let height = Int((Double(width) * Double(source.piece.height) / Double(source.piece.width)).rounded() / 2) * 2
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        // HEVC for 4K, and for anything H.264's level limits would refuse.
        let usesHEVC = quality == .uhd || max(width, height) > 4096
        let bitrate = quality == .uhd ? 40_000_000 : 16_000_000
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: usesHEVC ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate, AVVideoExpectedSourceFrameRateKey: source.piece.fps],
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
        ])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(videoInput)
        var audio: AudioFeed?
        if let narration {
            audio = try? AudioFeed(url: narration, writer: writer)
        }
        guard writer.startWriting() else { throw Failure(message: writer.error?.localizedDescription ?? "The video file couldn't be written.") }
        writer.startSession(atSourceTime: .zero)
        let times = source.piece.frameTimes
        let timescale = CMTimeScale(source.piece.fps * 100)
        do {
            for (index, t) in times.enumerated() {
                try Task.checkCancellation()
                let image = try await renderer.frame(at: t)
                let presentation = CMTime(value: CMTimeValue(index * 100), timescale: timescale)
                // Keep the sound a second ahead of the picture, so the writer can interleave them.
                audio?.feed(until: presentation.seconds + 1)
                while !videoInput.isReadyForMoreMediaData {
                    audio?.feed(until: presentation.seconds + 2)
                    try await Task.sleep(for: .milliseconds(5))
                }
                guard let pool = adaptor.pixelBufferPool, let buffer = Self.pixelBuffer(from: image, pool: pool, width: width, height: height),
                      adaptor.append(buffer, withPresentationTime: presentation) else {
                    throw Failure(message: writer.error?.localizedDescription ?? "Frame \(index) couldn't be encoded.")
                }
                if index % 3 == 0 { progress(Double(index + 1) / Double(times.count)) }
            }
            audio?.feed(until: .infinity)
            videoInput.markAsFinished()
            audio?.finish()
            await writer.finishWriting()
            if writer.status != .completed { throw Failure(message: writer.error?.localizedDescription ?? "The video didn't finish.") }
            progress(1)
            if let error = renderer.errors.first { log.notice("motion render finished with script errors: \(error, privacy: .public)") }
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    static func pixelBuffer(from image: CGImage, pool: CVPixelBufferPool, width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    /// Navigation callbacks for the offscreen view.
    final class Navigation: NSObject, WKNavigationDelegate {
        let finished: @MainActor (Bool) -> Void
        init(finished: @escaping @MainActor (Bool) -> Void) { self.finished = finished }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { MainActor.assumeIsolated { finished(true) } }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { MainActor.assumeIsolated { finished(false) } }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { MainActor.assumeIsolated { finished(false) } }
    }
}

/// Reads a sound file and hands it to the writer's AAC input in step with the frames.
@MainActor
private final class AudioFeed {
    let reader: AVAssetReader
    let output: AVAssetReaderTrackOutput
    let input: AVAssetWriterInput
    private var pending: CMSampleBuffer?
    private var done = false

    init(url: URL, writer: AVAssetWriter) throws {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else { throw MotionRenderer.Failure(message: "The narration has no sound.") }
        reader = try AVAssetReader(asset: asset)
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
                                                                         AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
                                                                         AVLinearPCMIsBigEndianKey: false])
        reader.add(output)
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 1,
                                                                       AVSampleRateKey: 48_000, AVEncoderBitRateKey: 192_000])
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        reader.startReading()
    }

    /// Appends sound up to `seconds`, as far as the input will take it now.
    func feed(until seconds: Double) {
        guard !done else { return }
        while input.isReadyForMoreMediaData {
            guard let buffer = pending ?? output.copyNextSampleBuffer() else { done = true; input.markAsFinished(); return }
            if CMSampleBufferGetPresentationTimeStamp(buffer).seconds > seconds { pending = buffer; return }
            pending = nil
            input.append(buffer)
        }
    }

    func finish() {
        guard !done else { return }
        done = true
        input.markAsFinished()
        reader.cancelReading()
    }
}

/// The narration as one sound file: each line spoken in Dante's natural voice (Kokoro) and
/// placed at its time. Cached by the lines, voice and speed, so a re-render doesn't speak again.
enum NarrationTrack {
    struct Result {
        var url: URL
        /// Seconds each line runs.
        var lengths: [Double]
    }

    static var cacheFolder: URL {
        URL.applicationSupportDirectory.appending(path: "Dante/motion-voice")
    }

    /// Nil when there's nothing to say or the natural voice isn't set up.
    static func make(_ piece: MotionPiece, voice: String, speed: Double) async -> Result? {
        guard !piece.narration.isEmpty, NaturalVoice.isInstalled() else { return nil }
        let key = SHA256.hash(data: Data((piece.narration.map { "\($0.at)|\($0.text)" } + [voice, "\(speed)", "\(piece.duration)"]).joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(24)
        let url = cacheFolder.appending(path: "\(key).caf")
        let lengthsURL = cacheFolder.appending(path: "\(key).json")
        if FileManager.default.fileExists(atPath: url.path), let data = try? Data(contentsOf: lengthsURL),
           let lengths = try? JSONDecoder().decode([Double].self, from: data) {
            return Result(url: url, lengths: lengths)
        }
        return await Task.detached(priority: .userInitiated) { () -> Result? in
            guard let spoken = await speak(piece.narration.map(\.text), voice: voice, speed: speed) else { return nil }
            let rate = spoken.rate
            let lengths = spoken.lines.map { Double($0.count) / rate }
            let end = zip(piece.narration, lengths).map { $0.at + $1 }.max() ?? 0
            let total = Int((max(piece.duration, end) * rate).rounded(.up))
            var mix = [Float](repeating: 0, count: total)
            for (line, samples) in zip(piece.narration, spoken.lines) {
                let start = Int(line.at * rate)
                for (offset, sample) in samples.enumerated() where start + offset < total { mix[start + offset] += sample }
            }
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)) else { return nil }
            buffer.frameLength = AVAudioFrameCount(total)
            mix.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: total) }
            do {
                try FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
                let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                try file.write(from: buffer)
                try JSONEncoder().encode(lengths).write(to: lengthsURL)
            } catch {
                return nil
            }
            return Result(url: url, lengths: lengths)
        }.value
    }

    /// Speaks each line with a Kokoro server of its own (the voice's warm one stays free).
    nonisolated static func speak(_ lines: [String], voice: String, speed: Double) async -> (lines: [[Float]], rate: Double)? {
        let folder = NaturalVoice.folder
        try? NaturalVoice.writeScript(in: folder)
        let process = Process()
        process.executableURL = NaturalVoice.python(in: folder)
        process.arguments = ["-I", NaturalVoice.server(in: folder).path, folder.path]
        process.currentDirectoryURL = folder
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }
        var replies = output.fileHandleForReading.bytes.lines.makeAsyncIterator()
        // Ready first.
        while let line = try? await replies.next() {
            if NaturalVoice.Reply.parse(line)?.ready == true { break }
        }
        var spoken: [[Float]] = []
        var rate = 24_000.0
        for (index, text) in lines.enumerated() {
            guard (try? input.fileHandleForWriting.write(contentsOf: Data(NaturalVoice.request(id: index, text: text, voice: voice, speed: speed).utf8))) != nil else { return nil }
            var samples: [Float] = []
            while let line = try? await replies.next() {
                guard let reply = NaturalVoice.Reply.parse(line), reply.id == index else { continue }
                if let path = reply.path {
                    samples = NaturalVoice.samples(at: URL(filePath: path)) ?? []
                    try? FileManager.default.removeItem(atPath: path)
                    rate = reply.rate ?? rate
                }
                break
            }
            spoken.append(samples)
        }
        return (spoken, rate)
    }
}
