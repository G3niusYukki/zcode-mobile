import Foundation

/// zcode-agent 通道的 V4 会话业务:握手 → 监听+订阅 → 命令(sendText/stop/resolveInteraction)→ 翻页。
public final class ConversationChannel: @unchecked Sendable {

    public struct HandshakeInfo {
        public var connectionId: String?
        public var protocolVersion: Int = 3
        public var capabilities: [String: Any] = [:]
    }

    public let state = ConversationState()
    public private(set) var handshakeInfo = HandshakeInfo()

    private let client: ChannelClient
    private let logger: (String) -> Void
    private let reassembler = WireReassembler()
    private let lock = NSLock()
    private var eventListenerId: Int?
    private var currentSessionId: String?
    private var currentSubscriptionId: String?
    private var subscribeGeneration = 0
    private let clientId: String        // 与其他通道共用的 v4ClientId
    private let appVersion: String

    public init(client: ChannelClient, clientId: String, appVersion: String = "3.6.5", onLog: ((String) -> Void)? = nil) {
        self.client = client
        self.clientId = clientId
        self.appVersion = appVersion
        self.logger = onLog ?? { _ in }
        state.onResyncNeeded = { [weak self] in
            guard let self else { return }
            Task { try? await self.resync(forceSnapshot: true) }
        }
    }

    // MARK: - 握手(hello → initialize,每桥一次;zcode-agent)

    public func handshake() async throws {
        // hello
        let hello = try await client.call(Self.channel, "helloConversationV4", args: [], timeout: 30)
        if case .json(let text) = hello,
           let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
            let version = synced(lock) { () -> Int in
                handshakeInfo.connectionId = obj["connectionId"] as? String
                handshakeInfo.protocolVersion = obj["protocolVersion"] as? Int ?? 3
                handshakeInfo.capabilities = obj["capabilities"] as? [String: Any] ?? [:]
                return handshakeInfo.protocolVersion
            }
            // initialize(clientHello,zod strict —— 只发基础五字段)
            let clientHello = IpcValue.object([
                ("kind", .string("clientHello")),
                ("protocolVersion", .int(version)),
                ("clientId", .string(clientId)),
                ("clientKind", .string("mobileApp")),
                ("appVersion", .string(appVersion)),
            ])
            do {
                _ = try await client.call(Self.channel, "initializeConversationV4", args: [clientHello], timeout: 30)
            } catch ChannelClient.ChannelError.promiseRejected(let message, _) {
                // clientChanged 属预期(其他通道先 initialize 绑定了 clientId),容忍继续
                if !message.contains("clientChanged") { throw ChannelClient.ChannelError.promiseRejected(message: message, code: nil) }
            }
            return
        }
        throw ChannelClient.ChannelError.malformedHandshake
    }

    static let channel = ChannelClient.channelAgent

    // MARK: - 监听 + 订阅

    /// 102 监听(会话帧;arg = scope 裸对象)。订阅前先挂好,帧先于 ack 到达是常态。返回监听 id。
    @discardableResult
    public func startListening(workspacePath: String, workspaceIdentity: String?) throws -> Int {
        // 监听只挂一次:重复 102 会让每帧被投递多次(实测会导致 seq 错乱与 resync 风暴)
        if let existing = synced(lock, { eventListenerId }) {
            return existing
        }
        let scope = Self.scopeValue(workspacePath: workspacePath, workspaceIdentity: workspaceIdentity)
        let id = try client.listen(Self.channel, event: "onDynamicConversationFrame", arg: scope) { [weak self] value in
            self?.handleConversationEvent(value)
        }
        synced(lock) { eventListenerId = id }
        return id
    }

    /// 订阅一个会话(切换会话 = 旧订阅作废并异步退订;同一时刻只有一个生效订阅)
    public func subscribe(sessionId: String, workspacePath: String, workspaceIdentity: String?) async throws {
        let (old, oldSession, generation) = synced(lock) { () -> (String?, String?, Int) in
            let o = (currentSubscriptionId, currentSessionId)
            currentSessionId = sessionId
            currentSubscriptionId = nil
            subscribeGeneration += 1
            return (o.0, o.1, subscribeGeneration)
        }

        state.reset()
        if let old, let oldSession {
            try? await unsubscribe(subscriptionId: old, sessionId: oldSession, workspacePath: workspacePath, workspaceIdentity: workspaceIdentity)
        }

        var scope = Self.scopePairs(workspacePath: workspacePath, workspaceIdentity: workspaceIdentity)
        scope.append(("sessionId", .string(sessionId)))
        scope.append(("visibility", .string("foreground")))
        let result = try await client.call(Self.channel, "subscribeConversationV4", args: [.object(scope)], timeout: 60)
        var ackSubscriptionId: String?
        if case .json(let text) = result,
           let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
            if let ack = obj["ack"] as? [String: Any] {
                ackSubscriptionId = ack["subscriptionId"] as? String
            }
            ackSubscriptionId = ackSubscriptionId ?? obj["subscriptionId"] as? String
        }
        guard let sid = ackSubscriptionId else {
            ZDlog("[ZCodeMobile][conv] subscribe ack missing subscriptionId")
            throw ChannelClient.ChannelError.promiseRejected(message: "subscribe ack missing subscriptionId", code: nil)
        }
        let isLatest = synced(lock) { () -> Bool in
            guard subscribeGeneration == generation else { return false }
            currentSubscriptionId = sid
            return true
        }
        guard isLatest else {
            ZDlog("[ZCodeMobile][conv] stale subscribe ack discarded %@", sid)
            return
        }
        ZDlog("[ZCodeMobile][conv] subscribed session=%@ as=%@", sessionId, sid)
        logger("[conversation] subscribed \(sessionId) as \(sid)")
    }

    public func unsubscribe(subscriptionId: String, sessionId: String, workspacePath: String, workspaceIdentity: String?) async throws {
        var scope = Self.scopePairs(workspacePath: workspacePath, workspaceIdentity: workspaceIdentity)
        scope.append(("sessionId", .string(sessionId)))
        scope.append(("subscriptionId", .string(subscriptionId)))
        _ = try await client.call(Self.channel, "unsubscribeConversationV4", args: [.object(scope)], timeout: 30)
    }

    public func resync(forceSnapshot: Bool) async throws {
        let (sid, epoch, seq) = synced(lock) { (currentSubscriptionId, state.logEpoch, state.seq) }
        guard let sid else { return }
        var body: [(String, IpcValue)] = [("subscriptionId", .string(sid))]
        if let epoch {
            body.append(("forceSnapshot", .bool(forceSnapshot)))
            body.append(("base", .object([("logEpoch", .string(epoch)), ("seq", .int(seq))])))
        }
        _ = try? await client.call(Self.channel, "resyncConversationV4", args: [.object(body)], timeout: 30)
    }

    /// 向上翻页:拉更早的历史行
    public func loadOlder(sessionId: String, workspacePath: String, workspaceIdentity: String?, limit: Int = 60) async throws -> Bool {
        let (earliest, epoch) = synced(lock) { (state.rows.first?.rowId, state.logEpoch) }
        guard let before = earliest else { return false }

        var scope = Self.scopePairs(workspacePath: workspacePath, workspaceIdentity: workspaceIdentity)
        scope.append(("sessionId", .string(sessionId)))
        scope.append(("beforeRowId", .int(before)))
        scope.append(("limit", .int(limit)))
        let result = try await client.call(Self.channel, "conversationRowsRangeV4", args: [.object(scope)], timeout: 45)
        guard case .json(let text) = result,
              let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return false }
        // atLogEpoch != 当前 logEpoch → 快照失效,整批丢弃
        if let atEpoch = obj["atLogEpoch"] as? String, atEpoch != epoch { return false }
        // 双层包裹兼容 {rows:{rows:[…],hasMore}}
        var rowsRaw = obj["rows"] as? [[String: Any]]
        var hasMore = obj["hasMore"] as? Bool ?? false
        if rowsRaw == nil, let wrapped = obj["rows"] as? [String: Any] {
            rowsRaw = wrapped["rows"] as? [[String: Any]]
            hasMore = wrapped["hasMore"] as? Bool ?? hasMore
        }
        let older = (rowsRaw ?? []).compactMap(ConversationRow.init)
        state.prependOlder(rows: older, hasMore: hasMore)
        return hasMore
    }

    // MARK: - 事件(204 → wire 重组 → topic 帧 → state)

    private func handleConversationEvent(_ value: IpcValue) {
        guard case .json(let text) = value,
              let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
        ZDlog("[ZCodeMobile][conv] 204 frame wireVersion=%@ kind=%@", String(describing: obj["wireVersion"]), String(describing: obj["kind"]))
        // 只关心当前会话的 topic
        let (current, currentSub) = synced(lock) { (currentSessionId, currentSubscriptionId) }

        switch reassembler.accept(obj) {
        case .success(let frameDict):
            guard let frameDict, let frame = TopicFrame(dict: frameDict) else { return }
            guard frame.topic == "conversation/\(current ?? "")" else { return }
            // 帧必须匹配当前订阅(旧订阅的快照/增量一律丢弃,否则双重订阅会引发 resync 风暴)
            if let sub = frame.subscriptionId, let cur = currentSub, sub != cur { return }
            state.apply(frame: frame)
            if frame.payloadKind == "snapshot" {
                ZDlog("[ZCodeMobile][conv] snapshot applied rows=%d title=%@", state.rows.count, state.title ?? "-")
            }
        case .failure(let error):
            logger("[conversation] wire error \(error)")
            Task { try? await resync(forceSnapshot: true) }
        }
    }

    // MARK: - 命令(sendConversationCommandV4)

    public struct CommandAck: Equatable {
        public let status: String
        public let message: String?
        public let reasonCode: String?
        public var isSuccess: Bool { status == "accepted" || status == "duplicate" || status == "noop" }
    }

    private func sendCommand(sessionId: String?, workspacePath: String, workspaceIdentity: String?,
                             type: String, payload: [(String, IpcValue)],
                             baseRevision: Int? = nil, baseLogEpoch: String? = nil,
                             timeout: TimeInterval = 30) async throws -> CommandAck {
        var envelope: [(String, IpcValue)] = [
            ("commandId", .string("cmd-\(UUID().uuidString.lowercased())")),
            ("clientId", .string(clientId)),
            ("sessionId", sessionId.map { .string($0) } ?? .json("null")),
            ("type", .string(type)),
            ("payload", .object(payload)),
            ("issuedAt", .int(Int(Date().timeIntervalSince1970 * 1000))),
        ]
        if let baseRevision { envelope.insert(("baseRevision", .int(baseRevision)), at: 3) }
        if let baseLogEpoch { envelope.insert(("baseLogEpoch", .string(baseLogEpoch)), at: 4) }
        _ = envelope
        var args = Self.scopePairs(workspacePath: workspacePath, workspaceIdentity: workspaceIdentity)
        args.append(("envelope", .object(envelope)))
        let result = try await client.call(Self.channel, "sendConversationCommandV4", args: [.object(args)], timeout: timeout)
        var ack = CommandAck(status: "accepted", message: nil, reasonCode: nil)
        if case .json(let text) = result,
           let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
            let source = (obj["ack"] as? [String: Any]) ?? obj
            ack = CommandAck(
                status: source["status"] as? String ?? "accepted",
                message: source["message"] as? String,
                reasonCode: source["reasonCode"] as? String)
        }
        return ack
    }

    public struct Attachment: Equatable {
        public let ref: String
        public let fileName: String
        public let mime: String
        public let bytes: Int
        public init(ref: String, fileName: String, mime: String, bytes: Int) {
            self.ref = ref; self.fileName = fileName; self.mime = mime; self.bytes = bytes
        }
    }

    /// 发送消息(可带附件)
    @discardableResult
    public func sendText(_ text: String, sessionId: String, workspacePath: String, workspaceIdentity: String?,
                         attachments: [Attachment] = []) async throws -> CommandAck {
        var payload: [(String, IpcValue)] = [
            ("text", .string(text)),
            ("requestedDelivery", .string("startNow")),
        ]
        if !attachments.isEmpty {
            payload.append(("attachments", .array(attachments.map { a in
                .object([
                    ("ref", .string(a.ref)),
                    ("fileName", .string(a.fileName)),
                    ("mime", .string(a.mime)),
                    ("bytes", .int(a.bytes)),
                ])
            })))
        }
        return try await sendCommand(sessionId: sessionId, workspacePath: workspacePath, workspaceIdentity: workspaceIdentity,
                                     type: "sendText", payload: payload)
    }

    // MARK: - 模型 / 思考强度 / 模式

    @discardableResult
    public func switchModel(provider: String, model: String, thought: String,
                            sessionId: String, workspacePath: String, workspaceIdentity: String?,
                            baseRevision: Int?) async throws -> CommandAck {
        try await sendCommand(sessionId: sessionId, workspacePath: workspacePath, workspaceIdentity: workspaceIdentity,
                              type: "switchModelConfig",
                              payload: [("provider", .string(provider)),
                                        ("model", .string(model)),
                                        ("thought", .string(thought))],
                              baseRevision: baseRevision)
    }

    @discardableResult
    public func switchMode(_ mode: String, sessionId: String, workspacePath: String, workspaceIdentity: String?,
                           baseRevision: Int?) async throws -> CommandAck {
        try await sendCommand(sessionId: sessionId, workspacePath: workspacePath, workspaceIdentity: workspaceIdentity,
                              type: "switchCollaborationMode", payload: [("mode", .string(mode))],
                              baseRevision: baseRevision)
    }

    // MARK: - 附件上传(四件套:begin/chunk/commit/abort)

    public enum AttachmentError: Error, Equatable {
        case tooLarge(Int)
        case tooManyChunks(Int)
        case serverRejected(String)
        case progressMismatch(expected: Int, got: Int)
    }

    /// 上传附件,返回可用于 sendText 的 ref
    public func uploadAttachment(data: [UInt8], fileName: String, mime: String,
                                 sessionId: String, workspacePath: String,
                                 workspaceIdentity: String?) async throws -> Attachment {
        let maxBytes = 20 * 1024 * 1024
        let chunkBytes = 384 * 1024
        guard data.count <= maxBytes else { throw AttachmentError.tooLarge(data.count) }
        let totalChunks = max(1, (data.count + chunkBytes - 1) / chunkBytes)
        guard totalChunks <= 64 else { throw AttachmentError.tooManyChunks(totalChunks) }

        let uploadId = "upload-" + UUID().uuidString.lowercased()
        let checksum = "sha256:" + SHA256.hex(of: data)
        var scope = Self.scopePairs(workspacePath: workspacePath, workspaceIdentity: workspaceIdentity)
        scope.append(contentsOf: [
            ("uploadId", .string(uploadId)),
            ("sessionId", .string(sessionId)),
            ("fileName", .string(fileName)),
            ("mime", .string(mime)),
            ("totalBytes", .int(data.count)),
            ("totalChunks", .int(totalChunks)),
            ("checksum", .string(checksum)),
        ])

        // begin(秒传:已 committed 直接给 ref)
        let beginResult = try await client.call(Self.channel, "attachmentBeginV4", args: [.object(scope)], timeout: 60)
        if case .json(let text) = beginResult,
           let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
            if (obj["state"] as? String) == "committed", let ref = obj["ref"] as? String {
                return Attachment(ref: ref, fileName: fileName, mime: mime, bytes: data.count)
            }
        }

        // chunks
        for index in 0..<totalChunks {
            let start = index * chunkBytes
            let end = min(start + chunkBytes, data.count)
            let chunk = Data(data[start..<end]).base64EncodedString()
            var body = Self.scopePairs(workspacePath: workspacePath, workspaceIdentity: workspaceIdentity)
            body.append(contentsOf: [
                ("uploadId", .string(uploadId)),
                ("sessionId", .string(sessionId)),
                ("chunkIndex", .int(index)),
                ("dataBase64", .string(chunk)),
            ])
            let result = try await client.call(Self.channel, "attachmentChunkV4", args: [.object(body)], timeout: 60)
            if case .json(let text) = result,
               let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
               let next = obj["nextChunkIndex"] as? Int, next != index + 1, next != totalChunks {
                throw AttachmentError.progressMismatch(expected: index + 1, got: next)
            }
        }

        // commit
        var commitBody = Self.scopePairs(workspacePath: workspacePath, workspaceIdentity: workspaceIdentity)
        commitBody.append(contentsOf: [
            ("uploadId", .string(uploadId)),
            ("sessionId", .string(sessionId)),
        ])
        let commitResult = try await client.call(Self.channel, "attachmentCommitV4", args: [.object(commitBody)], timeout: 60)
        guard case .json(let text) = commitResult,
              let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let ref = obj["ref"] as? String else {
            throw AttachmentError.serverRejected("commit missing ref")
        }
        return Attachment(ref: ref, fileName: fileName, mime: mime, bytes: data.count)
    }

    /// 新建会话(在活跃工作区)
    @discardableResult
    public func createSession(workspacePath: String, workspaceIdentity: String?) async throws -> CommandAck {
        try await sendCommand(sessionId: nil, workspacePath: workspacePath, workspaceIdentity: workspaceIdentity,
                              type: "createSession",
                              payload: [("workspaceId", .string(workspacePath))])
    }

    /// 停止当前执行
    @discardableResult
    public func stop(sessionId: String, workspacePath: String, workspaceIdentity: String?,
                     expectedForegroundExecutionId: String?) async throws -> CommandAck {
        var payload: [(String, IpcValue)] = []
        if let execId = expectedForegroundExecutionId {
            payload.append(("expectedForegroundExecutionId", .string(execId)))
        }
        return try await sendCommand(sessionId: sessionId, workspacePath: workspacePath, workspaceIdentity: workspaceIdentity,
                                     type: "stop", payload: payload)
    }

    /// 权限/提问应答。answer 只透传(optionId 原样,绝不映射序号)
    @discardableResult
    public func resolveInteraction(interactionId: String, optionId: String? = nil, freeText: String? = nil,
                                   action: String? = nil, contentJSON: String? = nil,
                                   sessionId: String, workspacePath: String, workspaceIdentity: String?) async throws -> CommandAck {
        var answer: [(String, IpcValue)] = []
        if let optionId { answer.append(("optionId", .string(optionId))) }
        if let freeText { answer.append(("freeText", .string(freeText))) }
        if let action { answer.append(("action", .string(action))) }
        if let contentJSON { answer.append(("content", .json(contentJSON))) }
        return try await sendCommand(sessionId: sessionId, workspacePath: workspacePath, workspaceIdentity: workspaceIdentity,
                                     type: "resolveInteraction",
                                     payload: [("interactionId", .string(interactionId)), ("answer", .object(answer))])
    }

    // MARK: - 工具

    static func scopePairs(workspacePath: String, workspaceIdentity: String?) -> [(String, IpcValue)] {
        var pairs: [(String, IpcValue)] = [("workspacePath", .string(workspacePath))]
        if let identity = workspaceIdentity, !identity.isEmpty {
            pairs.append(("workspaceIdentity", .string(identity)))
        }
        return pairs
    }

    static func scopeValue(workspacePath: String, workspaceIdentity: String?) -> IpcValue {
        .object(scopePairs(workspacePath: workspacePath, workspaceIdentity: workspaceIdentity))
    }
}

extension ChannelClient.ChannelError {
    static var malformedHandshake: ChannelClient.ChannelError {
        .promiseRejected(message: "malformed hello response", code: nil)
    }
}

extension IpcValue {
    static func bool(_ b: Bool) -> IpcValue { .json(b ? "true" : "false") }
}
