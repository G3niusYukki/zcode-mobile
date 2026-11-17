import Foundation

// MARK: - bootstrap 工作区模型

public struct WorkspaceInfo: Identifiable, Equatable {
    public let workspacePath: String
    public let workspaceIdentity: String?
    public let label: String
    public let kind: String               // local | remote
    public let connectionState: String?
    public var id: String { workspaceIdentity ?? workspacePath }

    public init(workspacePath: String, workspaceIdentity: String?, label: String,
                kind: String = "local", connectionState: String? = nil) {
        self.workspacePath = workspacePath
        self.workspaceIdentity = workspaceIdentity
        self.label = label
        self.kind = kind
        self.connectionState = connectionState
    }

    init(dict: [String: Any]) {
        workspacePath = dict["workspacePath"] as? String ?? ""
        workspaceIdentity = dict["workspaceIdentity"] as? String
        label = dict["label"] as? String ?? (workspacePath as NSString).lastPathComponent
        kind = dict["kind"] as? String ?? "local"
        connectionState = dict["connectionState"] as? String
    }
}

public enum BootstrapResult {
    case workspaces([WorkspaceInfo], activeWorkspaceKey: String?)
}

// MARK: - 单工作区 bridge(每工作区一套:transport + 通道 + 会话流)

final class WorkspaceBridge {
    let workspace: WorkspaceInfo
    let identity: RpcFrameTransport.BridgeIdentity
    let transport: RpcFrameTransport
    let channelClient: ChannelClient
    let conversation: ConversationChannel

    init(workspace: WorkspaceInfo, identity: RpcFrameTransport.BridgeIdentity,
         transport: RpcFrameTransport, channelClient: ChannelClient,
         conversation: ConversationChannel) {
        self.workspace = workspace
        self.identity = identity
        self.transport = transport
        self.channelClient = channelClient
        self.conversation = conversation
    }
}

public enum RelayClientBridgeError: Error, Equatable {
    case payloadTimeout(String)
    case bridgeError(String)
    case noWorkspace
    case bridgeOpenFailed(String)
}

// MARK: - BridgeSession:多工作区桥管理器

/// 每个工作区一条独立 bridge(workspace-bridge-open 的 workspaceKey 决定作用域)。
/// bootstrap 的活动工作区为主桥(承载 window-controller 全局任务列表);
/// 打开其他工作区的会话时按需开新桥。
public final class BridgeSession: @unchecked Sendable {

    public struct Status: Equatable {
        public var phase: Phase
        public var workspaces: [WorkspaceInfo] = []
        public enum Phase: Equatable { case idle, connecting, bootstrapping, openingBridge, ready, failed(String) }
    }

    private let relay: RelayClient
    private let logger: (String) -> Void
    private let appVersion: String
    private let lock = NSLock()

    private var primaryBridge: WorkspaceBridge?
    private var bridges: [String: WorkspaceBridge] = [:]     // workspaceKey → bridge
    private var liveTransports: [ObjectIdentifier: RpcFrameTransport] = [:] // 建桥期间即可路由 rpc-frame
    private var openingBridges: [String: Task<WorkspaceBridge, Error>] = [:]
    private var bridgeGenerationCounter = 0
    private let terminalClientSessionId = "swift-term-" + UUID().uuidString.lowercased()
    private let v4ClientId = "ios-" + UUID().uuidString.lowercased()
    private var bootstrapTask: Task<Void, Error>?

    // 待匹配的 bridge-ready(bridgeSessionId → continuation)
    private var readyWaiters: [String: CheckedContinuation<[String: Any], Error>] = [:]

    public private(set) var status = Status(phase: .idle)
    public var onStatusChange: ((Status) -> Void)?
    public var onReady: ((WorkspaceInfo) -> Void)?

    /// 当前会话流(选中会话所在工作区的桥)
    public private(set) var activeConversation: ConversationChannel?
    public private(set) var activeConversationWorkspace: WorkspaceInfo?

    /// 全局任务列表(主桥承载)
    public let controller: ControllerChannel

    public init(relay: RelayClient, appVersion: String = "3.6.5", onLog: ((String) -> Void)? = nil) {
        self.relay = relay
        self.appVersion = appVersion
        self.logger = onLog ?? { _ in }
        // controller 暂挂在占位 client,主桥建立后回填
        let placeholderClient = ChannelClient()
        self.controller = ControllerChannel(client: placeholderClient)

        relay.onPayload = { [weak self] payload in
            self?.handlePayload(payload)
        }
        relay.onPaired = { [weak self] in
            self?.onPaired()
        }
    }

    // MARK: 状态

    private func setStatus(_ phase: Status.Phase, workspaces: [WorkspaceInfo]? = nil) {
        lock.lock()
        status.phase = phase
        if let workspaces { status.workspaces = workspaces }
        let snapshot = status
        lock.unlock()
        onStatusChange?(snapshot)
        if case .ready = phase, let ws = activeConversationWorkspace ?? primaryBridge?.workspace {
            onReady?(ws)
        }
    }

    private func onPaired() {
        bootstrapTask?.cancel()
        guard case .paired = relay.state else { return }
        bootstrapTask = Task { [weak self] in
            await self?.bootstrapAndOpen()
        }
    }

    public func bootstrapNow() {
        bootstrapTask?.cancel()
        bootstrapTask = Task { [weak self] in
            await self?.bootstrapAndOpen()
        }
    }

    // MARK: bootstrap + 主桥

    private func bootstrapAndOpen() async {
        setStatus(.bootstrapping)
        do {
            let requestId = "boot-\(Int(Date().timeIntervalSince1970 * 1000))"
            let bootPayload: [(String, IpcValue)] = [
                ("zcode_type", .string("bootstrap-request")),
                ("requestId", .string(requestId)),
                ("terminalClientSessionId", .string(terminalClientSessionId)),
            ]
            let response = try await awaitPayload("bootstrap-response", timeout: 15) { [relay] in
                relay.sendPayload(IpcValue.object(bootPayload).jsonValueText)
            }
            guard let result = response["result"] as? [String: Any] else {
                throw RelayClientBridgeError.bridgeError("bootstrap missing result")
            }
            let workspaces = (result["workspaces"] as? [[String: Any]] ?? []).map(WorkspaceInfo.init)
            let activeKey = result["activeWorkspaceKey"] as? String
            let active = workspaces.first(where: { $0.id == activeKey || $0.workspacePath == activeKey })
                ?? workspaces.first(where: { $0.connectionState == "connected" })
                ?? workspaces.first
            lock.lock()
            status.workspaces = workspaces
            lock.unlock()
            guard let workspace = active else { throw RelayClientBridgeError.noWorkspace }

            let bridge = try await openBridge(for: workspace)
            lock.lock()
            primaryBridge = bridge
            bridges[workspace.id] = bridge   // 主桥也入映射,避免同工作区重复开桥
            lock.unlock()
            // 主桥承载全局 controller
            controller.rebind(client: bridge.channelClient)
            try controller.start()
            try await controller.subscribeTopics()

            setStatus(.ready)
            logger("[bridge] primary ready ws=\(workspace.workspacePath)")
        } catch {
            logger("[bridge] bootstrap failed: \(error)")
            setStatus(.failed(String(describing: error)))
        }
    }

    // MARK: 打开任意工作区桥(串行化)

    /// 确保指定工作区的桥存在;重复调用复用同一 Task
    func ensureBridge(for workspace: WorkspaceInfo) async throws -> WorkspaceBridge {
        lock.lock()
        if let existing = bridges[workspace.id] {
            lock.unlock()
            return existing
        }
        if let inflight = openingBridges[workspace.id] {
            lock.unlock()
            return try await inflight.value
        }
        let task = Task<WorkspaceBridge, Error> { [weak self] in
            guard let self else { throw RelayClientBridgeError.bridgeOpenFailed("gone") }
            return try await self.openBridge(for: workspace)
        }
        openingBridges[workspace.id] = task
        lock.unlock()

        do {
            let bridge = try await task.value
            lock.lock()
            bridges[workspace.id] = bridge
            openingBridges[workspace.id] = nil
            lock.unlock()
            return bridge
        } catch {
            lock.lock()
            openingBridges[workspace.id] = nil
            lock.unlock()
            throw error
        }
    }

    private func openBridge(for workspace: WorkspaceInfo) async throws -> WorkspaceBridge {
        setStatus(.openingBridge)
        let bridgeSessionId = "bridge-" + UUID().uuidString.lowercased()
        let generation = synced(lock) { () -> Int in
            bridgeGenerationCounter += 1
            return bridgeGenerationCounter
        }

        var payload: [(String, IpcValue)] = [
            ("zcode_type", .string("workspace-bridge-open")),
            ("requestId", .string("workspace-bridge-" + UUID().uuidString.lowercased())),
            ("bridgeSessionId", .string(bridgeSessionId)),
            ("bridgeGeneration", .int(generation)),
            ("workspaceKey", .string(workspace.id)),
            ("terminalClientSessionId", .string(terminalClientSessionId)),
        ]
        _ = payload

        let ready = try await awaitReady(bridgeSessionId: bridgeSessionId, timeout: 10) { [relay] in
            relay.sendPayload(IpcValue.object(payload).jsonValueText)
        }
        if let error = ready["error"] as? String {
            throw RelayClientBridgeError.bridgeError(error)
        }

        let bridgeDict = ready["bridge"] as? [String: Any]
        let sid = ready["bridgeSessionId"] as? String ?? bridgeDict?["bridgeSessionId"] as? String ?? bridgeSessionId
        let gen = ready["bridgeGeneration"] as? Int ?? bridgeDict?["bridgeGeneration"] as? Int ?? generation
        let recovery = ready["recoveryId"] as? String ?? bridgeDict?["recoveryId"] as? String
        let identity = RpcFrameTransport.BridgeIdentity(bridgeSessionId: sid, bridgeGeneration: gen, recoveryId: recovery)

        let transport = RpcFrameTransport(identity: identity, chunkBytes: 512 * 1024)
        let channelClient = ChannelClient()
        let conversation = ConversationChannel(client: channelClient, clientId: v4ClientId, appVersion: appVersion)

        transport.onMessage = { [weak channelClient] data in
            channelClient?.handleData(data)
        }
        transport.onDegraded = { [weak self] reason in
            self?.logger("[bridge] degraded ws=\(workspace.workspacePath): \(reason)")
        }
        // 立即注册:200 Initialize 等 rpc-frame 在 ready 返回前就会到达
        synced(lock) { liveTransports[ObjectIdentifier(transport)] = transport }
        transport.sendPayload = { [weak self] text in
            self?.relay.sendPayload(text)
        }
        channelClient.attach { [weak transport] data in
            guard let transport else { throw ChannelClient.ChannelError.notReady }
            try transport.sendMessage(data)
        }

        do {
            try await channelClient.awaitReady(timeout: 30)
            try await conversation.handshake()
        } catch {
            synced(lock) { liveTransports[ObjectIdentifier(transport)] = nil }
            throw error
        }

        logger("[bridge] opened ws=\(workspace.workspacePath) gen=\(gen)")
        return WorkspaceBridge(workspace: workspace, identity: identity,
                               transport: transport, channelClient: channelClient,
                               conversation: conversation)
    }

    // MARK: 会话选择

    /// 选中会话:确保其工作区桥存在 → 挂监听 → 订阅 → 成为当前会话流
    public func selectSession(_ sessionId: String, workspace: WorkspaceInfo) async throws {
        let bridge = try await ensureBridge(for: workspace)
        try conversationStart(bridge: bridge, sessionId: sessionId)
        try await bridge.conversation.subscribe(
            sessionId: sessionId,
            workspacePath: bridge.workspace.workspacePath,
            workspaceIdentity: bridge.workspace.workspaceIdentity)
    }

    private func conversationStart(bridge: WorkspaceBridge, sessionId: String) throws {
        try bridge.conversation.startListening(workspacePath: bridge.workspace.workspacePath,
                                              workspaceIdentity: bridge.workspace.workspaceIdentity)
        synced(lock) {
            activeConversation = bridge.conversation
            activeConversationWorkspace = bridge.workspace
        }
    }

    /// 订阅(由调用方先 selectSession 确保桥)
    public func subscribeActive(sessionId: String) async throws {
        guard let bridge = activeBridge() else { throw RelayClientBridgeError.noWorkspace }
        try await bridge.conversation.subscribe(
            sessionId: sessionId,
            workspacePath: bridge.workspace.workspacePath,
            workspaceIdentity: bridge.workspace.workspaceIdentity)
    }

    /// 会话列表空窗自愈:重新订阅 controller topics
    public func retryController() {
        Task { [weak self] in
            guard let self, let bridge = self.primaryBridgeLocked() else { return }
            self.controller.rebind(client: bridge.channelClient)
            do { try self.controller.start() } catch {}
            try? await self.controller.subscribeTopics()
            self.logger("[bridge] controller retry issued")
        }
    }

    private func primaryBridgeLocked() -> WorkspaceBridge? {
        lock.lock(); defer { lock.unlock() }
        return primaryBridge
    }

    /// 服务类通道(zcode-session/usage-stats 等)使用的 client(当前会话所在桥优先)
    public func servicesClient() -> ChannelClient? {
        if let bridge = activeBridge() { return bridge.channelClient }
        lock.lock(); defer { lock.unlock() }
        return primaryBridge?.channelClient
    }

    private func activeBridge() -> WorkspaceBridge? {
        lock.lock(); defer { lock.unlock() }
        if let active = bridges.values.first(where: { $0.conversation === activeConversation }) {
            return active
        }
        return primaryBridge
    }

    // MARK: payload 路由

    private func handlePayload(_ payload: [String: Any]) {
        guard let zcodeType = payload["zcode_type"] as? String else { return }
        switch zcodeType {
        case "rpc-frame", "rpc-frame-ack":
            // 广播到所有活跃传输(身份不匹配的自动忽略;含建桥未完成的)
            lock.lock()
            let transports = Array(liveTransports.values)
            lock.unlock()
            for transport in transports {
                transport.acceptPayload(payload)
            }
        case "bridge-degraded":
            if let sid = payload["bridgeSessionId"] as? String,
               let bridge = findBridge(sessionId: sid) {
                bridge.transport.acceptPayload(payload)
            }
        case "bootstrap-response":
            resolvePayload("bootstrap-response", payload)
        case "workspace-bridge-ready", "workspace-bridge-error":
            if let sid = payload["bridgeSessionId"] as? String {
                resolveReady(bridgeSessionId: sid, payload: payload)
            }
        case "workspace-list-response", "workspace-list-updated":
            if let result = payload["result"] as? [String: Any],
               let list = result["workspaces"] as? [[String: Any]] {
                let workspaces = list.map(WorkspaceInfo.init)
                synced(lock) { status.workspaces = workspaces }
                setStatus(lockStatusPhase(), workspaces: workspaces)
            }
        case "mobile-task-view-request":
            break // 桌面端视图探测,忽略
        case "app-error":
            let reason = payload["reason"] as? String ?? "app-error"
            logger("[bridge] app-error: \(reason) \(payload["error"] ?? "")")
        default:
            logger("[bridge] unhandled zcode_type: \(zcodeType)")
        }
    }

    private func lockStatusPhase() -> Status.Phase {
        lock.lock(); defer { lock.unlock() }
        return status.phase
    }

    private func findBridge(sessionId: String) -> WorkspaceBridge? {
        lock.lock(); defer { lock.unlock() }
        if let primaryBridge, primaryBridge.identity.bridgeSessionId == sessionId { return primaryBridge }
        return bridges.values.first { $0.identity.bridgeSessionId == sessionId }
    }

    // MARK: payload 等待器(bootstrap 单飞 / ready 按 bridgeSessionId)

    private final class Waiter {
        let continuation: CheckedContinuation<[String: Any], Error>
        let timeoutItem: DispatchWorkItem
        init(_ c: CheckedContinuation<[String: Any], Error>, _ t: DispatchWorkItem) {
            continuation = c
            timeoutItem = t
        }
    }
    private var payloadWaiters: [String: Waiter] = [:]

    private func awaitPayload(_ key: String, timeout: TimeInterval,
                              start: @escaping () -> Void) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { cont in
            let item = DispatchWorkItem { [weak self] in
                self?.failPayload(key, error: RelayClientBridgeError.payloadTimeout(key))
            }
            let waiter = Waiter(cont, item)
            synced(lock) { payloadWaiters[key] = waiter }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
            start()
        }
    }

    private func resolvePayload(_ key: String, _ payload: [String: Any]) {
        let waiter = synced(lock) { payloadWaiters.removeValue(forKey: key) }
        guard let waiter else { return }
        waiter.timeoutItem.cancel()
        waiter.continuation.resume(returning: payload)
    }

    private func failPayload(_ key: String, error: Error) {
        let waiter = synced(lock) { payloadWaiters.removeValue(forKey: key) }
        guard let waiter else { return }
        waiter.timeoutItem.cancel()
        waiter.continuation.resume(throwing: error)
    }

    private func awaitReady(bridgeSessionId: String, timeout: TimeInterval,
                            start: @escaping () -> Void) async throws -> [String: Any] {
        try await awaitPayload("ready:" + bridgeSessionId, timeout: timeout, start: start)
    }

    private func resolveReady(bridgeSessionId sid: String, payload: [String: Any]) {
        resolvePayload("ready:" + sid, payload)
    }
}
