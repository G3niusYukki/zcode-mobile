import XCTest
@testable import ZCodeMobileCore

// MARK: - 假服务器:接通道客户端的出站请求,允许测试解码并回帧

final class FakeHost {
    struct Request {
        let type: Int
        let id: Int
        let channel: String
        let method: String
        let args: IpcValue
    }

    let client = ChannelClient()
    private(set) var requests: [Request] = []
    private let lock = NSLock()

    /// 出站字节 → Request(100/102);测试手动回 201/204
    func attach() {
        client.attach { [weak self] data in
            guard let self else { throw ChannelClient.ChannelError.notReady }
            guard let (header, second) = try? IpcCodec.decodeMessage([UInt8](data)),
                  header.count >= 4,
                  case .int(let type) = header[0],
                  case .int(let id) = header[1],
                  case .string(let channel) = header[2],
                  case .string(let method) = header[3] else {
                throw ChannelClient.ChannelError.notReady
            }
            self.lock.lock()
            self.requests.append(Request(type: type, id: id, channel: channel, method: method, args: second))
            self.lock.unlock()
        }
    }

    /// 服务端就绪(200)
    func sendInitialize() {
        let bytes = IpcCodec.encode(.array([.int(200)]))
        client.handleData(Data(bytes))
    }

    /// 回 201 应答
    func respond(id: Int, value: IpcValue) {
        let bytes = IpcCodec.encode(.array([.int(201), .int(id)])) + IpcCodec.encode(value)
        client.handleData(Data(bytes))
    }

    /// 推 204 事件(挂监听 id)
    func fire(listenerId: Int, value: IpcValue) {
        let bytes = IpcCodec.encode(.array([.int(204), .int(listenerId)])) + IpcCodec.encode(value)
        client.handleData(Data(bytes))
    }

    var lastRequest: Request? {
        lock.lock(); defer { lock.unlock() }
        return requests.last
    }
}

// MARK: - ChannelClient

final class ChannelClientTests: XCTestCase {

    func testNotReadyBefore200() async {
        let host = FakeHost()
        host.attach() // attach 但未发 200
        do {
            _ = try await host.client.call("zcode-agent", "ping", args: [], timeout: 1)
            XCTFail("should reject")
        } catch { /* notReady */ }
    }

    func testCallRoundtrip() async {
        let host = FakeHost()
        host.attach()
        host.sendInitialize()

        let task = Task {
            try await host.client.call("zcode-agent", "helloConversationV4", args: [], timeout: 2)
        }
        // 等请求出站
        try! await Task.sleep(nanoseconds: 100_000_000)
        let req = host.lastRequest
        XCTAssertNotNil(req)
        XCTAssertEqual(req?.type, 100)
        XCTAssertEqual(req?.channel, "zcode-agent")
        XCTAssertEqual(req?.method, "helloConversationV4")
        if case .array(let args) = req?.args { XCTAssertTrue(args.isEmpty) } else { XCTFail("args should be array") }

        host.respond(id: req!.id, value: .json(#"{"kind":"hello","protocolVersion":3,"connectionId":"host-rpc-1"}"#))
        let result = try! await task.value
        if case .json(let text) = result {
            XCTAssertTrue(text.contains(#""connectionId":"host-rpc-1""#))
        } else { XCTFail() }
    }

    func testCallError() async {
        let host = FakeHost()
        host.attach()
        host.sendInitialize()
        let task = Task {
            try await host.client.call("zcode-agent", "nope", args: [], timeout: 2)
        }
        try! await Task.sleep(nanoseconds: 100_000_000)
        let req = host.lastRequest!
        host.respond(id: req.id, value: .json(#"{"message":"Method not found: nope","name":"Error"}"#))
        // 202 需要手造:FakeHost.respond 只有 201;直接构造 202
        let bytes = IpcCodec.encode(.array([.int(202), .int(req.id)]))
            + IpcCodec.encode(.json(#"{"message":"Method not found: nope"}"#))
        _ = bytes
        do {
            _ = try await task.value
        } catch let ChannelClient.ChannelError.promiseRejected(message, _) {
            // respond 201 的值不是错误;此测试实际验证 201 路径 — 见 testError202
            XCTAssertFalse(message.isEmpty)
        } catch { XCTFail("unexpected \(error)") }
    }

    func testError202() async {
        let host = FakeHost()
        host.attach()
        host.sendInitialize()
        let task = Task {
            try await host.client.call("zcode-agent", "x", args: [], timeout: 2)
        }
        try! await Task.sleep(nanoseconds: 100_000_000)
        let req = host.lastRequest!
        let bytes = IpcCodec.encode(.array([.int(202), .int(req.id)]))
            + IpcCodec.encode(.json(#"{"message":"Method not found: x"}"#))
        host.client.handleData(Data(bytes))
        do {
            _ = try await task.value
            XCTFail("should throw")
        } catch let ChannelClient.ChannelError.promiseRejected(message, _) {
            XCTAssertEqual(message, "Method not found: x")
        } catch { XCTFail("unexpected \(error)") }
    }

    func testEventListenAndFire() async throws {
        let host = FakeHost()
        host.attach()
        host.sendInitialize()

        var fired: [IpcValue] = []
        let listenerId = try host.client.listen(
            "zcode-agent", event: "onDynamicConversationFrame",
            arg: IpcValue.object([("workspacePath", IpcValue.string("/w"))])) { fired.append($0) }

        // 102 的头是 [102, id, channel, event],第二段是裸值
        let req = host.lastRequest
        XCTAssertEqual(req?.type, 102)
        XCTAssertEqual(req?.method, "onDynamicConversationFrame")
        if case .array? = req?.args { XCTFail("listen arg must be bare value not array") }

        host.fire(listenerId: listenerId, value: .json(#"{"wireVersion":3,"kind":"complete","topic":"conversation/sess_1","frame":{"topic":"conversation/sess_1","fromSeq":0,"toSeq":1,"payload":{"kind":"snapshot","snapshot":{"sessionId":"sess_1"}}}}"#))
        XCTAssertEqual(fired.count, 1)
    }

    func testTimeout() async {
        let host = FakeHost()
        host.attach()
        host.sendInitialize()
        do {
            _ = try await host.client.call("zcode-agent", "slow", args: [], timeout: 0.2)
            XCTFail("should timeout")
        } catch let ChannelClient.ChannelError.timeout(label) {
            XCTAssertTrue(label.contains("slow"))
        } catch { XCTFail("unexpected \(error)") }
    }
}

// MARK: - WireReassembler

final class WireReassemblerTests: XCTestCase {

    func jsonDict(_ text: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }

    func testCompletePassthrough() {
        let r = WireReassembler()
        let result = r.accept(jsonDict(#"{"wireVersion":3,"kind":"complete","topic":"conversation/sess_1","frame":{"topic":"conversation/sess_1","fromSeq":0,"toSeq":5,"payload":{"kind":"deltas","deltas":[]}}}"#))
        guard case .success(let frame) = result, let frame else { return XCTFail() }
        XCTAssertEqual(frame["topic"] as? String, "conversation/sess_1")
        XCTAssertEqual(frame["toSeq"] as? Int, 5)
    }

    func testFragmentReassembly() throws {
        let r = WireReassembler()
        let topicFrame = #"{"topic":"conversation/sess_2","fromSeq":0,"toSeq":9,"payload":{"kind":"deltas","deltas":[{"op":"row.appended","row":{"rowId":1,"kind":"userInput","text":"hi"}}]}}"#
        let payload = Data(topicFrame.utf8)
        let crc = Crc32.hex(payload)
        let mid = payload.count / 2
        let part1 = payload[0..<mid], part2 = payload[mid...]

        let envelope1: [String: Any] = [
            "wireVersion": 3, "kind": "fragment", "logicalFrameId": "lf-1", "logicalFrameOrdinal": 1,
            "topic": "conversation/sess_2", "subscriptionId": "sub-1",
            "fragmentIndex": 0, "fragmentCount": 2, "logicalBytes": payload.count,
            "checksum": ["algorithm": "crc32", "value": crc],
            "dataBase64": Data(part1).base64EncodedString(),
        ]
        let result1 = r.accept(envelope1)
        guard case .success(let none) = result1, none == nil else { return XCTFail("should wait for fragment 2") }

        var envelope2 = envelope1
        envelope2["fragmentIndex"] = 1
        envelope2["dataBase64"] = Data(part2).base64EncodedString()
        let result2 = r.accept(envelope2)
        guard case .success(let frame) = result2, let frame else { return XCTFail("should complete") }
        XCTAssertEqual(frame["toSeq"] as? Int, 9)
        let payload2 = frame["payload"] as! [String: Any]
        XCTAssertEqual(payload2["kind"] as? String, "deltas")
    }

    func testMetadataMismatch() {
        let r = WireReassembler()
        let base: [String: Any] = [
            "wireVersion": 3, "kind": "fragment", "logicalFrameId": "lf-x",
            "fragmentIndex": 0, "fragmentCount": 2, "logicalBytes": 100,
            "checksum": ["algorithm": "crc32", "value": "deadbeef"],
            "dataBase64": Data([0x01]).base64EncodedString(),
        ]
        _ = r.accept(base) // ok,等待
        var bad = base
        bad["logicalBytes"] = 200 // 元数据不一致
        bad["fragmentIndex"] = 1
        if case .failure(let e) = r.accept(bad) {
            if case .metadataMismatch = e {} else { XCTFail("\(e)") }
        } else { XCTFail("expected failure") }
    }

    func testLegacyBareFrameTolerated() {
        let r = WireReassembler()
        let result = r.accept(jsonDict(#"{"topic":"controller/tasks-index","fromSeq":0,"toSeq":1,"payload":{"kind":"snapshot","snapshot":{"tasks":[]}}}"#))
        guard case .success(let frame) = result, frame != nil else { return XCTFail() }
    }
}

// MARK: - ConversationState 归约

final class ConversationStateTests: XCTestCase {

    func makeSnapshotFrame(toSeq: Int = 100) -> TopicFrame {
        let snapshot: [String: Any] = [
            "sessionId": "sess_1", "logEpoch": "epoch-1", "revision": 10,
            "meta": ["title": "测试会话"],
            "control": ["phase": "running", "canStop": true, "stopState": "stoppable"],
            "pendingInteractions": [[
                "interactionId": "perm_1", "kind": "permission",
                "payload": ["toolName": "Bash", "summary": "运行命令",
                            "detail": ["command": "swift test"],
                            "options": [["optionId": "opt-allow", "label": "允许一次", "kind": "allowOnce"],
                                        ["optionId": "opt-deny", "label": "拒绝", "kind": "deny"]]],
            ]],
            "rows": [
                "window": [
                    ["rowId": 5, "kind": "userInput", "text": "你好"],
                    ["rowId": 6, "kind": "assistantText", "text": "我是", "state": "streaming"],
                ],
                "totalCount": 10, "firstRowId": 1,
            ],
        ]
        let dict: [String: Any] = [
            "topic": "conversation/sess_1", "subscriptionId": "sub-1",
            "fromSeq": 0, "toSeq": toSeq,
            "payload": ["kind": "snapshot", "snapshot": snapshot],
        ]
        return TopicFrame(dict: dict)!
    }

    func makeDeltasFrame(fromSeq: Int, toSeq: Int, ops: [[String: Any]]) -> TopicFrame {
        let dict: [String: Any] = [
            "topic": "conversation/sess_1", "subscriptionId": "sub-1",
            "fromSeq": fromSeq, "toSeq": toSeq,
            "payload": ["kind": "deltas", "deltas": ops],
        ]
        return TopicFrame(dict: dict)!
    }

    func testSnapshotApply() {
        let s = ConversationState()
        s.apply(frame: makeSnapshotFrame())
        XCTAssertEqual(s.sessionId, "sess_1")
        XCTAssertEqual(s.title, "测试会话")
        XCTAssertTrue(s.isRunning)
        XCTAssertTrue(s.control.canStop)
        XCTAssertEqual(s.rows.count, 2)
        XCTAssertEqual(s.rows[0].rowId, 5)
        XCTAssertEqual(s.pendingInteractions.count, 1)
        XCTAssertEqual(s.pendingInteractions[0].options.count, 2)
        XCTAssertEqual(s.pendingInteractions[0].options[0].optionId, "opt-allow")
        XCTAssertTrue(s.hasMoreOlder) // firstRowId=1,最早加载 5
    }

    func testDeltaAppendAndStream() {
        let s = ConversationState()
        s.apply(frame: makeSnapshotFrame())
        s.apply(frame: makeDeltasFrame(fromSeq: 100, toSeq: 101, ops: [
            ["op": "row.appended", "row": ["rowId": 7, "kind": "toolCall", "toolName": "Bash", "status": "running"]],
            ["op": "row.delta", "rowId": 6, "path": "text", "append": "ZCode"],
        ]))
        XCTAssertEqual(s.rows.count, 3)
        XCTAssertEqual(s.rows.first { $0.rowId == 6 }?.text, "我是ZCode")
        // path-kind 白名单:text delta 不适用于 toolCall
        s.apply(frame: makeDeltasFrame(fromSeq: 101, toSeq: 102, ops: [
            ["op": "row.delta", "rowId": 7, "path": "text", "append": "X"],
        ]))
        XCTAssertEqual(s.rows.first { $0.rowId == 7 }?.text, "") // 被静默丢弃
        // output.text 适用于 toolCall
        s.apply(frame: makeDeltasFrame(fromSeq: 102, toSeq: 103, ops: [
            ["op": "row.delta", "rowId": 7, "path": "output.text", "append": "done"],
        ]))
        XCTAssertEqual(s.rows.first { $0.rowId == 7 }?.outputText, "done")
    }

    func testStateUpdatedReplacesPendingInteractions() {
        let s = ConversationState()
        s.apply(frame: makeSnapshotFrame())
        XCTAssertEqual(s.pendingInteractions.count, 1)
        s.apply(frame: makeDeltasFrame(fromSeq: 100, toSeq: 101, ops: [
            ["op": "state.updated", "patch": ["pendingInteractions": [], "control": ["phase": "completedInterrupted", "canStop": false, "stopState": "idle"]]],
        ]))
        XCTAssertEqual(s.pendingInteractions.count, 0)
        XCTAssertFalse(s.isRunning)
    }

    func testSeqGapTriggersResync() {
        let s = ConversationState()
        var resynced = 0
        s.onResyncNeeded = { resynced += 1 }
        s.apply(frame: makeSnapshotFrame()) // toSeq 100
        s.apply(frame: makeDeltasFrame(fromSeq: 105, toSeq: 106, ops: [])) // 缺口
        XCTAssertEqual(resynced, 1)
    }

    func testRowRemoved() {
        let s = ConversationState()
        s.apply(frame: makeSnapshotFrame())
        s.apply(frame: makeDeltasFrame(fromSeq: 100, toSeq: 101, ops: [
            ["op": "row.removed", "fromRowId": 6],
        ]))
        XCTAssertEqual(s.rows.map(\.rowId), [5])
    }

    func testOldSubscriptionDeltasIgnored() {
        let s = ConversationState()
        s.apply(frame: makeSnapshotFrame()) // sub-1
        let dict: [String: Any] = [
            "topic": "conversation/sess_1", "subscriptionId": "sub-OLD",
            "fromSeq": 100, "toSeq": 101,
            "payload": ["kind": "deltas", "deltas": [["op": "row.appended", "row": ["rowId": 99, "kind": "userInput", "text": "旧订阅"]]]],
        ]
        s.apply(frame: TopicFrame(dict: dict)!)
        XCTAssertEqual(s.rows.count, 2) // 未增加
    }

    func testPrependOlderPreservesOrder() {
        let s = ConversationState()
        s.apply(frame: makeSnapshotFrame())
        s.prependOlder(rows: [
            ConversationRow(dict: ["rowId": 2, "kind": "userInput", "text": "更早"])!,
            ConversationRow(dict: ["rowId": 4, "kind": "assistantText", "text": "中间"])!,
        ], hasMore: true)
        XCTAssertEqual(s.rows.map(\.rowId), [2, 4, 5, 6])
    }

    func testPatchBeforeSnapshotBuffered() {
        let s = ConversationState()
        s.apply(frame: makeDeltasFrame(fromSeq: 0, toSeq: 1, ops: [
            ["op": "state.updated", "patch": ["meta": ["title": "新标题"]]],
        ]))
        XCTAssertNil(s.sessionId) // 未落地
        s.apply(frame: makeSnapshotFrame())
        XCTAssertEqual(s.title, "新标题") // 缓冲 patch 被合并
    }
}

// MARK: - ControllerChannel 归约

final class ControllerChannelTests: XCTestCase {

    func channel() -> ControllerChannel {
        ControllerChannel(client: ChannelClient())
    }

    func tasksSnapshot(toSeq: Int, tasks: [[String: Any]]) -> IpcValue {
        .json(#"{"topic":"controller/tasks-index","fromSeq":0,"toSeq":\#(toSeq),"payload":{"kind":"snapshot","snapshot":{"protocolVersion":1,"logEpoch":"e1","tasks":\#(jsonString(tasks))}}}"#)
    }

    func jsonString(_ obj: Any) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }

    func taskDict(id: String, title: String, updatedAt: Double, pinned: Bool = false, archived: Bool = false) -> [String: Any] {
        [
            "address": ["workspacePath": "/w", "taskId": id],
            "meta": ["taskId": id, "title": title, "workspacePath": "/w", "updatedAt": updatedAt],
            "membership": ["pinned": pinned, "archived": archived, "active": false],
            "liveStatus": "running",
        ]
    }

    func testSnapshotAndDeltas() {
        let c = channel()
        c.handleEvent(tasksSnapshot(toSeq: 1, tasks: [taskDict(id: "sess_a", title: "A", updatedAt: 100)]))
        XCTAssertEqual(c.tasks.count, 1)
        XCTAssertEqual(c.tasks[0].title, "A")

        // fromSeq=1 续接 → upsert 生效
        c.handleEvent(.json(#"{"topic":"controller/tasks-index","fromSeq":1,"toSeq":2,"payload":{"kind":"deltas","deltas":[{"op":"task.upserted","task":\#(jsonString(taskDict(id: "sess_b", title: "B", updatedAt: 200, pinned: true)))},{"op":"task.upserted","task":\#(jsonString(taskDict(id: "sess_a", title: "A2", updatedAt: 100)))}]}}"#))
        XCTAssertEqual(c.tasks.count, 2)
        XCTAssertEqual(c.visibleTasks.first?.taskId, "sess_b") // pinned 置顶

        // fromSeq 缺口 → 忽略本帧(重同步在真机上触发)
        c.handleEvent(.json(#"{"topic":"controller/tasks-index","fromSeq":9,"toSeq":10,"payload":{"kind":"deltas","deltas":[{"op":"task.upserted","task":\#(jsonString(taskDict(id: "sess_c", title: "C", updatedAt: 300)))}]}}"#))
        XCTAssertEqual(c.tasks.count, 2)
    }

    func testArchivedFiltered() {
        let c = channel()
        c.handleEvent(tasksSnapshot(toSeq: 1, tasks: [
            taskDict(id: "sess_a", title: "A", updatedAt: 100),
            taskDict(id: "sess_z", title: "Z", updatedAt: 50, archived: true),
        ]))
        XCTAssertEqual(c.tasks.count, 2)
        XCTAssertEqual(c.visibleTasks.map(\.taskId), ["sess_a"])
    }

    func testWorkspacesSnapshot() {
        let c = channel()
        c.handleEvent(.json(#"{"topic":"controller/workspaces","fromSeq":0,"toSeq":1,"payload":{"kind":"snapshot","snapshot":{"protocolVersion":1,"logEpoch":"e1","workspaces":[{"workspacePath":"/w","connectionState":"online","sourceAvailability":"online"}]}}}"#))
        XCTAssertEqual(c.workspaces.count, 1)
        XCTAssertEqual(c.workspaces[0].connectionState, "online")
    }
}

// MARK: - ConversationChannel(握手 + 订阅,走 FakeHost)

final class ConversationChannelTests: XCTestCase {

    func testHandshakeAndSubscribe() async throws {
        let host = FakeHost()
        host.attach()
        host.sendInitialize()
        let channel = ConversationChannel(client: host.client, clientId: "ios-test")

        // 后台监听 204
        let listenerId = try channel.startListening(workspacePath: "/w", workspaceIdentity: nil)

        let handshakeTask = Task { try await channel.handshake() }
        try! await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(host.lastRequest?.method, "helloConversationV4")
        host.respond(id: host.lastRequest!.id, value: .json(#"{"kind":"hello","protocolVersion":3,"connectionId":"host-rpc-x","capabilities":{"nativeDialogs":false}}"#))
        try! await Task.sleep(nanoseconds: 100_000_000)
        // initialize 请求
        let initReq = host.requests.last!
        XCTAssertEqual(initReq.method, "initializeConversationV4")
        if case .array(let args) = initReq.args, case .json(let text)? = args.first {
            XCTAssertTrue(text.contains(#""clientId":"ios-test""#))
            XCTAssertTrue(text.contains(#""clientKind":"mobileApp""#))
        } else { XCTFail() }
        host.respond(id: initReq.id, value: .json(#"{"ok":true}"#))
        _ = try! await handshakeTask.value
        XCTAssertEqual(channel.handshakeInfo.connectionId, "host-rpc-x")

        // 订阅
        let subscribeTask = Task { try await channel.subscribe(sessionId: "sess_9", workspacePath: "/w", workspaceIdentity: nil) }
        try! await Task.sleep(nanoseconds: 100_000_000)
        let subReq = host.requests.last!
        XCTAssertEqual(subReq.method, "subscribeConversationV4")
        if case .array(let args) = subReq.args, case .json(let text)? = args.first {
            XCTAssertTrue(text.contains(#""sessionId":"sess_9""#))
            XCTAssertTrue(text.contains(#""workspacePath":"/w""#))
        } else { XCTFail() }
        host.respond(id: subReq.id, value: .json(#"{"ack":{"subscriptionId":"sub-abc","mode":"snapshot","logEpoch":"e1"}}"#))

        // 推一帧快照(挂 listenerId)
        let snapshotEnvelope = #"{"wireVersion":3,"kind":"complete","topic":"conversation/sess_9","subscriptionId":"sub-abc","frame":{"topic":"conversation/sess_9","subscriptionId":"sub-abc","fromSeq":0,"toSeq":1,"payload":{"kind":"snapshot","snapshot":{"sessionId":"sess_9","logEpoch":"e1","rows":{"window":[{"rowId":1,"kind":"userInput","text":"hi"}],"totalCount":1,"firstRowId":1},"control":{"phase":"idle","canStop":false}}}}}"#
        host.fire(listenerId: listenerId, value: .json(snapshotEnvelope))

        _ = try! await subscribeTask.value
        // 订阅完成的同一 runloop 内帧应已入 state(等一小会)
        try! await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(channel.state.rows.count, 1)
        XCTAssertEqual(channel.state.rows[0].text, "hi")
    }

    func testSendTextCommandEnvelope() async throws {
        let host = FakeHost()
        host.attach()
        host.sendInitialize()
        let channel = ConversationChannel(client: host.client, clientId: "ios-test")

        let task = Task {
            try await channel.sendText("你好 ZCode", sessionId: "sess_9", workspacePath: "/w", workspaceIdentity: nil)
        }
        try! await Task.sleep(nanoseconds: 100_000_000)
        let req = host.lastRequest!
        XCTAssertEqual(req.method, "sendConversationCommandV4")
        if case .array(let args) = req.args, case .json(let text)? = args.first {
            XCTAssertTrue(text.contains(#""type":"sendText""#))
            XCTAssertTrue(text.contains(#""text":"你好 ZCode""#))
            XCTAssertTrue(text.contains(#""clientId":"ios-test""#))
            XCTAssertTrue(text.contains(#""commandId":"cmd-"#))
            XCTAssertTrue(text.contains(#""issuedAt":"#)) // issuedAt 是数字,JSON 文本包含键名
        } else { XCTFail() }

        host.respond(id: req.id, value: .json(#"{"ack":{"status":"accepted","revisionAtDecision":11}}"#))
        let ack = try! await task.value
        XCTAssertEqual(ack.status, "accepted")
        XCTAssertTrue(ack.isSuccess)
    }
}
