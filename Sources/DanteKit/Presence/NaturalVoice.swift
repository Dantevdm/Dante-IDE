import CryptoKit
import Foundation
import Observation

/// Dante's natural voice: Kokoro (82M parameters, Apache-2.0), a neural voice that runs on
/// this Mac through `kokoro-onnx`, several times faster than it speaks. It lives in
/// Application Support/Dante/voice: a Python environment of its own, the model and the voices,
/// and the small server Dante talks to (`script`). Nothing is sent anywhere.
public enum NaturalVoice {
    public struct Voice: Identifiable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var accent: String
    }

    /// The voices worth hearing, best first (Kokoro's own grades put Heart and Bella on top).
    public static let voices: [Voice] = [
        Voice(id: "af_heart", name: "Heart", accent: "American"),
        Voice(id: "af_bella", name: "Bella", accent: "American"),
        Voice(id: "af_nicole", name: "Nicole", accent: "American, soft"),
        Voice(id: "af_sarah", name: "Sarah", accent: "American"),
        Voice(id: "am_michael", name: "Michael", accent: "American"),
        Voice(id: "am_fenrir", name: "Fenrir", accent: "American"),
        Voice(id: "am_puck", name: "Puck", accent: "American"),
        Voice(id: "bf_emma", name: "Emma", accent: "British"),
        Voice(id: "bf_isabella", name: "Isabella", accent: "British"),
        Voice(id: "bm_george", name: "George", accent: "British"),
        Voice(id: "bm_fable", name: "Fable", accent: "British"),
    ]

    public static let defaultVoice = "af_heart"

    /// What setting up fetches: the package from PyPI, and the model files from the
    /// project's GitHub release, checked against these digests.
    public static let package = "kokoro-onnx==0.6.1"
    public struct Download: Sendable, Equatable {
        public var name: String
        public var url: URL
        public var bytes: Int
        public var sha256: String
    }

    public static let downloads = [
        Download(name: "kokoro-v1.0.onnx", url: URL(string: "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx")!,
                 bytes: 325_532_387, sha256: "7d5df8ecf7d4b1878015a32686053fd0eebe2bc377234608764cc0ef3636a6c5"),
        Download(name: "voices-v1.0.bin", url: URL(string: "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin")!,
                 bytes: 28_214_398, sha256: "bca610b8308e8d99f32e6fe4197e7ec01679264efed0cac9140fe9c29f1fbf7d"),
    ]

    /// About how much setting up downloads, for the button.
    public static var downloadSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(downloads.map(\.bytes).reduce(0, +) + 30_000_000), countStyle: .file)
    }

    public static var folder: URL {
        if let override = ProcessInfo.processInfo.environment["DANTE_VOICE_DIR"], !override.isEmpty {
            return URL(filePath: override, directoryHint: .isDirectory)
        }
        return URL.applicationSupportDirectory.appending(path: "Dante/voice", directoryHint: .isDirectory)
    }

    public static func python(in folder: URL = folder) -> URL { folder.appending(path: "venv/bin/python") }
    public static func server(in folder: URL = folder) -> URL { folder.appending(path: "server.py") }

    /// Set up: the environment is there and the model files are whole.
    public static func isInstalled(in folder: URL = folder) -> Bool {
        let files = FileManager.default
        guard files.isExecutableFile(atPath: python(in: folder).path) else { return false }
        return downloads.allSatisfy { download in
            let size = (try? files.attributesOfItem(atPath: folder.appending(path: download.name).path)[.size] as? Int) ?? nil
            return size == download.bytes
        }
    }

    /// Kokoro's speed for the speed slider's rate (0.4 slow … 0.62 fast; 0.52 is normal).
    public static func speed(forRate rate: Double) -> Double {
        min(1.35, max(0.75, 1 + (rate - 0.52) * 2.6))
    }

    /// The chosen voice if it's one Kokoro has, else the default.
    public static func voice(_ chosen: String) -> String {
        voices.contains { $0.id == chosen } ? chosen : defaultVoice
    }

    /// One line from the server.
    public struct Reply: Decodable, Equatable, Sendable {
        public var ready: Bool?
        public var id: Int?
        public var path: String?
        public var rate: Double?
        public var samples: Int?
        public var error: String?

        public static func parse(_ line: String) -> Reply? {
            try? JSONDecoder().decode(Reply.self, from: Data(line.utf8))
        }
    }

    /// A request line for the server.
    public static func request(id: Int, text: String, voice: String, speed: Double) -> String {
        let object: [String: Any] = ["id": id, "text": text, "voice": voice, "speed": speed]
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// Reads a file of raw little-endian 32-bit float samples, as the server writes them.
    public static func samples(at url: URL) -> [Float]? {
        guard let data = try? Data(contentsOf: url), data.count % 4 == 0 else { return nil }
        return data.withUnsafeBytes { raw in
            (0..<data.count / 4).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
        }
    }

    /// The Python to build the environment from: Homebrew's, then the system's when it's new
    /// enough (onnxruntime needs 3.10 or later).
    public static func basePython() -> URL? {
        let candidates = ["/opt/homebrew/bin/python3.12", "/opt/homebrew/bin/python3.13", "/opt/homebrew/bin/python3.11",
                          "/usr/local/bin/python3.12", "/usr/local/bin/python3.13", "/usr/local/bin/python3.11",
                          "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        return candidates.lazy.map { URL(filePath: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// The server: loads the model once, warms it up, then answers one request per line with
    /// a file of samples. It ends when Dante closes its stdin (or quits).
    public static let script = #"""
    # Dante's natural voice: Kokoro on this Mac. One JSON request per line on stdin,
    # {"id": 1, "text": "...", "voice": "af_heart", "speed": 1.0}; each answer is a JSON line
    # naming a file of raw little-endian 32-bit float samples, mono, at "rate" Hz.
    import atexit, json, os, shutil, sys, tempfile

    def main():
        folder = sys.argv[1]
        out = tempfile.mkdtemp(prefix="dante-voice-")
        atexit.register(shutil.rmtree, out, True)
        from kokoro_onnx import Kokoro
        kokoro = Kokoro(os.path.join(folder, "kokoro-v1.0.onnx"), os.path.join(folder, "voices-v1.0.bin"))
        kokoro.create("Ready.", voice="af_heart", speed=1.0, lang="en-us")
        print(json.dumps({"ready": True}), flush=True)
        for line in sys.stdin:
            try:
                request = json.loads(line)
            except ValueError:
                continue
            ident = request.get("id")
            try:
                voice = request.get("voice") or "af_heart"
                lang = "en-gb" if voice.startswith("b") else "en-us"
                samples, rate = kokoro.create(request["text"], voice=voice, speed=float(request.get("speed", 1.0)), lang=lang)
                path = os.path.join(out, "%s.f32" % ident)
                samples.astype("<f4").tofile(path)
                print(json.dumps({"id": ident, "path": path, "rate": rate, "samples": int(len(samples))}), flush=True)
            except Exception as error:
                print(json.dumps({"id": ident, "error": str(error)}), flush=True)

    if __name__ == "__main__":
        main()
    """#

    /// Writes the server script when it's missing or out of date.
    public static func writeScript(in folder: URL = folder) throws {
        let url = server(in: folder)
        if (try? String(contentsOf: url, encoding: .utf8)) == script { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try script.write(to: url, atomically: true, encoding: .utf8)
    }

    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Setting the natural voice up from Settings: a Python environment with `kokoro-onnx`, then
/// the model and voices, each checked against its digest.
@MainActor
@Observable
public final class NaturalVoiceSetup {
    public static let shared = NaturalVoiceSetup()

    public enum State: Equatable {
        case idle
        case working(String)
        case failed(String)
    }

    public private(set) var state: State = .idle
    public private(set) var installed = NaturalVoice.isInstalled()

    public var isWorking: Bool { if case .working = state { true } else { false } }

    public func refresh() { installed = NaturalVoice.isInstalled() }

    public func install() async {
        guard !isWorking else { return }
        let folder = NaturalVoice.folder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if !FileManager.default.isExecutableFile(atPath: NaturalVoice.python(in: folder).path) {
                guard let base = NaturalVoice.basePython() else {
                    throw Failure("The natural voice needs Python 3.11 or later. Install it with Homebrew: brew install python@3.12")
                }
                state = .working("Making a Python environment…")
                let venv = await Shell.run([base.path, "-m", "venv", folder.appending(path: "venv").path], in: folder)
                guard venv.succeeded else { throw Failure("Couldn’t make the Python environment: \(venv.message)") }
            }
            state = .working("Installing Kokoro…")
            let pip = await Shell.run([NaturalVoice.python(in: folder).path, "-m", "pip", "install", "--disable-pip-version-check", "-q", NaturalVoice.package], in: folder)
            guard pip.succeeded else { throw Failure("Couldn’t install Kokoro: \(pip.message.suffix(300))") }
            for download in NaturalVoice.downloads {
                let target = folder.appending(path: download.name)
                if let size = try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int, size == download.bytes { continue }
                state = .working("Downloading \(download.name) (\(ByteCountFormatter.string(fromByteCount: Int64(download.bytes), countStyle: .file)))…")
                let (temporary, response) = try await URLSession.shared.download(from: download.url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure("Couldn’t download \(download.name).") }
                state = .working("Checking \(download.name)…")
                let digest = await Task.detached { NaturalVoice.sha256(of: temporary) }.value
                guard digest == download.sha256 else {
                    try? FileManager.default.removeItem(at: temporary)
                    throw Failure("\(download.name) didn’t match its checksum, so it wasn’t kept.")
                }
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: temporary, to: target)
            }
            try NaturalVoice.writeScript(in: folder)
            state = .idle
        } catch let failure as Failure {
            state = .failed(failure.message)
        } catch {
            state = .failed(error.localizedDescription)
        }
        refresh()
    }

    struct Failure: Error {
        var message: String
        init(_ message: String) { self.message = message }
    }
}
