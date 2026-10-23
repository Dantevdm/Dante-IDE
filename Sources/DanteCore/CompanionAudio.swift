import Foundation

/// Mono PCM16 WAV for native playback on the companion, bounded below its WebSocket limit.
public enum CompanionAudio {
    public static let maximumBytes = 2 << 20

    public static func wav(samples: [Float], sampleRate: Int) -> Data? {
        guard (8_000...48_000).contains(sampleRate), !samples.isEmpty,
              samples.count <= (maximumBytes - 44) / 2 else { return nil }
        var data = Data()
        func word<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        word(UInt32(36 + samples.count * 2))
        data.append(contentsOf: "WAVEfmt ".utf8)
        word(UInt32(16))
        word(UInt16(1)) // PCM
        word(UInt16(1)) // mono
        word(UInt32(sampleRate))
        word(UInt32(sampleRate * 2))
        word(UInt16(2))
        word(UInt16(16))
        data.append(contentsOf: "data".utf8)
        word(UInt32(samples.count * 2))
        for sample in samples {
            let clipped = sample.isFinite ? min(1, max(-1, sample)) : 0
            word(Int16(clipped * Float(Int16.max)))
        }
        return data
    }
}
