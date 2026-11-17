import Foundation

/// 204 事件载荷 = 逻辑帧信封(wire 层)重组器。
/// complete 帧直接取 frame;fragment 帧按 logicalFrameId 分片拼接(CRC32 校验)后 UTF-8 → JSON。
/// 兼容无 wire 封装的旧形态(直接下发逻辑帧)。
public final class WireReassembler: @unchecked Sendable {

    public enum WireError: Error, Equatable {
        case metadataMismatch(String)
        case checksumMismatch(String)
        case invalidPayload(String)
    }

    private struct Assembly {
        var fragmentCount: Int
        var logicalBytes: Int
        var checksum: String
        var topic: String?
        var subscriptionId: String?
        var fragments: [Int: Data] = [:]
        var createdAt = Date()
    }

    private let lock = NSLock()
    private var assemblies: [String: Assembly] = [:]
    private let maxConcurrent = 32
    private let maxFragments = 1024
    private let maxBytes = 16 * 1024 * 1024

    public init() {}

    /// 输入 204 data(JSON 对象),输出 topic 帧(kind=complete 时为 frame,重组后为解析的 JSON)。
    /// 返回 nil 表示是不关心的帧或仍在等待分片。
    public func accept(_ obj: [String: Any]) -> Result<[String: Any]?, WireError> {
        // 无 wire 封装的旧形态:直接是 topic 帧
        if obj["payload"] != nil, obj["wireVersion"] == nil {
            return .success(obj)
        }
        guard obj["wireVersion"] != nil, let kind = obj["kind"] as? String else {
            return .success(nil) // 未知形态,忽略
        }
        switch kind {
        case "complete":
            guard let frame = obj["frame"] as? [String: Any] else {
                return .failure(.invalidPayload("complete frame missing frame"))
            }
            return .success(frame)

        case "fragment":
            guard let frameId = obj["logicalFrameId"] as? String,
                  let fragmentIndex = obj["fragmentIndex"] as? Int,
                  let fragmentCount = obj["fragmentCount"] as? Int,
                  let logicalBytes = obj["logicalBytes"] as? Int,
                  let checksum = obj["checksum"] as? [String: Any],
                  let crc = checksum["value"] as? String,
                  let b64 = obj["dataBase64"] as? String,
                  let decoded = Data(base64Encoded: b64) else {
                return .failure(.invalidPayload("fragment missing fields"))
            }
            guard fragmentCount > 0, fragmentCount <= maxFragments,
                  logicalBytes > 0, logicalBytes <= maxBytes, fragmentIndex >= 0, fragmentIndex < fragmentCount else {
                return .failure(.invalidPayload("fragment limits"))
            }

            lock.lock()
            var assembly = assemblies[frameId] ?? Assembly(
                fragmentCount: fragmentCount, logicalBytes: logicalBytes, checksum: crc,
                topic: obj["topic"] as? String, subscriptionId: obj["subscriptionId"] as? String)
            // 元数据全等校验
            if assembly.fragmentCount != fragmentCount || assembly.logicalBytes != logicalBytes || assembly.checksum != crc {
                lock.unlock()
                assemblies.removeValue(forKey: frameId)
                return .failure(.metadataMismatch(frameId))
            }
            if assembly.fragments[fragmentIndex] == nil {
                assembly.fragments[fragmentIndex] = decoded
            }
            assemblies[frameId] = assembly
            let complete = assembly.fragments.count == assembly.fragmentCount
            lock.unlock()

            if !complete {
                // 60s TTL 清理
                sweep()
                return .success(nil)
            }
            lock.lock()
            let finished = assemblies.removeValue(forKey: frameId)
            lock.unlock()
            guard let a = finished else { return .success(nil) }

            var joined = Data()
            joined.reserveCapacity(a.logicalBytes)
            for i in 0..<a.fragmentCount {
                if let fragment = a.fragments[i] { joined.append(fragment) }
            }
            guard joined.count == a.logicalBytes else {
                return .failure(.metadataMismatch("length \(joined.count) != \(a.logicalBytes)"))
            }
            guard Crc32.hex(joined) == a.checksum else {
                return .failure(.checksumMismatch(frameId))
            }
            guard let text = String(data: joined, encoding: .utf8),
                  let frameObj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                return .failure(.invalidPayload("fragment payload not json"))
            }
            return .success(frameObj)

        default:
            return .success(nil)
        }
    }

    private func sweep() {
        lock.lock(); defer { lock.unlock() }
        let cutoff = Date().addingTimeInterval(-60)
        assemblies = assemblies.filter { $0.value.createdAt > cutoff }
        if assemblies.count > maxConcurrent {
            assemblies.removeAll()
        }
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        assemblies.removeAll()
    }
}

/// topic 帧轻量访问器(conversation / controller / sessions-index 共用)
public struct TopicFrame {
    public let topic: String
    public let subscriptionId: String?
    public let fromSeq: Int
    public let toSeq: Int
    public let payloadKind: String          // snapshot | deltas
    public let snapshot: [String: Any]?
    public let deltas: [[String: Any]]

    public init?(dict: [String: Any]) {
        guard let topic = dict["topic"] as? String,
              let payload = dict["payload"] as? [String: Any],
              let kind = payload["kind"] as? String else { return nil }
        self.topic = topic
        self.subscriptionId = dict["subscriptionId"] as? String
        self.fromSeq = dict["fromSeq"] as? Int ?? 0
        self.toSeq = dict["toSeq"] as? Int ?? 0
        self.payloadKind = kind
        self.snapshot = payload["snapshot"] as? [String: Any]
        self.deltas = payload["deltas"] as? [[String: Any]] ?? []
    }
}
