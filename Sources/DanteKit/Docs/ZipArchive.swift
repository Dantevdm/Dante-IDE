import Compression
import Foundation

/// Just enough ZIP for document formats such as `.xmind`: reads stored and deflated entries,
/// and writes deflated ones (stored when deflating doesn't help). No ZIP64, encryption or
/// multi-disk archives.
public enum ZipArchive {
    public enum Failure: Error, Equatable {
        case notAZip
        case unsupported(String)
        case corrupt(String)
    }

    /// Every file in the archive by its path. Folders are left out.
    public static func read(_ data: Data) throws -> [String: Data] {
        let bytes = [UInt8](data)
        guard let end = endOfCentralDirectory(bytes) else { throw Failure.notAZip }
        let count = Int(u16(bytes, end + 10))
        var offset = Int(u32(bytes, end + 16))
        var files: [String: Data] = [:]
        for _ in 0..<count {
            guard offset + 46 <= bytes.count, u32(bytes, offset) == 0x0201_4b50 else { throw Failure.corrupt("central directory") }
            let flags = u16(bytes, offset + 8)
            let method = u16(bytes, offset + 10)
            let compressed = Int(u32(bytes, offset + 20))
            let size = Int(u32(bytes, offset + 24))
            let nameLength = Int(u16(bytes, offset + 28))
            let extraLength = Int(u16(bytes, offset + 30))
            let commentLength = Int(u16(bytes, offset + 32))
            let local = Int(u32(bytes, offset + 42))
            guard offset + 46 + nameLength <= bytes.count else { throw Failure.corrupt("name") }
            let name = String(decoding: bytes[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)
            offset += 46 + nameLength + extraLength + commentLength
            if name.hasSuffix("/") { continue }
            guard flags & 1 == 0 else { throw Failure.unsupported("encrypted entries") }
            guard local + 30 <= bytes.count, u32(bytes, local) == 0x0403_4b50 else { throw Failure.corrupt(name) }
            let start = local + 30 + Int(u16(bytes, local + 26)) + Int(u16(bytes, local + 28))
            guard start + compressed <= bytes.count else { throw Failure.corrupt(name) }
            let body = Data(bytes[start..<(start + compressed)])
            switch method {
            case 0: files[name] = body
            case 8: files[name] = try inflate(body, size: size, name: name)
            default: throw Failure.unsupported("compression method \(method)")
            }
        }
        return files
    }

    /// An archive of the files, in the order given (some readers want a manifest first).
    public static func write(_ files: [(path: String, data: Data)], date: Date = Date()) -> Data {
        var out = Data()
        var central = Data()
        let (time, day) = dosDateTime(date)
        for file in files {
            let name = Array(file.path.utf8)
            let crc = crc32(file.data)
            let deflated = deflate(file.data)
            let method: UInt16 = deflated.map { $0.count < file.data.count } == true ? 8 : 0
            let body = method == 8 ? deflated! : file.data
            let offset = UInt32(out.count)
            var header = Data()
            header.append32(0x0403_4b50)
            header.append16(20); header.append16(0x0800) // version, UTF-8 names
            header.append16(method); header.append16(time); header.append16(day)
            header.append32(crc); header.append32(UInt32(body.count)); header.append32(UInt32(file.data.count))
            header.append16(UInt16(name.count)); header.append16(0)
            out.append(header); out.append(contentsOf: name); out.append(body)

            central.append32(0x0201_4b50)
            central.append16(20); central.append16(20); central.append16(0x0800)
            central.append16(method); central.append16(time); central.append16(day)
            central.append32(crc); central.append32(UInt32(body.count)); central.append32(UInt32(file.data.count))
            central.append16(UInt16(name.count)); central.append16(0); central.append16(0)
            central.append16(0); central.append16(0); central.append32(0)
            central.append32(offset)
            central.append(contentsOf: name)
        }
        let start = UInt32(out.count)
        out.append(central)
        out.append32(0x0605_4b50)
        out.append16(0); out.append16(0)
        out.append16(UInt16(files.count)); out.append16(UInt16(files.count))
        out.append32(UInt32(central.count)); out.append32(start)
        out.append16(0)
        return out
    }

    // MARK: Pieces

    private static func endOfCentralDirectory(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 22 else { return nil }
        let lowest = max(0, bytes.count - 22 - 65_535)
        var index = bytes.count - 22
        while index >= lowest {
            if u32(bytes, index) == 0x0605_4b50 { return index }
            index -= 1
        }
        return nil
    }

    private static func inflate(_ data: Data, size: Int, name: String) throws -> Data {
        if size == 0 { return Data() }
        var output = [UInt8](repeating: 0, count: size)
        let written = data.withUnsafeBytes { raw -> Int in
            guard let source = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(&output, size, source, data.count, nil, COMPRESSION_ZLIB)
        }
        guard written == size else { throw Failure.corrupt(name) }
        return Data(output)
    }

    private static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = data.count + data.count / 10 + 64
        var output = [UInt8](repeating: 0, count: capacity)
        let written = data.withUnsafeBytes { raw -> Int in
            guard let source = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(&output, capacity, source, data.count, nil, COMPRESSION_ZLIB)
        }
        return written > 0 ? Data(output.prefix(written)) : nil
    }

    private static let crcTable: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    private static func dosDateTime(_ date: Date) -> (UInt16, UInt16) {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let time = UInt16((parts.hour ?? 0) << 11 | (parts.minute ?? 0) << 5 | (parts.second ?? 0) / 2)
        let day = UInt16(max(0, (parts.year ?? 1980) - 1980) << 9 | (parts.month ?? 1) << 5 | (parts.day ?? 1))
        return (time, day)
    }

    private static func u16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
        guard at + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
    }

    private static func u32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        guard at + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }
}

private extension Data {
    mutating func append16(_ value: UInt16) { append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8)]) }
    mutating func append32(_ value: UInt32) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)])
    }
}
