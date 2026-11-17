import Foundation

// MARK: - 任务/工作区模型(window-controller)

public struct TaskEntry: Identifiable, Equatable, Hashable {
    public let taskId: String
    public let workspacePath: String
    public let workspaceIdentity: String?
    public let title: String
    public let status: String          // liveStatus ?: meta.status
    public let updatedAt: Double
    public let pinned: Bool
    public let archived: Bool
    public var id: String { taskId }

    public init(taskId: String, workspacePath: String, workspaceIdentity: String?,
                title: String, status: String, updatedAt: Double, pinned: Bool, archived: Bool) {
        self.taskId = taskId
        self.workspacePath = workspacePath
        self.workspaceIdentity = workspaceIdentity
        self.title = title
        self.status = status
        self.updatedAt = updatedAt
        self.pinned = pinned
        self.archived = archived
    }

    init?(dict: [String: Any]) {
        guard let address = dict["address"] as? [String: Any],
              let taskId = address["taskId"] as? String,
              let workspacePath = address["workspacePath"] as? String else { return nil }
        self.taskId = taskId
        self.workspacePath = workspacePath
        self.workspaceIdentity = address["workspaceIdentity"] as? String
        let meta = dict["meta"] as? [String: Any]
        self.title = meta?["title"] as? String ?? taskId
        self.updatedAt = meta?["updatedAt"] as? Double ?? 0
        let membership = dict["membership"] as? [String: Any]
        self.pinned = membership?["pinned"] as? Bool ?? false
        self.archived = membership?["archived"] as? Bool ?? false
        self.status = dict["liveStatus"] as? String ?? meta?["status"] as? String ?? "unknown"
    }
}

public struct WorkspaceEntry: Identifiable, Equatable {
    public let workspacePath: String
    public let workspaceIdentity: String?
    public let connectionState: String
    public let sourceAvailability: String
    public var id: String { workspaceIdentity ?? workspacePath }

    public init(workspacePath: String, workspaceIdentity: String?, connectionState: String, sourceAvailability: String) {
        self.workspacePath = workspacePath
        self.workspaceIdentity = workspaceIdentity
        self.connectionState = connectionState
        self.sourceAvailability = sourceAvailability
    }

    init?(dict: [String: Any]) {
        guard let path = dict["workspacePath"] as? String else { return nil }
        self.workspacePath = path
        self.workspaceIdentity = dict["workspaceIdentity"] as? String
        self.connectionState = dict["connectionState"] as? String ?? "unknown"
        self.sourceAvailability = dict["sourceAvailability"] as? String ?? "unknown"
    }
}

// MARK: - Controller 通道(tasks-index + workspaces 两个 topic,裸帧无 wire 信封)

public final class ControllerChannel: @unchecked Sendable {

    public static let tasksTopic = "controller/tasks-index"
    public static let workspacesTopic = "controller/workspaces"

    private var client: ChannelClient
    private let logger: (String) -> Void
    private let lock = NSLock()
    private var listenerId: Int?
    private var subscriptionIds: [String: String] = [:]    // topic → sub id
    private var watermarks: [String: (logEpoch: String, toSeq: Int)] = [:]

    public private(set) var tasks: [TaskEntry] = []
    public private(set) var workspaces: [WorkspaceEntry] = []
    public var onUpdated: (() -> Void)?

    public init(client: ChannelClient, onLog: ((String) -> Void)? = nil) {
        self.client = client
        self.logger = onLog ?? { _ in }
    }

    /// 主桥建立后回填真实的 ChannelClient
    func rebind(client: ChannelClient) {
        self.client = client
    }

    /// Controller 订阅序列:先握手(调用方负责)→ 102 listen(arg=null)→ 两 topic 各 subscribe
    public func start() throws {
        let id = try client.listen(ChannelClient.channelWindowController, event: "onDynamicControllerFrame", arg: .undefined) { [weak self] value in
            self?.handleEvent(value)
        }
        lock.lock()
        listenerId = id
        lock.unlock()
    }

    public func subscribeTopics() async throws {
        for topic in [Self.tasksTopic, Self.workspacesTopic] {
            let result = try await client.call(
                ChannelClient.channelWindowController, "subscribeControllerV4",
                args: [.object([("topic", .string(topic)), ("visibility", .string("foreground"))])],
                timeout: 30)
            var subId: String?
            if case .json(let text) = result,
               let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                subId = (obj["ack"] as? [String: Any])?["subscriptionId"] as? String ?? obj["subscriptionId"] as? String
            }
            if let subId {
                synced(lock) { subscriptionIds[topic] = subId }
            }
        }
    }

    func handleEvent(_ value: IpcValue) {
        guard case .json(let text) = value,
              let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
        // 裸帧优先;容忍 wire 信封形态
        var frameDict = obj
        if obj["wireVersion"] != nil, let inner = (obj["frame"] as? [String: Any]) {
            frameDict = inner
        }
        guard let frame = TopicFrame(dict: frameDict) else { return }
        applyFrame(frame)
        onUpdated?()
    }

    private func applyFrame(_ frame: TopicFrame) {
        lock.lock()
        defer { lock.unlock() }
        switch frame.payloadKind {
        case "snapshot":
            // 快照不判失同步,但照常刷新水位
            if let epoch = frame.snapshot?["logEpoch"] as? String {
                watermarks[frame.topic] = (epoch, frame.toSeq)
            }
            if frame.topic == Self.tasksTopic {
                let list = (frame.snapshot?["tasks"] as? [[String: Any]] ?? []).compactMap(TaskEntry.init)
                tasks = Self.sortedTasks(list)
            } else if frame.topic == Self.workspacesTopic {
                workspaces = (frame.snapshot?["workspaces"] as? [[String: Any]] ?? []).compactMap(WorkspaceEntry.init)
            }
        case "deltas":
            // 失同步判定:fromSeq != 上次 toSeq 或 logEpoch 变化 → resync
            if let mark = watermarks[frame.topic] {
                if frame.fromSeq != mark.toSeq {
                    scheduleResync(topic: frame.topic)
                    return
                }
            } else {
                return // 尚无快照,忽略增量
            }
            for delta in frame.deltas {
                guard let op = delta["op"] as? String else { continue }
                if frame.topic == Self.tasksTopic {
                    switch op {
                    case "task.upserted":
                        if let task = (delta["task"] as? [String: Any]).flatMap(TaskEntry.init) {
                            tasks.removeAll { $0.taskId == task.taskId }
                            tasks.append(task)
                            tasks = Self.sortedTasks(tasks)
                        }
                    case "task.removed":
                        if let address = delta["address"] as? [String: Any],
                           let taskId = address["taskId"] as? String {
                            tasks.removeAll { $0.taskId == taskId }
                        }
                    default: break
                    }
                } else if frame.topic == Self.workspacesTopic {
                    switch op {
                    case "workspace.upserted":
                        if let ws = (delta["workspace"] as? [String: Any]).flatMap(WorkspaceEntry.init) {
                            workspaces.removeAll { $0.id == ws.id }
                            workspaces.append(ws)
                        }
                    case "workspace.removed":
                        if let path = delta["workspacePath"] as? String {
                            workspaces.removeAll { $0.workspacePath == path }
                        }
                    default: break
                    }
                }
            }
            if var mark = watermarks[frame.topic] {
                mark.toSeq = frame.toSeq
                watermarks[frame.topic] = mark
            }
        default:
            break
        }
    }

    private func scheduleResync(topic: String) {
        logger("[controller] desync on \(topic), resyncing")
        Task { [weak self] in
            guard let self else { return }
            let pair = synced(self.lock) { (self.subscriptionIds[topic], self.watermarks[topic]) }
            let subId = pair.0
            let mark = pair.1
            guard let subId, let mark else { return }
            var body: [(String, IpcValue)] = [
                ("subscriptionId", .string(subId)),
                ("forceSnapshot", .bool(true)),
            ]
            if let epoch = mark.logEpoch as String? {
                body.append(("base", .object([("logEpoch", .string(epoch)), ("seq", .int(mark.toSeq))])))
            }
            _ = try? await self.client.call(
                ChannelClient.channelWindowController, "resyncControllerV4",
                args: [.object(body)], timeout: 30)
        }
    }

    static func sortedTasks(_ list: [TaskEntry]) -> [TaskEntry] {
        list.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
            return a.taskId < b.taskId
        }
    }

    /// 可见任务:过滤归档
    public var visibleTasks: [TaskEntry] {
        lock.lock(); defer { lock.unlock() }
        return tasks.filter { !$0.archived }
    }
}
