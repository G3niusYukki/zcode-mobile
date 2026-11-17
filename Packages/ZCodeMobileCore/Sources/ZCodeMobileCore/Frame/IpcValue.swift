import Foundation

/// ZCode IPC 值模型(Vql 二进制编码)。
/// tag: 0=Undefined 1=String 2=Buffer 3=VSBuffer 4=Array 5=Object(JSON 文本) 6=Int
///
/// 设计要点(对照 docs/specs/frame-codec.md §2):
/// - 字节统一编 tag 3(VSBuffer),解码端 2/3 都接受 —— 线上字节一致,互操作无影响
/// - Int 只支持 0...2^31-1(协议实际值域);负数/超界数走 JSON(官方 uint32 补码读回有损,不采)
/// - 对象以原始 JSON 文本承载,由 `IpcValue.object(_:)` 保序构造
public indirect enum IpcValue: Equatable, Sendable {
    case undefined
    case string(String)
    case int(Int)
    case bytes([UInt8])
    case array([IpcValue])
    /// 原始 JSON 文本(对象/数字/布尔/null 均可);由调用方保证是合法 JSON
    case json(String)

    /// 保序 JSON 对象便捷构造:`.object([("workspacePath", .string("/w")), ...])`
    public static func object(_ pairs: [(String, IpcValue)]) -> IpcValue {
        .json(IpcCodec.writeJSON(pairs))
    }
}

public enum IpcCodec {
    static let tagUndefined: UInt8 = 0x00
    static let tagString: UInt8 = 0x01
    static let tagBuffer: UInt8 = 0x02
    static let tagVSBuffer: UInt8 = 0x03
    static let tagArray: UInt8 = 0x04
    static let tagObject: UInt8 = 0x05
    static let tagInt: UInt8 = 0x06

    /// 解码防御上限(照 Kotlin IpcCodec)
    public static let maxContainerItems = 100_000
    public static let maxValueBytes = 16 * 1024 * 1024

    // MARK: - 编码

    public static func encode(_ value: IpcValue) -> [UInt8] {
        var w = VarintWriter()
        encode(into: &w, value: value)
        return w.toBytes()
    }

    public static func encode(into w: inout VarintWriter, value: IpcValue) {
        switch value {
        case .undefined:
            w.writeByte(tagUndefined)
        case .string(let s):
            let utf8 = Array(s.utf8)
            w.writeByte(tagString)
            w.writeVarint(UInt32(utf8.count))
            w.writeBytes(utf8)
        case .int(let i):
            if i >= 0, i <= Int(Int32.max) {
                w.writeByte(tagInt)
                w.writeVarint(UInt32(i))
            } else {
                // 负数/超 int32 → JSON 数字文本(差异采信表 #2)
                encode(into: &w, value: .json(String(i)))
            }
        case .bytes(let b):
            w.writeByte(tagVSBuffer)
            w.writeVarint(UInt32(b.count))
            w.writeBytes(b)
        case .array(let items):
            w.writeByte(tagArray)
            w.writeVarint(UInt32(items.count))
            for item in items { encode(into: &w, value: item) }
        case .json(let text):
            let utf8 = Array(text.utf8)
            w.writeByte(tagObject)
            w.writeVarint(UInt32(utf8.count))
            w.writeBytes(utf8)
        }
    }

    /// RPC 报文 = 两个顶层值顺序拼接(无总长前缀)。
    /// 请求: serialize([type, id, channel, method]) ++ serialize(args)
    public static func encodeRequest(type: Int, id: Int, channel: String, method: String, args: [IpcValue]) -> [UInt8] {
        let header = IpcCodec.encode(.array([.int(type), .int(id), .string(channel), .string(method)]))
        let body = IpcCodec.encode(.array(args))
        return header + body
    }

    /// 事件监听第二段是单个值(listen 传监听参数,dispose 传 undefined)
    public static func encodeEvent(type: Int, id: Int, arg: IpcValue) -> [UInt8] {
        let header = IpcCodec.encode(.array([.int(type), .int(id)]))
        let body = IpcCodec.encode(arg)
        return header + body
    }

    // MARK: - 解码

    public static func decode(_ data: [UInt8]) throws -> IpcValue {
        let r = VarintReader(data)
        let v = try decode(from: r)
        return v
    }

    public static func decode(from r: VarintReader) throws -> IpcValue {
        let tag = try r.readByte()
        switch tag {
        case tagUndefined:
            return .undefined
        case tagString:
            let len = try r.readVarint()
            guard Int(len) <= maxValueBytes else { throw IpcCodecError.stringTooLarge }
            return .string(try r.readUtf8(Int(len)))
        case tagBuffer, tagVSBuffer:
            let len = try r.readVarint()
            guard Int(len) <= maxValueBytes else { throw IpcCodecError.bytesTooLarge }
            return .bytes(try r.read(Int(len)))
        case tagArray:
            let count = try r.readVarint()
            guard Int(count) <= maxContainerItems else { throw IpcCodecError.listTooLarge }
            var items: [IpcValue] = []
            items.reserveCapacity(min(Int(count), 64))
            for _ in 0..<count { items.append(try decode(from: r)) }
            return .array(items)
        case tagObject:
            let len = try r.readVarint()
            guard Int(len) <= maxValueBytes else { throw IpcCodecError.jsonTooLarge }
            return .json(try r.readUtf8(Int(len)))
        case tagInt:
            return .int(Int(try r.readVarint()))
        default:
            throw IpcCodecError.unknownValueTag(tag)
        }
    }

    /// 解析一条完整 RPC 报文(两个顶层值):
    /// 返回 (header 数组, 第二个值)。服务端帧 header = [type, id],第二段为应答/事件载荷。
    public static func decodeMessage(_ data: [UInt8]) throws -> (header: [IpcValue], second: IpcValue) {
        let r = VarintReader(data)
        guard case .array(let header)? = try? decode(from: r) else {
            throw IpcCodecError.notEnoughData
        }
        let second = try decode(from: r)
        return (header, second)
    }

    // MARK: - 保序 JSON 写出(用于 tag5 载荷与 rpc-frame 信封)

    static func writeJSON(_ pairs: [(String, IpcValue)]) -> String {
        var out = "{"
        for (i, pair) in pairs.enumerated() {
            if i > 0 { out += "," }
            out += jsonEscaped(pair.0) + ":" + jsonText(of: pair.1)
        }
        return out + "}"
    }

    static func jsonText(of value: IpcValue) -> String {
        switch value {
        case .undefined: return "null" // 仅防御;协议中不应出现
        case .string(let s): return jsonEscaped(s)
        case .int(let i): return String(i)
        case .bytes(let b):
            // 官方约定 __zcode_rpc_nested_uint8array_v1(见规格 §2.6,当前参数集未用到,保持对齐)
            return "{\"__zcode_rpc_nested_uint8array_v1\":true,\"base64\":\"\(Data(b).base64EncodedString())\"}"
        case .array(let items):
            return "[" + items.map(jsonText(of:)).joined(separator: ",") + "]"
        case .json(let text): return text
        }
    }

    static func jsonEscaped(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
