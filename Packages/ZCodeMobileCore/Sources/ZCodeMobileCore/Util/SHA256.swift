import Foundation
import CryptoKit

/// 附件校验用 SHA-256(小写 hex)
public enum SHA256 {
    public static func hex(of bytes: [UInt8]) -> String {
        SHA256Digest(data: Data(bytes)).hex
    }
    public static func hex(of data: Data) -> String {
        SHA256Digest(data: data).hex
    }
    struct SHA256Digest {
        let hex: String
        init(data: Data) {
            let digest = CryptoKit.SHA256.hash(data: data)
            hex = digest.map { String(format: "%02x", $0) }.joined()
        }
    }
}
