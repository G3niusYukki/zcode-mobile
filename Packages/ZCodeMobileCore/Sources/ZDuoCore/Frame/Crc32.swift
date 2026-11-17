import Foundation

/// CRC-32/IEEE (iso-hdlc), 反射实现 —— 即 zlib/PNG 标准 CRC32。
/// 协议中输出为 8 位小写十六进制,不足补零(zod 校验 `^[0-9a-f]{8}$`)。
/// 校验对象是整条拼接后的消息字节,不是单个分片。
public enum Crc32 {
    static let table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1 == 1) ? (c >> 1) ^ 0xEDB8_8320 : (c >> 1)
            }
            return c
        }
    }()

    public static func compute(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    public static func compute(_ bytes: [UInt8]) -> UInt32 {
        compute(Data(bytes))
    }

    /// 8 位小写 hex,左侧补零 —— 线上格式。
    public static func hex(_ data: Data) -> String {
        String(format: "%08x", compute(data))
    }
}
