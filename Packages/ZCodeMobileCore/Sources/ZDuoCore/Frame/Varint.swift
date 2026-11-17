import Foundation

/// ULEB128 varint 读写 —— 官方 `writeInt32VQL`/`readIntVQL` 的 Swift 对照。
/// 7 bit 一组、低位组在前、无符号无 zigzag、uint32 语义。
public struct VarintWriter {
    public private(set) var bytes: [UInt8] = []

    public init() {}

    public mutating func writeByte(_ v: UInt8) { bytes.append(v) }

    public mutating func writeBytes(_ b: [UInt8]) {
        guard !b.isEmpty else { return }
        bytes.append(contentsOf: b)
    }

    public mutating func writeVarint(_ value: UInt32) {
        var v = value
        if v == 0 { bytes.append(0x00); return }
        while v > 0 {
            var b = UInt8(v & 0x7F)
            v >>= 7
            if v > 0 { b |= 0x80 }
            bytes.append(b)
        }
    }

    public var count: Int { bytes.count }

    public func toBytes() -> [UInt8] { bytes }
}

public final class VarintReader {
    private let data: [UInt8]
    public private(set) var pos: Int = 0

    public init(_ data: [UInt8]) { self.data = data }

    public var remaining: Int { data.count - pos }

    public func readByte() throws -> UInt8 {
        guard pos < data.count else { throw IpcCodecError.notEnoughData }
        let b = data[pos]; pos += 1; return b
    }

    public func read(_ n: Int) throws -> [UInt8] {
        guard n >= 0 else { throw IpcCodecError.notEnoughData }
        guard pos + n <= data.count else { throw IpcCodecError.notEnoughData }
        let out = Array(data[pos..<(pos + n)]); pos += n; return out
    }

    public func readUtf8(_ n: Int) throws -> String {
        let raw = try read(n)
        guard let s = String(bytes: raw, encoding: .utf8) else { throw IpcCodecError.invalidUtf8 }
        return s
    }

    public func readVarint() throws -> UInt32 {
        var result: UInt32 = 0
        var shift: UInt32 = 0
        while true {
            let b = try readByte()
            if shift == 28 && (b & 0xF0) != 0 { throw IpcCodecError.varintOverflow }
            result |= UInt32(b & 0x7F) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
            if shift >= 35 { throw IpcCodecError.invalidVarint }
        }
    }
}

public enum IpcCodecError: Error, Equatable, CustomStringConvertible {
    case notEnoughData
    case invalidUtf8
    case varintOverflow
    case invalidVarint
    case unknownValueTag(UInt8)
    case stringTooLarge
    case bytesTooLarge
    case listTooLarge
    case jsonTooLarge

    public var description: String {
        switch self {
        case .notEnoughData: return "Not enough data"
        case .invalidUtf8: return "Invalid UTF-8"
        case .varintOverflow: return "varint overflow"
        case .invalidVarint: return "invalid varint"
        case .unknownValueTag(let t): return "unknown value tag \(t)"
        case .stringTooLarge: return "string too large"
        case .bytesTooLarge: return "bytes too large"
        case .listTooLarge: return "list too large"
        case .jsonTooLarge: return "json too large"
        }
    }
}
