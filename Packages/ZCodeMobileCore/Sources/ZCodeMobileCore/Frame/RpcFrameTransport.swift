import Foundation

/// rpc-frame 分片传输层 —— 手机↔桌面真正的会话数据通道。
///
/// 发送: 整条消息 CRC32 → 等长分片(默认 512 KiB)→ 每片独立 canonical base64 →
///       按官方键序组装信封 JSON(交给上层包 data 信封发 WS)。
/// 接收: 身份三元组全等过滤 → 按 messageSeq 落槽组装(容忍乱序)→
///       集齐后校验长度+CRC → 回累计 ack → 投递 onMessage。
///
/// seq/messageSeq: 每方向、每桥独立,从 1 起;seq 每分片 +1,messageSeq 每消息 +1。
public final class RpcFrameTransport: @unchecked Sendable {
    public enum TransportError: Error, Equatable, CustomStringConvertible {
        case emptyMessage
        case messageTooLarge(Int)
        case envelopeTooLarge(Int)
        case fragmentLimitExceeded(Int)
        case invalidBase64
        case notOpen

        public var description: String {
            switch self {
            case .emptyMessage: return "remote.rpcFrame.emptyMessage"
            case .messageTooLarge(let n): return "remote.rpcFrame.messageTooLarge(\(n))"
            case .envelopeTooLarge(let n): return "remote.rpcFrame.envelopeTooLarge(\(n))"
            case .fragmentLimitExceeded(let n): return "remote.rpcFrame.fragmentLimitExceeded(\(n))"
            case .invalidBase64: return "remote.rpcFrame.invalidBase64"
            case .notOpen: return "remote.rpcFrame.notOpen"
            }
        }
    }

    /// 桥身份三元组。「出现一个键就必须三个全等」—— ack 漏 bridgeGeneration 会被对端静默丢弃。
    public struct BridgeIdentity: Equatable, Sendable {
        public let bridgeSessionId: String
        public let bridgeGeneration: Int?
        public let recoveryId: String?

        public init(bridgeSessionId: String, bridgeGeneration: Int? = nil, recoveryId: String? = nil) {
            self.bridgeSessionId = bridgeSessionId
            self.bridgeGeneration = bridgeGeneration
            self.recoveryId = recoveryId
        }

        /// 三字段全等(含「缺席 === 缺席」)
        func matches(payload: [String: Any]) -> Bool {
            guard let sid = payload["bridgeSessionId"] as? String, sid == bridgeSessionId else { return false }
            let gen = payload["bridgeGeneration"] as? Int
            if gen != bridgeGeneration { return false } // Int? 严格比较,nil===缺键
            let rec = payload["recoveryId"] as? String
            if rec != recoveryId { return false }
            return true
        }

        var identityPairs: [(String, IpcValue)] {
            var pairs: [(String, IpcValue)] = [("bridgeSessionId", .string(bridgeSessionId))]
            if let g = bridgeGeneration { pairs.append(("bridgeGeneration", .int(g))) }
            if let r = recoveryId { pairs.append(("recoveryId", .string(r))) }
            return pairs
        }
    }

    // 发送侧上限(对端 zod 硬校验,必须官方值)
    public static let maxMessageBytes = 16 * 1024 * 1024
    public static let maxFragments = 64
    public static let maxPhysicalFrameBytes = 1_048_576
    public static let defaultChunkBytes = 512 * 1024
    // 接收侧放宽(采 zemote 口径:长上下文快照)
    static let recvMaxMessageBytes = 64 * 1024 * 1024
    static let recvMaxFragments = 256
    static let assemblyTimeout: TimeInterval = 30

    /// 上行回调:传入 payload 对象的 JSON 文本,由上层包 data 信封发 WS。
    public var sendPayload: ((String) -> Void)?
    /// 完整消息回调(直接喂 ChannelClient)
    public var onMessage: ((Data) -> Void)?
    /// 收到 bridge-degraded(reason)
    public var onDegraded: ((String) -> Void)?

    private let lock = NSLock()
    private var identity: BridgeIdentity
    private let chunkBytes: Int
    private var nextPhysicalSeq: UInt64 = 1
    private var nextMessageSeq: UInt64 = 1
    private var degraded = false
    private var lastAckedMessageSeq: UInt64 = 0

    // 接收组装表: messageSeq → Assembly
    private struct Assembly {
        var checksum: String
        var fragmentCount: Int
        var messageBytes: Int
        var fragments: [Int: Data] = [:]
        var stagedBytes: Int = 0
        var firstSeenAt: Date = Date()
    }

    private var assemblies: [UInt64: Assembly] = [:]

    /// - Parameters:
    ///   - identity: 桥身份(从 workspace-bridge-ready 的 bridge 对象取得)
    ///   - chunkBytes: 分片大小(测试可注入小值;生产用默认 512 KiB)
    public init(identity: BridgeIdentity, chunkBytes: Int = RpcFrameTransport.defaultChunkBytes) {
        self.identity = identity
        self.chunkBytes = max(1, chunkBytes)
    }

    /// 换桥:重置计数器与新身份(seq/messageSeq 从 1 重新开始)
    public func swapBridge(_ newIdentity: BridgeIdentity) {
        lock.lock(); defer { lock.unlock() }
        identity = newIdentity
        nextPhysicalSeq = 1
        nextMessageSeq = 1
        degraded = false
        assemblies.removeAll()
        lastAckedMessageSeq = 0
    }

    public func markDegraded() {
        lock.lock(); defer { lock.unlock() }
        degraded = true
    }

    // MARK: - 发送

    public func sendMessage(_ data: Data) throws {
        try sendMessage([UInt8](data))
    }

    public func sendMessage(_ bytes: [UInt8]) throws {
        lock.lock()
        if degraded { lock.unlock(); throw TransportError.notOpen }
        guard !bytes.isEmpty else { lock.unlock(); throw TransportError.emptyMessage }
        guard bytes.count <= Self.maxMessageBytes else {
            lock.unlock(); throw TransportError.messageTooLarge(bytes.count)
        }

        let messageSeq = nextMessageSeq
        nextMessageSeq += 1
        let messageBytes = bytes.count
        let crcHex = Crc32.hex(Data(bytes))
        let fragmentCount = Int(ceil(Double(messageBytes) / Double(chunkBytes)))
        guard fragmentCount <= Self.maxFragments else {
            lock.unlock(); throw TransportError.fragmentLimitExceeded(fragmentCount)
        }

        var envelopes: [String] = []
        for fragmentIndex in 0..<fragmentCount {
            let start = fragmentIndex * chunkBytes
            let end = min(start + chunkBytes, messageBytes)
            let slice = Data(bytes[start..<end])
            let seq = nextPhysicalSeq
            nextPhysicalSeq += 1

            var pairs: [(String, IpcValue)] = [
                ("zcode_type", .string("rpc-frame")),
            ]
            pairs.append(contentsOf: identity.identityPairs)
            pairs.append(contentsOf: [
                ("seq", .int(Int(seq))),
                ("messageSeq", .int(Int(messageSeq))),
                ("fragmentIndex", .int(fragmentIndex)),
                ("fragmentCount", .int(fragmentCount)),
                ("messageBytes", .int(messageBytes)),
                ("checksum", .object([("algorithm", .string("crc32")), ("value", .string(crcHex))])),
                ("dataBase64", .string(slice.base64EncodedString())),
            ])
            envelopes.append(IpcValue.object(pairs).jsonValueText)
        }
        lock.unlock()

        // 出站物理帧上限校验(预留外层 data 信封余量)
        for envelope in envelopes {
            let byteCount = envelope.utf8.count
            guard byteCount + 128 <= Self.maxPhysicalFrameBytes else {
                throw TransportError.envelopeTooLarge(byteCount)
            }
        }
        for envelope in envelopes { sendPayload?(envelope) }
    }

    // MARK: - 接收

    /// 收到 data.payload(zcode_type 已判明为 rpc-frame / rpc-frame-ack / bridge-degraded 之外的入口分流在调用方)。
    /// 返回 true 表示本层已消费。
    @discardableResult
    public func acceptPayload(_ payload: [String: Any]) -> Bool {
        let type = payload["zcode_type"] as? String

        if type == "bridge-degraded" {
            let reason = payload["reason"] as? String ?? "unknown"
            lock.lock(); degraded = true; lock.unlock()
            onDegraded?(reason)
            return true
        }

        lock.lock()
        let ident = identity
        let isDegraded = degraded
        lock.unlock()
        guard !isDegraded, ident.matches(payload: payload) else { return false }

        switch type {
        case "rpc-frame":
            acceptFrame(payload, identity: ident)
        case "rpc-frame-ack":
            // 无重放缓冲时 ack 仅用于诊断;不做处理(差异采信表 #13)
            break
        default:
            return false
        }
        return true
    }

    private func acceptFrame(_ payload: [String: Any], identity: BridgeIdentity) {
        guard let seqNum = payload["seq"] as? Int, seqNum > 0,
              let messageSeqNum = payload["messageSeq"] as? Int, messageSeqNum > 0,
              let fragmentIndex = payload["fragmentIndex"] as? Int, fragmentIndex >= 0,
              let fragmentCount = payload["fragmentCount"] as? Int,
              let messageBytes = payload["messageBytes"] as? Int, messageBytes > 0,
              let checksum = payload["checksum"] as? [String: Any],
              let crcValue = checksum["value"] as? String,
              let b64 = payload["dataBase64"] as? String else { return }

        guard fragmentCount <= Self.recvMaxFragments, messageBytes <= Self.recvMaxMessageBytes,
              fragmentIndex < fragmentCount else { return }

        // canonical base64 校验(重编码必须还原)
        guard let decoded = Data(base64Encoded: b64),
              decoded.base64EncodedString() == b64 else {
            sendAck(identity: identity) // 坏帧也要维持 ack 心跳不误伤
            return
        }

        let messageSeq = UInt64(messageSeqNum)
        lock.lock()
        var assembly = assemblies[messageSeq] ?? Assembly(
            checksum: crcValue, fragmentCount: fragmentCount, messageBytes: messageBytes)
        if assembly.fragments[fragmentIndex] == nil {
            assembly.fragments[fragmentIndex] = decoded
            assembly.stagedBytes += decoded.count
        }
        assemblies[messageSeq] = assembly
        let complete = assembly.fragments.count == assembly.fragmentCount
        var outData: Data? = nil
        if complete {
            var joined = Data()
            joined.reserveCapacity(assembly.messageBytes)
            for i in 0..<assembly.fragmentCount {
                if let fragment = assembly.fragments[i] { joined.append(fragment) }
            }
            if joined.count == assembly.messageBytes, Crc32.hex(joined) == assembly.checksum {
                outData = joined
                assemblies.removeValue(forKey: messageSeq)
            } else {
                // 校验失败:丢弃该消息,等待对端降级/重开桥兜底
                assemblies.removeValue(forKey: messageSeq)
            }
        }
        lock.unlock()

        if let data = outData {
            sendAck(identity: identity, acking: messageSeq)
            onMessage?(data)
        }
    }

    /// 累计 ack:回带完整身份三元组(有 generation/recoveryId 必须回带)
    private func sendAck(identity: BridgeIdentity, acking: UInt64? = nil) {
        var ackSeq = acking ?? 0
        lock.lock()
        if acking == nil { ackSeq = lastAckedMessageSeq }
        lastAckedMessageSeq = max(lastAckedMessageSeq, ackSeq)
        lock.unlock()
        guard ackSeq > 0 else { return }

        var pairs: [(String, IpcValue)] = [("zcode_type", .string("rpc-frame-ack"))]
        pairs.append(contentsOf: identity.identityPairs)
        pairs.append(("ackMessageSeq", .int(Int(ackSeq))))
        sendPayload?(IpcValue.object(pairs).jsonValueText)
    }

    /// 组装超时清理(30s),由上层定时调用
    public func sweep(now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        let cutoff = now.addingTimeInterval(-Self.assemblyTimeout)
        assemblies = assemblies.filter { $0.value.firstSeenAt > cutoff }
    }
}

extension IpcValue {
    /// .json 载荷的文本形式(内部便捷)
    var jsonValueText: String {
        if case .json(let text) = self { return text }
        return IpcCodec.jsonText(of: self)
    }
}
