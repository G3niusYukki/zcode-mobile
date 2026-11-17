import Foundation

// MARK: - WS 抽象(可注入测试替身)

public protocol WSConnection: AnyObject {
    var onOpen: (() -> Void)? { get set }
    var onText: ((String) -> Void)? { get set }
    var onClose: ((Int, String?) -> Void)? { get set }
    func sendText(_ text: String)
    func ping()
    func resumeIfNeeded()
    func close()
}

public protocol WSFactory: Sendable {
    func make(url: URL, headers: [String: String]) -> WSConnection
}

// MARK: - RelayClient

/// V2 中继客户端状态机。
/// 守则(规格 §7.4,每条都有真机教训背书):
/// 1. 连接代次守卫:旧 socket 迟到回调一律丢弃
/// 2. 终态即关 socket(存活 WS 会收到 matched 静默绕过终态)
/// 3. 心跳 5s±1s 每轮重抽;15s 单向失活(「发了但没回」才判)
/// 4. 重连调度防重入
/// 5. DEVICE_OFFLINE 15s 有界宽限,重连不重置起点;宽限内不启心跳
/// 6. KICKED 首次 2~5s 自愈,60s 窗口二次终态
/// 7. token 401/403 → authFailed 终态,不当网络错误无限重连
public final class RelayClient: @unchecked Sendable {

    public enum FailureReason: String, Equatable, Sendable {
        case kicked, authFailed, protocolMismatch, invalidEndpoint, desktopDisconnected
        case network, internal_, relayUnavailable

        public var isTerminal: Bool {
            switch self {
            case .kicked, .authFailed, .protocolMismatch, .invalidEndpoint, .desktopDisconnected, .relayUnavailable:
                return true
            default: return false
            }
        }
    }

    public enum State: Equatable, Sendable {
        case idle
        case connecting
        case authenticating
        case waitingPeer
        case paired
        case failed(FailureReason, String?)
    }

    public struct Config: Sendable {
        public var heartbeatInterval: TimeInterval = 5
        public var heartbeatJitter: TimeInterval = 1
        public var ackTimeout: TimeInterval = 15
        public var deviceOfflineGrace: TimeInterval = 15
        public var outboundQueueLimit = 50
        public var allowInsecureWS = false
        public var meta = RelayProtocol.TerminalMeta(platform: "ios", version: "0.1.0", name: "ZCodeMobile")
        public init() {}
    }

    // 事件
    public var onStateChange: ((State) -> Void)?
    /// 配对成功(每次 matched 都回调;重连恢复也走这里)
    public var onPaired: (() -> Void)?
    /// data.payload(业务帧,zcode_type 路由在调用方)
    public var onPayload: (([String: Any]) -> Void)?
    public var onLog: ((String) -> Void)?

    // 依赖注入
    public struct Dependencies {
        public var tokenFetcher: @Sendable () async throws -> String
        public var wsFactory: WSFactory
        public var scheduler: @Sendable (@Sendable @escaping () -> Void, TimeInterval) -> Cancellable
        public var now: @Sendable () -> Date
        public var random: @Sendable () -> Double
        public init(
            tokenFetcher: @escaping @Sendable () async throws -> String,
            wsFactory: WSFactory,
            scheduler: @escaping @Sendable (@Sendable @escaping () -> Void, TimeInterval) -> Cancellable = { work, delay in
                let workItem = DispatchWorkItem(block: work)
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) { workItem.perform() }
                return DispatchWorkItemCancellable(item: workItem)
            },
            now: @escaping @Sendable () -> Date = { Date() },
            random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }
        ) {
            self.tokenFetcher = tokenFetcher
            self.wsFactory = wsFactory
            self.scheduler = scheduler
            self.now = now
            self.random = random
        }
    }

    public let device: PairedDevice
    public let config: Config
    private let deps: Dependencies

    private let lock = NSLock()
    private var _state: State = .idle
    private var generation = 0
    private var ws: WSConnection?
    private var retryPolicy: RetryPolicy
    private var hadPaired = false
    private var reconnectScheduled = false
    private var heartbeatTimer: Cancellable?
    private var watchdogTimer: Cancellable?
    private var unackedHeartbeatAt: Date?
    private var offlineGraceStartedAt: Date?
    private var outboundQueue: [String] = []
    private var stopped = false

    public init(device: PairedDevice, config: Config = Config(), deps: Dependencies) {
        self.device = device
        self.config = config
        self.deps = deps
        self.retryPolicy = RetryPolicy(random: deps.random, nowMs: { deps.now().timeIntervalSince1970 * 1000 })
    }

    public var state: State {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    private func setState(_ new: State) {
        lock.lock()
        guard !isTerminal(_state) || !isTerminal(new) else { lock.unlock(); return } // 终态不可逆
        _state = new
        lock.unlock()
        onStateChange?(new)
        if case .paired = new { onPaired?() }
    }

    private func isTerminal(_ s: State) -> Bool {
        if case .failed(let reason, _) = s { return reason.isTerminal }
        return false
    }

    // MARK: - 生命周期

    /// 建立连接。用户/网络恢复路径 resetRetryPolicy=true;内部重连调度 false。
    public func start(resetRetryPolicy: Bool = true) {
        lock.lock()
        stopped = false
        if isTerminal(_state) { lock.unlock(); return }
        if resetRetryPolicy { retryPolicy.reset() }
        let alreadyConnecting: Bool
        switch _state {
        case .connecting, .authenticating, .waitingPeer, .paired: alreadyConnecting = true
        default: alreadyConnecting = false
        }
        lock.unlock()
        guard !alreadyConnecting else { return }
        connect()
    }

    public func stop(reason: String) {
        lock.lock()
        stopped = true
        generation += 1 // 使一切在途回调失效
        let socket = ws
        ws = nil
        heartbeatTimer?.cancel(); heartbeatTimer = nil
        watchdogTimer?.cancel(); watchdogTimer = nil
        reconnectScheduled = false
        outboundQueue.removeAll()
        _state = .idle
        lock.unlock()
        socket?.close()
        log("stopped: \(reason)")
        onStateChange?(.idle)
    }

    // MARK: - 出站

    /// 发业务 payload(JSON 文本,会被包进 data 信封)。未配对时入队(50 条,溢出整批丢弃)。
    @discardableResult
    public func sendPayload(_ payloadJSON: String) -> Bool {
        let envelope = RelayProtocol.dataEnvelope(payloadJSON: payloadJSON, now: deps.now())
        lock.lock()
        let socket = ws
        let ready: Bool
        if case .paired = _state { ready = true } else { ready = false }
        if !ready {
            outboundQueue.append(envelope)
            if outboundQueue.count > config.outboundQueueLimit {
                outboundQueue.removeAll() // 官方口径:整批丢弃,重连不回放
                log("outbound queue overflow, dropped all")
            }
        }
        lock.unlock()
        guard ready, let socket else { return false }
        socket.sendText(envelope)
        return true
    }

    // MARK: - 连接

    private func connect() {
        lock.lock()
        generation += 1
        let myGeneration = generation
        let terminal = isTerminal(_state)
        let stoppedNow = stopped
        lock.unlock()
        guard !terminal, !stoppedNow else { return }

        setState(.connecting)
        log("connecting (gen \(myGeneration))")

        Task { [weak self] in
            guard let self else { return }
            do {
                let token = try await self.deps.tokenFetcher() // token 不落日志
                self.openSocket(token: token, generation: myGeneration)
            } catch {
                self.handleTokenError(error, generation: myGeneration)
            }
        }
    }

    private func handleTokenError(_ error: Error, generation gen: Int) {
        guard gen == currentGeneration() else { return }
        if case V2AccountApi.ApiError.authFailed(let msg) = error {
            setState(.failed(.authFailed, msg))
            closeSocket()
            return
        }
        log("token fetch failed: \(error.localizedDescription)")
        scheduleReconnect()
    }

    private func openSocket(token: String, generation gen: Int) {
        guard gen == currentGeneration() else { return }
        let mid = device.deviceMid ?? "zcode-mobile-terminal"
        guard let url = RelayProtocol.v2RelayWsUrl(origin: device.origin, token: token, mid: mid),
              RelayProtocol.validateEndpoint(url, allowInsecureWS: config.allowInsecureWS) else {
            setState(.failed(.invalidEndpoint, nil))
            return
        }

        let headers = ["Origin": RelayProtocol.originHeader(forWsUrl: url)]
        let socket = deps.wsFactory.make(url: url, headers: headers)
        socket.onOpen = { [weak self, gen] in self?.handleOpen(generation: gen) }
        socket.onText = { [weak self, gen] text in self?.handleText(text, generation: gen) }
        socket.onClose = { [weak self, gen] code, reason in self?.handleClose(code: code, reason: reason, generation: gen) }

        lock.lock()
        ws = socket
        lock.unlock()
        socket.resumeIfNeeded()
    }

    private func handleOpen(generation gen: Int) {
        guard gen == currentGeneration() else { return }
        setState(.authenticating)
        let initFrame = RelayProtocol.authInit(deviceSid: device.deviceSid, meta: config.meta, now: deps.now())
        lock.lock(); let socket = ws; lock.unlock()
        socket?.sendText(initFrame)
        scheduleHeartbeat()
        scheduleWatchdog()
    }

    private func handleText(_ text: String, generation gen: Int) {
        guard gen == currentGeneration() else { return }
        // 任何入站帧都证明链路双向可用 → 清失活计时
        lock.lock(); unackedHeartbeatAt = nil; lock.unlock()

        switch RelayInbound.parse(text) {
        case .authAck(_, _, let pairStatus, _):
            switch pairStatus {
            case "matched":
                lock.lock()
                hadPaired = true
                offlineGraceStartedAt = nil
                retryPolicy.acknowledged()
                let queued = outboundQueue
                outboundQueue.removeAll()
                let socket = ws
                lock.unlock()
                setState(.paired)
                for envelope in queued { socket?.sendText(envelope) }
            case "waiting":
                setState(.waitingPeer)
            default:
                setState(.failed(.protocolMismatch, "unknown pair_status: \(pairStatus ?? "nil")"))
                closeSocket()
            }

        case .pairStatusAck(let pairStatus):
            if pairStatus == "matched" {
                lock.lock()
                if case .waitingPeer = _state { hadPaired = hadPaired || false }
                let wasWaiting: Bool
                if case .waitingPeer = _state { wasWaiting = true } else { wasWaiting = false }
                lock.unlock()
                if wasWaiting { setState(.paired) }
            } else if pairStatus == "waiting" {
                lock.lock(); let wasPaired: Bool
                if case .paired = _state { wasPaired = true } else { wasPaired = false }
                lock.unlock()
                if wasPaired { setState(.waitingPeer) }
            }

        case .data(let payload):
            onPayload?(payload)

        case .challenge:
            setState(.failed(.protocolMismatch, "auth_challenge on ws2"))
            closeSocket()

        case .error(let code, let message):
            handleError(code: code, message: message, generation: gen)

        case .unknown(let type):
            log("unknown relay frame type: \(type ?? "nil")")
        }
    }

    private func handleError(code: String, message: String?, generation gen: Int) {
        guard gen == currentGeneration() else { return }
        log("relay error: \(code) \(message ?? "")")
        switch code {
        case "KICKED":
            if let delay = retryPolicyKicked() {
                setState(.connecting) // 占位;调度重连
                scheduleReconnect(delayMs: delay)
            } else {
                setState(.failed(.kicked, message))
            }
            closeSocket()
        case "AUTH_FAILED", "WRONG_PARAM":
            setState(.failed(.authFailed, message ?? code))
            closeSocket()
        case "DEVICE_OFFLINE":
            lock.lock()
            let graceStart: Date?
            if offlineGraceStartedAt == nil { offlineGraceStartedAt = deps.now() }
            graceStart = offlineGraceStartedAt
            lock.unlock()
            setState(.waitingPeer)
            scheduleOfflineGraceCheck(startedAt: graceStart)
            scheduleReconnect()
        case "INTERNAL":
            lock.lock()
            let resumeWaiting = hadPaired || {
                if case .waitingPeer = _state { return true }
                return false
            }()
            lock.unlock()
            if resumeWaiting {
                setState(.waitingPeer)
            } else {
                scheduleReconnect(delayMs: 0) // 立即,不退避
            }
        default:
            setState(.failed(.relayUnavailable, "\(code) \(message ?? "")"))
            closeSocket()
        }
    }

    private func handleClose(code: Int, reason: String?, generation gen: Int) {
        guard gen == currentGeneration() else { return }
        log("ws closed: \(code) \(reason ?? "")")
        lock.lock()
        let terminal = isTerminal(_state)
        let stoppedNow = stopped
        ws = nil
        heartbeatTimer?.cancel(); heartbeatTimer = nil
        lock.unlock()
        guard !terminal, !stoppedNow else { return }
        scheduleReconnect()
    }

    // MARK: - 心跳与看门狗

    private func scheduleHeartbeat() {
        lock.lock()
        heartbeatTimer?.cancel()
        let inGrace = offlineGraceStartedAt != nil // 宽限内不启心跳(ack 永远不来)
        lock.unlock()
        guard !inGrace else { return }

        let base = config.heartbeatInterval
        let jitter = config.heartbeatJitter
        let delay = base - jitter + deps.random() * jitter * 2 // [base-j, base+j] 每轮重抽
        heartbeatTimer = deps.scheduler({ [weak self] in
            guard let self else { return }
            self.lock.lock()
            let active: Bool
            switch self._state {
            case .paired, .waitingPeer, .authenticating: active = true
            default: active = false
            }
            let socket = self.ws
            if self.unackedHeartbeatAt == nil { self.unackedHeartbeatAt = self.deps.now() }
            let unackedAt = self.unackedHeartbeatAt
            self.lock.unlock()
            guard active, let socket else { return }

            socket.sendText(RelayProtocol.heartbeat(now: self.deps.now()))
            socket.ping()
            _ = unackedAt
            self.scheduleHeartbeat() // 链路仍活 → 续排下一轮
        }, delay)
    }

    /// DEVICE_OFFLINE 15s 有界宽限:超时且仍 WaitingPeer ⇒ desktopDisconnected 终态。
    /// matched 取消并清零(此检查发现 offlineGraceStartedAt 已变化/清空则不动作)。
    private func scheduleOfflineGraceCheck(startedAt: Date?) {
        guard let startedAt else { return }
        _ = deps.scheduler({ [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stillInGrace = self.offlineGraceStartedAt == startedAt
            let waiting: Bool
            if case .waitingPeer = self._state { waiting = true } else { waiting = false }
            self.lock.unlock()
            if stillInGrace, waiting {
                self.setState(.failed(.desktopDisconnected, "device offline grace exceeded"))
                self.closeSocket()
            }
        }, config.deviceOfflineGrace)
    }

    private func scheduleWatchdog() {
        lock.lock()
        watchdogTimer?.cancel()
        lock.unlock()
        watchdogTimer = deps.scheduler({ [weak self] in
            guard let self else { return }
            self.lock.lock()
            let unacked = self.unackedHeartbeatAt.map { self.deps.now().timeIntervalSince($0) }
            self.watchdogTimer = nil
            var watching = true
            switch self._state {
            case .paired, .waitingPeer, .authenticating: watching = true
            default: watching = false
            }
            let live: Bool
            if case .paired = self._state { live = true }
            else if case .waitingPeer = self._state { live = true }
            else { live = false }
            self.lock.unlock()
            guard watching else { return } // 连接结束(终态/idle/重连中),停止看门狗
            if let elapsed = unacked, live, elapsed >= self.config.ackTimeout {
                self.log("heartbeat watchdog fired (\(Int(elapsed))s without ack)")
                self.failNetworkAndReconnect()
            } else {
                self.scheduleWatchdog() // 继续看
            }
        }, config.ackTimeout)
    }

    private func failNetworkAndReconnect() {
        setState(.failed(.network, "heartbeat timeout")) // 非终态,可恢复
        closeSocket()
        scheduleReconnect()
    }

    // MARK: - 重连调度

    private func scheduleReconnect(delayMs: Double? = nil) {
        lock.lock()
        guard !reconnectScheduled, !stopped, !isTerminal(_state) else { lock.unlock(); return }
        reconnectScheduled = true
        let delay: Double
        if let delayMs { delay = delayMs / 1000 }
        else { delay = retryPolicy.nextDelay() / 1000 }
        lock.unlock()
        log("reconnect in \(Int(delay * 1000))ms")
        _ = deps.scheduler({ [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.reconnectScheduled = false
            let hasLiveSocket = self.ws != nil
            self.lock.unlock()
            // socket 仍存活(如 DEVICE_OFFLINE 后原连接恢复)则跳过这次重连
            guard !hasLiveSocket else { return }
            self.connect()
        }, max(delay, 0.01))
    }

    private func retryPolicyKicked() -> Double? {
        lock.lock(); defer { lock.unlock() }
        return retryPolicy.kickedDelay()
    }

    // MARK: - 网络钩子(由 NWPathMonitor 驱动)

    public func handleNetworkLost() {
        log("network lost")
        lock.lock()
        retryPolicy.reset()
        let terminal = isTerminal(_state)
        let stoppedNow = stopped
        lock.unlock()
        guard !terminal, !stoppedNow else { return }
        closeSocket()
        setState(.idle)
        scheduleReconnect(delayMs: 250)
    }

    public func handleNetworkRestored() {
        log("network restored")
        lock.lock()
        retryPolicy.reset()
        let shouldConnect: Bool
        switch _state {
        case .idle, .failed(.network, _): shouldConnect = true
        case .connecting, .authenticating: shouldConnect = false // 残留态,交给在途流程
        default: shouldConnect = false
        }
        lock.unlock()
        if shouldConnect { connect() }
    }

    // MARK: - 杂项

    private func currentGeneration() -> Int {
        lock.lock(); defer { lock.unlock() }
        return generation
    }

    private func closeSocket() {
        lock.lock()
        generation += 1 // 迟到回调全部失效
        let socket = ws
        ws = nil
        heartbeatTimer?.cancel(); heartbeatTimer = nil
        lock.unlock()
        socket?.close()
    }

    private func log(_ message: String) {
        onLog?("[relay] \(message)")
    }
}

// MARK: - 生产 WS 实现

public final class URLSessionWSFactory: WSFactory {
    public init() {}
    public func make(url: URL, headers: [String: String]) -> WSConnection {
        var request = URLRequest(url: url, timeoutInterval: 15)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let task = URLSession.shared.webSocketTask(with: request)
        return URLSessionWSConnection(task: task)
    }
}

final class URLSessionWSConnection: NSObject, WSConnection, URLSessionWebSocketDelegate {
    var onOpen: (() -> Void)?
    var onText: ((String) -> Void)?
    var onClose: ((Int, String?) -> Void)?

    private let task: URLSessionWebSocketTask
    private let delegateBox = DelegateBox()
    private var closed = false

    init(task: URLSessionWebSocketTask) {
        self.task = task
        super.init()
        delegateBox.forwarder = self
        task.delegate = delegateBox
    }

    func resumeIfNeeded() {
        receiveLoop()
        task.resume()
    }

    private func receiveLoop() {
        task.receive { [weak self] completion in
            guard let self else { return }
            switch completion {
            case .success(let message):
                if case .string(let text) = message { self.onText?(text) }
                self.receiveLoop()
            case .failure(let error):
                let code = (error as NSError).code
                self.onClose?(code, error.localizedDescription)
            }
        }
    }

    func sendText(_ text: String) {
        task.send(.string(text)) { [weak self] error in
            if let error { self?.onClose?((error as NSError).code, error.localizedDescription) }
        }
    }

    func ping() {
        task.sendPing { _ in }
    }

    func close() {
        guard !closed else { return }
        closed = true
        task.cancel(with: .goingAway, reason: nil)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        onOpen?()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        onClose?(Int(closeCode.rawValue), String(data: reason ?? Data(), encoding: .utf8))
    }

    // delegate 必须长存(URLSession 弱持有),用盒子转发避免循环引用
    final class DelegateBox: NSObject, URLSessionWebSocketDelegate {
        weak var forwarder: URLSessionWSConnection?

        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
            forwarder?.urlSession(session, webSocketTask: webSocketTask, didOpenWithProtocol: `protocol`)
        }

        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
            forwarder?.urlSession(session, webSocketTask: webSocketTask, didCloseWith: closeCode, reason: reason)
        }
    }
}

// MARK: - 调度抽象

public protocol Cancellable {
    func cancel()
}

public struct DispatchWorkItemCancellable: Cancellable {
    let item: DispatchWorkItem
    public init(item: DispatchWorkItem) { self.item = item }
    public func cancel() { item.cancel() }
}

/// 测试用手动调度器:记录任务,由测试显式推进
public final class ManualScheduler: @unchecked Sendable {
    public private(set) var tasks: [(id: UUID, at: Double, work: @Sendable () -> Void, cancelled: Bool)] = []
    private let lock = NSLock()
    public var virtualNow: Double = 0

    public init() {}

    public func schedule(_ work: @Sendable @escaping () -> Void, _ delay: TimeInterval) -> Cancellable {
        lock.lock(); defer { lock.unlock() }
        let id = UUID()
        tasks.append((id, virtualNow + delay, work, false))
        return TaskCancellable(scheduler: self, id: id)
    }

    /// 推进虚拟时间并执行到期任务
    public func advance(by seconds: Double) {
        lock.lock()
        virtualNow += seconds
        let due = tasks.filter { !$0.cancelled && $0.at <= virtualNow }
        tasks.removeAll { !$0.cancelled && $0.at <= virtualNow }
        lock.unlock()
        for task in due { task.work() }
    }

    public func runAll() {
        lock.lock()
        let all = tasks.filter { !$0.cancelled }
        tasks.removeAll { !$0.cancelled }
        lock.unlock()
        for task in all { task.work() }
    }

    private func cancel(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        if let idx = tasks.firstIndex(where: { $0.id == id }) { tasks[idx].cancelled = true }
    }

    struct TaskCancellable: Cancellable {
        let scheduler: ManualScheduler
        let id: UUID
        func cancel() { scheduler.cancel(id: id) }
    }
}
