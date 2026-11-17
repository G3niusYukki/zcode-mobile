import Foundation

// MARK: - 行模型

public struct ConversationRow: Identifiable {
    public let rowId: Int
    public let kind: String          // userInput|assistantText|reasoning|toolCall|turnHeader|subagent|…
    public var text: String
    public var state: String?        // complete|streaming|interrupted(toolCall: inputStreaming|running|success|error…)
    public var toolName: String?
    public var toolCallId: String?
    public var inputText: String?
    public var outputText: String?
    public var origin: String?
    public var createdAt: Double?
    public var visibility: String
    public var raw: [String: Any]

    public var id: Int { rowId }

    public init?(dict: [String: Any]) {
        guard let rowId = dict["rowId"] as? Int, let kind = dict["kind"] as? String else { return nil }
        self.rowId = rowId
        self.kind = kind
        self.text = dict["text"] as? String ?? ""
        self.state = dict["state"] as? String ?? dict["status"] as? String
        self.toolName = dict["toolName"] as? String
        self.toolCallId = dict["toolCallId"] as? String
        self.inputText = dict["inputText"] as? String
        self.outputText = (dict["output"] as? [String: Any])?["text"] as? String
        self.origin = dict["origin"] as? String
        self.createdAt = dict["createdAt"] as? Double
        self.visibility = dict["visibility"] as? String ?? "visible"
        self.raw = dict
    }
}

// MARK: - 待处理交互(权限/提问/表单)

public struct InteractionOption: Equatable {
    public let optionId: String
    public let label: String
    public let kind: String
    public init(optionId: String, label: String, kind: String) {
        self.optionId = optionId
        self.label = label
        self.kind = kind
    }
}

public struct PendingInteraction: Identifiable {
    public let interactionId: String
    public let kind: String                 // permission|userInput|workspaceHookReview
    public let toolName: String?
    public let summary: String?
    public let detailText: String?
    public let prompt: String?
    public let options: [InteractionOption]
    public let anchorRowId: Int?
    public let questions: [[String: Any]]
    public var id: String { interactionId }

    public init?(dict: [String: Any]) {
        guard let interactionId = dict["interactionId"] as? String else { return nil }
        self.interactionId = interactionId
        self.kind = dict["kind"] as? String ?? "permission"
        let payload = dict["payload"] as? [String: Any] ?? [:]
        self.toolName = payload["toolName"] as? String
        self.summary = payload["summary"] as? String
        if let detail = payload["detail"] as? [String: Any] {
            if let command = detail["command"] as? String {
                self.detailText = command
            } else if let data = try? JSONSerialization.data(withJSONObject: detail),
                      let text = String(data: data, encoding: .utf8) {
                self.detailText = String(text.prefix(2000))
            } else {
                self.detailText = nil
            }
        } else {
            self.detailText = nil
        }
        self.prompt = payload["prompt"] as? String ?? payload["message"] as? String
        self.options = (payload["options"] as? [[String: Any]] ?? []).compactMap { o in
            guard let optionId = o["optionId"] as? String else { return nil }
            return InteractionOption(
                optionId: optionId,
                label: o["label"] as? String ?? o["name"] as? String ?? o["value"] as? String ?? optionId,
                kind: o["kind"] as? String ?? "custom")
        }
        self.anchorRowId = dict["anchorRowId"] as? Int
        self.questions = payload["questions"] as? [[String: Any]] ?? []
    }
}

// MARK: - 会话状态归约器(snapshot + deltas → 本地状态)

public final class ConversationState: @unchecked Sendable {

    public struct Control: Equatable, Sendable {
        public var phase: String
        public var canStop: Bool
        public var stopState: String
        public static let idle = Control(phase: "idle", canStop: false, stopState: "idle")
    }

    private let lock = NSLock()
    // 快照顶层(保留 raw 供调试与扩展字段)
    public private(set) var snapshotRaw: [String: Any] = [:]
    public private(set) var sessionId: String?
    public private(set) var logEpoch: String?
    public private(set) var seq: Int = 0
    public private(set) var revision: Int = 0
    public private(set) var title: String?
    public private(set) var control = Control.idle
    public private(set) var pendingInteractions: [PendingInteraction] = []
    public private(set) var subscriptionId: String?
    // 快照落地前到达的 state.updated patch 缓冲
    private var pendingPatch: [[String: Any]] = []

    // 行集合(按 rowId 有序)
    public private(set) var rows: [ConversationRow] = []
    private var rowMap: [Int: ConversationRow] = [:]
    public private(set) var firstRowId: Int?
    public private(set) var totalCount: Int = 0
    public private(set) var hasMoreOlder: Bool = false

    // 变更通知(每次状态演进后触发;UI 监听)
    public var onUpdated: (() -> Void)?
    public var onResyncNeeded: (() -> Void)?

    public init() {}

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return control.phase == "running" || control.phase == "prewarming"
    }

    /// 应用 topic 帧(内部已由 reassembler 产出)
    public func apply(frame: TopicFrame) {
        lock.lock()
        // subscriptionId 关联(帧必须同时匹配 topic + subscriptionId)
        if let sid = frame.subscriptionId {
            if let current = subscriptionId, current != sid, frame.payloadKind == "deltas" {
                lock.unlock()
                return // 旧订阅迟到帧,丢弃
            }
            subscriptionId = sid
        }
        lock.unlock()

        switch frame.payloadKind {
        case "snapshot":
            applySnapshot(frame)
        case "deltas":
            applyDeltas(frame)
        default:
            break
        }
        onUpdated?()
    }

    private func applySnapshot(_ frame: TopicFrame) {
        guard let snapshot = frame.snapshot else { return }
        lock.lock()
        snapshotRaw = snapshot
        sessionId = snapshot["sessionId"] as? String
        logEpoch = snapshot["logEpoch"] as? String
        seq = frame.toSeq
        revision = snapshot["revision"] as? Int ?? revision
        title = (snapshot["meta"] as? [String: Any])?["title"] as? String

        if let controlDict = snapshot["control"] as? [String: Any] {
            control = Control(
                phase: controlDict["phase"] as? String ?? "idle",
                canStop: controlDict["canStop"] as? Bool ?? false,
                stopState: controlDict["stopState"] as? String ?? "idle")
        }
        pendingInteractions = (snapshot["pendingInteractions"] as? [[String: Any]] ?? []).compactMap(PendingInteraction.init)

        if let rowsDict = snapshot["rows"] as? [String: Any] {
            let window = (rowsDict["window"] as? [[String: Any]] ?? []).compactMap(ConversationRow.init)
            // 快照 = window 全量替换,但保留已翻页加载的更早行(rowId < window 首行)
            let windowFirst = window.first?.rowId ?? Int.max
            let olderLocal = rows.filter { $0.rowId < windowFirst }
            rowMap = Dictionary(uniqueKeysWithValues: (olderLocal + window).map { ($0.rowId, $0) })
            rows = (olderLocal + window).sorted { $0.rowId < $1.rowId }
            firstRowId = rowsDict["firstRowId"] as? Int
            totalCount = rowsDict["totalCount"] as? Int ?? rows.count
            hasMoreOlder = rows.first?.rowId != firstRowId
        }

        // 快照落地:合并先到的 patch
        let patches = pendingPatch
        pendingPatch.removeAll()
        lock.unlock()
        for patch in patches { applyStatePatch(patch, notify: false) }
    }

    private func applyDeltas(_ frame: TopicFrame) {
        lock.lock()
        // seq 连续性是接受增量的前提;断层 → 丢弃并请求 resync
        let expected = seq
        if frame.fromSeq != expected {
            lock.unlock()
            onResyncNeeded?()
            return
        }
        // 快照未落地时:行操作跳过(等快照),state.updated patch 照常处理(applyStatePatch 内部缓冲)
        let snapshotLanded = sessionId != nil
        lock.unlock()

        for delta in frame.deltas {
            guard let op = delta["op"] as? String else { continue }
            switch op {
            case "row.appended", "row.upserted":
                if snapshotLanded,
                   let rowDict = delta["row"] as? [String: Any], let row = ConversationRow(dict: rowDict) {
                    upsertRow(row)
                }
            case "row.removed":
                if let fromRowId = delta["fromRowId"] as? Int {
                    lock.lock()
                    rows.removeAll { $0.rowId >= fromRowId }
                    rowMap = rowMap.filter { $0.key < fromRowId }
                    lock.unlock()
                }
            case "row.delta":
                if snapshotLanded { applyRowDelta(delta) }
            case "state.updated":
                if let patch = delta["patch"] as? [String: Any] {
                    applyStatePatch(patch, notify: false)
                }
            default:
                break // 未知 op 宽容忽略
            }
        }
        lock.lock()
        seq = frame.toSeq
        lock.unlock()
    }

    private func upsertRow(_ row: ConversationRow) {
        lock.lock()
        rowMap[row.rowId] = row
        rows = rowMap.values.sorted { $0.rowId < $1.rowId }
        lock.unlock()
    }

    /// row.delta:流式追加。path×kind 白名单(不匹配静默丢弃)。
    private func applyRowDelta(_ delta: [String: Any]) {
        guard let rowId = delta["rowId"] as? Int,
              let path = delta["path"] as? String else { return }
        let append = delta["append"] as? String ?? ""
        lock.lock()
        guard var row = rowMap[rowId] else {
            lock.unlock()
            return // 行未到,丢弃(delta 早于 appended 时由 upsert 兜底)
        }
        let allowed: Bool
        switch path {
        case "text": allowed = row.kind == "assistantText" || row.kind == "reasoning"
        case "inputText": allowed = row.kind == "toolCall"
        case "output.text": allowed = row.kind == "toolCall"
        case "summaryText": allowed = row.kind == "subagent"
        default: allowed = false
        }
        guard allowed else { lock.unlock(); return }
        switch path {
        case "text": row.text += append
        case "inputText": row.inputText = (row.inputText ?? "") + append
        case "output.text": row.outputText = (row.outputText ?? "") + append
        case "summaryText": row.text += append
        default: break
        }
        rowMap[rowId] = row
        rows = rowMap.values.sorted { $0.rowId < $1.rowId }
        lock.unlock()
    }

    /// state.updated patch:顶层键整块替换;null = 清除
    private func applyStatePatch(_ patch: [String: Any], notify: Bool) {
        lock.lock()
        if sessionId == nil {
            // 快照未落地:缓冲
            pendingPatch.append(patch)
            lock.unlock()
            if notify { onUpdated?() }
            return
        }
        for (key, value) in patch {
            snapshotRaw[key] = value
            switch key {
            case "control":
                if let c = value as? [String: Any] {
                    control = Control(
                        phase: c["phase"] as? String ?? control.phase,
                        canStop: c["canStop"] as? Bool ?? control.canStop,
                        stopState: c["stopState"] as? String ?? control.stopState)
                } else if value is NSNull {
                    control = .idle
                }
            case "pendingInteractions":
                if let list = value as? [[String: Any]] {
                    pendingInteractions = list.compactMap(PendingInteraction.init)
                } else if value is NSNull {
                    pendingInteractions = []
                }
            case "meta":
                title = (value as? [String: Any])?["title"] as? String ?? title
            case "revision":
                if let r = value as? Int { revision = r }
            default:
                break
            }
        }
        lock.unlock()
        if notify { onUpdated?() }
    }

    /// 翻页结果合并(更早的历史行)
    public func prependOlder(rows older: [ConversationRow], hasMore: Bool) {
        lock.lock()
        for row in older { rowMap[row.rowId] = row }
        rows = rowMap.values.sorted { $0.rowId < $1.rowId }
        hasMoreOlder = hasMore
        lock.unlock()
        onUpdated?()
    }

    public func reset() {
        lock.lock()
        snapshotRaw = [:]
        sessionId = nil
        logEpoch = nil
        seq = 0
        revision = 0
        title = nil
        control = .idle
        pendingInteractions = []
        subscriptionId = nil
        pendingPatch = []
        rows = []
        rowMap = [:]
        firstRowId = nil
        totalCount = 0
        hasMoreOlder = false
        lock.unlock()
        onUpdated?()
    }
}
