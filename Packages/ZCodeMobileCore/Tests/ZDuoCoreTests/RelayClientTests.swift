import XCTest
@testable import ZCodeMobileCore

// MARK: - 测试替身

final class MockWS: WSConnection {
    var onOpen: (() -> Void)?
    var onText: ((String) -> Void)?
    var onClose: ((Int, String?) -> Void)?
    private(set) var sent: [String] = []
    private(set) var closedCount = 0

    func sendText(_ text: String) { sent.append(text) }
    func ping() {}
    func resumeIfNeeded() {}
    func close() {
        closedCount += 1
        onClose?(1000, "mock-close")
    }
}

final class MockWSFactory: WSFactory, @unchecked Sendable {
    private(set) var instances: [MockWS] = []
    private(set) var lastURL: URL?
    private(set) var lastHeaders: [String: String] = [:]

    func make(url: URL, headers: [String: String]) -> WSConnection {
        lastURL = url
        lastHeaders = headers
        let ws = MockWS()
        instances.append(ws)
        return ws
    }
}

/// 虚拟时钟(秒级推进)
final class VirtualClock: @unchecked Sendable {
    var base: TimeInterval
    var offset: TimeInterval = 0
    var now: Date { Date(timeIntervalSince1970: base + offset) }
    init(_ base: TimeInterval = 1_799_000_000) { self.base = base }
}

struct SeqRandom: @unchecked Sendable {
    let values: [Double]
    private let idx = AtomicCounter()
    func next() -> Double { values[idx.get() % values.count] }
}

final class AtomicCounter: @unchecked Sendable {
    private var n = 0
    private let lock = NSLock()
    func get() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}

// MARK: - RelayProtocol / QrParser / RetryPolicy 单测

final class RelayProtocolTests: XCTestCase {

    func testAuthInitUsesSeconds() {
        let date = Date(timeIntervalSince1970: 1_799_000_123)
        let frame = RelayProtocol.authInit(deviceSid: "d_abc", meta: .init(platform: "ios", version: "0.1", name: "ZCodeMobile"), now: date)
        let obj = try! JSONSerialization.jsonObject(with: Data(frame.utf8)) as! [String: Any]
        XCTAssertEqual(obj["type"] as? String, "auth_init")
        XCTAssertEqual(obj["device_sid"] as? String, "d_abc")
        XCTAssertEqual(obj["client_ts"] as? Int, 1_799_000_123) // 秒,不是毫秒
        XCTAssertNil(obj["role"]) // V2 严禁 role(strictObject)
        let meta = obj["meta"] as! [String: Any]
        XCTAssertEqual(meta["platform"] as? String, "ios")
    }

    func testHeartbeatHasNoDeviceSid() {
        let frame = RelayProtocol.heartbeat(now: Date(timeIntervalSince1970: 100))
        let obj = try! JSONSerialization.jsonObject(with: Data(frame.utf8)) as! [String: Any]
        XCTAssertEqual(obj["type"] as? String, "pair_status_query")
        XCTAssertEqual(obj["client_ts"] as? Int, 100)
        XCTAssertNil(obj["device_sid"]) // strictObject 拒多余字段
    }

    func testDataEnvelopeUsesMilliseconds() {
        let frame = RelayProtocol.dataEnvelope(payloadJSON: "{\"zcode_type\":\"x\"}", now: Date(timeIntervalSince1970: 1_799_000_123.456))
        let obj = try! JSONSerialization.jsonObject(with: Data(frame.utf8)) as! [String: Any]
        XCTAssertEqual(obj["type"] as? String, "data")
        XCTAssertEqual(obj["client_ts"] as? Int, 1_799_000_123_456) // 毫秒
        XCTAssertNotNil(obj["payload"])
    }

    func testWsUrlConstruction() {
        let url = RelayProtocol.v2RelayWsUrl(origin: "https://zcode.z.ai", token: "t123", mid: "m1")
        XCTAssertEqual(url?.absoluteString, "wss://zcode.z.ai/api/v1/remote/ws2?token=t123&mid=m1")
        // token 含需转义字符
        let url2 = RelayProtocol.v2RelayWsUrl(origin: "https://zcode.z.ai", token: "a+b/c", mid: nil)
        XCTAssertEqual(url2?.absoluteString, "wss://zcode.z.ai/api/v1/remote/ws2?token=a%2Bb%2Fc")
    }

    func testOriginHeader() {
        XCTAssertEqual(
            RelayProtocol.originHeader(forWsUrl: URL(string: "wss://zcode.z.ai/api/v1/remote/ws2")!),
            "https://zcode.z.ai")
    }

    func testEndpointValidation() {
        XCTAssertTrue(RelayProtocol.validateEndpoint(URL(string: "wss://zcode.z.ai/api")!))
        XCTAssertFalse(RelayProtocol.validateEndpoint(URL(string: "ws://zcode.z.ai/api")!)) // Release 拒 ws
        XCTAssertTrue(RelayProtocol.validateEndpoint(URL(string: "ws://localhost:8080/x")!, allowInsecureWS: true))
        XCTAssertFalse(RelayProtocol.validateEndpoint(URL(string: "https://zcode.z.ai")!))
    }

    func testInboundParse() {
        if case .authAck(_, let terminalSid, let pairStatus, _) = RelayInbound.parse(
            #"{"type":"auth_ack","device_sid":"d_1","terminal_sid":"t_9","pair_status":"matched"}"#) {
            XCTAssertEqual(terminalSid, "t_9")
            XCTAssertEqual(pairStatus, "matched")
        } else { XCTFail() }
        if case .error(let code, _) = RelayInbound.parse(#"{"type":"error","code":"KICKED"}"#) {
            XCTAssertEqual(code, "KICKED")
        } else { XCTFail() }
        if case .challenge = RelayInbound.parse(#"{"type":"auth_challenge"}"#) {} else { XCTFail() }
    }
}

final class QrParserTests: XCTestCase {

    func testV2Parse() throws {
        let device = try QrParser.parse("https://zcode.z.ai/remote/v4?sid=d_abc123&mid=mid-1&name=Peter%27s%20Mac&app_version=3.18.2")
        XCTAssertEqual(device.deviceSid, "d_abc123")
        XCTAssertEqual(device.deviceMid, "mid-1")
        XCTAssertEqual(device.deviceName, "Peter's Mac")
        XCTAssertTrue(device.isV2)
        XCTAssertEqual(device.remoteUrl, "https://zcode.z.ai/remote/v4")
        XCTAssertEqual(device.origin, "https://zcode.z.ai")
    }

    func testPlusPreEscaped() throws {
        // 字面 + 会被 URLComponents 当作空格,预转义后应保留
        let device = try QrParser.parse("https://zcode.z.ai/remote/v4?sid=a+b")
        XCTAssertEqual(device.deviceSid, "a+b")
    }

    func testMissingSidRejected() {
        XCTAssertThrowsError(try QrParser.parse("https://zcode.z.ai/remote/v4?mid=m")) { e in
            XCTAssertEqual(e as? QrParseError, .missingSid)
        }
    }

    func testV1Rejected() {
        XCTAssertThrowsError(try QrParser.parse("https://zcode.z.ai/remote/v3?sid=d_x&hash=abc%3D&t=1700")) { e in
            XCTAssertEqual(e as? QrParseError, .v1NotSupported)
        }
    }

    func testLandingUrlReusesSourceUrlVerbatim() throws {
        let raw = "https://zcode.z.ai/remote/v4?sid=d_a&mid=m&name=Mac%20Pro&app_version=3.18.2"
        let device = try QrParser.parse(raw)
        XCTAssertEqual(device.appVersion, "3.18.2")
        XCTAssertEqual(device.sourceUrl, raw)
        // 落地页逐字节复用扫码 URL(含 app_version —— 丢了会被官方页拒)
        XCTAssertEqual(device.landingUrl, raw)
    }

    func testLandingUrlRebuildIncludesAppVersion() throws {
        // 无 sourceUrl 时(如 SID 接续重建),四参重建也必须带 app_version
        let device = PairedDevice(deviceSid: "d_a", deviceMid: "m", deviceName: "Mac",
                                  remoteUrl: "https://zcode.z.ai/remote/v4", appVersion: "3.18.2")
        XCTAssertEqual(device.landingUrl, "https://zcode.z.ai/remote/v4?sid=d_a&mid=m&name=Mac&app_version=3.18.2")
    }
}

final class RetryPolicyTests: XCTestCase {

    func testBackoffSequence() {
        var policy = RetryPolicy(random: { 0.5 }, nowMs: { 0 }) // jitter 因子恒 1.0
        // 500,1000,2000,4000,8000,10000(封顶),10000
        XCTAssertEqual(policy.nextDelay(), 500)
        XCTAssertEqual(policy.nextDelay(), 1000)
        XCTAssertEqual(policy.nextDelay(), 2000)
        XCTAssertEqual(policy.nextDelay(), 4000)
        XCTAssertEqual(policy.nextDelay(), 8000)
        XCTAssertEqual(policy.nextDelay(), 10000)
        XCTAssertEqual(policy.nextDelay(), 10000)
    }

    func testJitterBounds() {
        var policy = RetryPolicy(random: { 0.0 }, nowMs: { 0 }) // 因子 = 1-0.2 = 0.8
        XCTAssertEqual(policy.nextDelay(), 400) // 500*0.8
        var policy2 = RetryPolicy(random: { 0.999 }, nowMs: { 0 })
        let d = policy2.nextDelay()
        XCTAssertLessThanOrEqual(d, 600) // 500*1.2
        XCTAssertGreaterThanOrEqual(d, 599)
    }

    func testSpreadAfterAcknowledged() {
        var policy = RetryPolicy(random: { 0.5 }, nowMs: { 0 })
        policy.acknowledged() // matched:清退避 + 下次打散
        XCTAssertEqual(policy.nextDelay(), 750) // 0.5 * 1500
        XCTAssertEqual(policy.nextDelay(), 500) // 之后正常退避
    }

    func testResetClearsButNoSpread() {
        var policy = RetryPolicy(random: { 0.5 }, nowMs: { 0 })
        policy.reset()
        XCTAssertEqual(policy.nextDelay(), 500)
    }

    func testKickedWindow() {
        var now: Double = 10_000
        var policy = RetryPolicy(random: { 0.5 }, nowMs: { now })
        let first = policy.kickedDelay()
        XCTAssertNotNil(first)
        XCTAssertEqual(first!, 3500) // 2000 + 0.5*3000(注意 kickedMax 应含边界 5000;官方 2000+random*3001)
        now = 40_000 // 30s 后,仍在 60s 窗口
        let second = policy.kickedDelay()
        XCTAssertNil(second) // 60s 内第二次 → 终态
        now = 80_000 // 70s 后,窗口过
        let third = policy.kickedDelay()
        XCTAssertNotNil(third)
    }
}

// MARK: - RelayClient 状态机

final class RelayClientTests: XCTestCase {

    var scheduler: ManualScheduler!
    var clock: VirtualClock!
    var factory: MockWSFactory!
    var tokenCalls: AtomicCounter!

    func makeClient(
        tokenResult: @escaping @Sendable (Int) throws -> String = { n in "relay-token-\(n)" }
    ) -> RelayClient {
        let device = try! QrParser.parse("https://zcode.z.ai/remote/v4?sid=d_test&mid=mid_test&name=Mac")
        tokenCalls = AtomicCounter()
        let deps = RelayClient.Dependencies(
            tokenFetcher: { [tokenCalls] in try tokenResult(tokenCalls.get()) },
            wsFactory: factory,
            scheduler: { [scheduler] work, delay in scheduler.schedule(work, delay) },
            now: { [clock] in clock.now },
            random: { 0.5 }
        )
        var config = RelayClient.Config()
        config.heartbeatInterval = 5
        config.heartbeatJitter = 1
        config.ackTimeout = 15
        config.deviceOfflineGrace = 15
        return RelayClient(device: device, config: config, deps: deps)
    }

    override func setUp() {
        super.setUp()
        scheduler = ManualScheduler()
        clock = VirtualClock()
        factory = MockWSFactory()
    }

    /// 让异步 Task(token fetch)有机会执行
    func yieldAsync(_ ms: Double = 0.05) {
        let exp = expectation(description: "yield")
        DispatchQueue.global().asyncAfter(deadline: .now() + ms) { exp.fulfill() }
        wait(for: [exp], timeout: 5)
    }

    /// 走到 Paired:token → ws → open → auth_ack(matched)
    @discardableResult
    func pair(_ client: RelayClient) -> MockWS {
        client.start()
        yieldAsync()
        scheduler.runAll() // token fetch → openSocket
        let ws = factory.instances.last!
        ws.onOpen!()
        scheduler.runAll() // 让 open 后的心跳调度挂上
        ws.onText!(#"{"type":"auth_ack","device_sid":"d_test","terminal_sid":"t_1","pair_status":"matched"}"#)
        return ws
    }

    func testAuthFlowAndFlush() {
        let client = makeClient()
        var states: [RelayClient.State] = []
        client.onStateChange = { states.append($0) }
        var pairedCount = 0
        client.onPaired = { pairedCount += 1 }

        // 未配对先发业务帧 → 入队
        client.sendPayload(#"{"zcode_type":"bootstrap-request","requestId":"boot-1"}"#)
        let ws = pair(client)

        XCTAssertEqual(client.state, .paired)
        XCTAssertEqual(pairedCount, 1)
        // auth_init 是第一条出站帧,client_ts 为秒
        let initObj = try! JSONSerialization.jsonObject(with: Data(ws.sent[0].utf8)) as! [String: Any]
        XCTAssertEqual(initObj["type"] as? String, "auth_init")
        XCTAssertEqual(initObj["client_ts"] as? Int, Int(clock.now.timeIntervalSince1970))
        // 队列中的 bootstrap 信封被 flush(client_ts 毫秒)
        XCTAssertTrue(ws.sent.contains { text in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return false }
            return obj["type"] as? String == "data"
                && (obj["client_ts"] as! Int) > 1_700_000_000_000
        })
        // Origin 头与 WS URL
        XCTAssertEqual(factory.lastHeaders["Origin"], "https://zcode.z.ai")
        XCTAssertEqual(factory.lastURL?.absoluteString, "wss://zcode.z.ai/api/v1/remote/ws2?token=relay-token-1&mid=mid_test")
        XCTAssertTrue(states.contains(.connecting))
        XCTAssertTrue(states.contains(.authenticating))
    }

    func testWaitingThenMatched() {
        let client = makeClient()
        client.start()
        yieldAsync()
        scheduler.runAll()
        let ws = factory.instances.last!
        ws.onOpen!()
        ws.onText!(#"{"type":"auth_ack","pair_status":"waiting"}"#)
        XCTAssertEqual(client.state, .waitingPeer)
        ws.onText!(#"{"type":"pair_status_ack","pair_status":"matched"}"#)
        XCTAssertEqual(client.state, .paired)
    }

    func testHeartbeatSentAndWatchdog() {
        let client = makeClient()
        let ws = pair(client)
        let sentBefore = ws.sent.count

        clock.offset += 5 // 5s 后
        scheduler.advance(by: 5) // 触发心跳(jitter 0.5 → 间隔 5s)
        let heartbeat = ws.sent.last!
        let obj = try! JSONSerialization.jsonObject(with: Data(heartbeat.utf8)) as! [String: Any]
        XCTAssertEqual(obj["type"] as? String, "pair_status_query")
        XCTAssertEqual(obj["client_ts"] as? Int, Int(clock.now.timeIntervalSince1970))

        // 15s 无任何 ack → watchdog → failed(network, 非终态) → 调度重连
        clock.offset += 15
        scheduler.advance(by: 15)
        if case .failed(.network, _) = client.state {} else {
            XCTFail("expected network failure, got \(client.state)")
        }
        // 重连调度(异步 token fetch → 新 socket)
        scheduler.runAll()
        yieldAsync()
        XCTAssertEqual(factory.instances.count, 2, "should have reconnected")
    }

    func testAuthErrorIsTerminal() {
        let client = makeClient()
        client.start()
        yieldAsync()
        scheduler.runAll()
        let ws = factory.instances.last!
        ws.onOpen!()
        ws.onText!(#"{"type":"error","code":"AUTH_FAILED","message":"expired"}"#)
        if case .failed(.authFailed, _) = client.state {} else { XCTFail() }
        XCTAssertTrue(ws.closedCount > 0)
        // 终态后 start 不再动作
        client.start()
        scheduler.runAll()
        XCTAssertEqual(factory.instances.count, 1)
    }

    func testKickedSelfHealThenTerminal() {
        let client = makeClient()
        _ = pair(client)
        XCTAssertEqual(factory.instances.count, 1)

        // 第一次 KICKED:2~5s 自愈重连
        factory.instances.last!.onText!(#"{"type":"error","code":"KICKED"}"#)
        clock.offset += 1
        scheduler.advance(by: 3.5) // kickedDelay = 3500ms
        yieldAsync() // 异步 token fetch → openSocket
        XCTAssertEqual(factory.instances.count, 2, "should self-heal reconnect")

        // 立即再次 KICKED(60s 窗口内)→ 终态
        factory.instances.last!.onOpen!()
        factory.instances.last!.onText!(#"{"type":"auth_ack","pair_status":"matched"}"#)
        factory.instances.last!.onText!(#"{"type":"error","code":"KICKED"}"#)
        if case .failed(.kicked, _) = client.state {} else { XCTFail("expected kicked terminal, got \(client.state)") }
    }

    func testDeviceOfflineGrace() {
        let client = makeClient()
        client.start()
        yieldAsync()
        scheduler.runAll()
        let ws = factory.instances.last!
        ws.onOpen!()
        ws.onText!(#"{"type":"auth_ack","pair_status":"waiting"}"#)
        ws.onText!(#"{"type":"error","code":"DEVICE_OFFLINE"}"#)
        XCTAssertEqual(client.state, .waitingPeer)

        clock.offset += 16
        scheduler.advance(by: 16) // 宽限 15s 到期
        if case .failed(.desktopDisconnected, _) = client.state {} else {
            XCTFail("expected desktopDisconnected, got \(client.state)")
        }
    }

    func testDeviceOfflineCancelsOnMatched() {
        let client = makeClient()
        client.start()
        yieldAsync()
        scheduler.runAll()
        let ws = factory.instances.last!
        ws.onOpen!()
        ws.onText!(#"{"type":"auth_ack","pair_status":"waiting"}"#)
        ws.onText!(#"{"type":"error","code":"DEVICE_OFFLINE"}"#)
        // 重连成功 + matched → 宽限取消
        ws.onText!(#"{"type":"pair_status_ack","pair_status":"matched"}"#)
        XCTAssertEqual(client.state, .paired)
        clock.offset += 20
        scheduler.advance(by: 20)
        XCTAssertEqual(client.state, .paired, "grace check must be cancelled by matched")
    }

    func testChallengeIsProtocolMismatch() {
        let client = makeClient()
        client.start()
        yieldAsync()
        scheduler.runAll()
        let ws = factory.instances.last!
        ws.onOpen!()
        ws.onText!(#"{"type":"auth_challenge","nonce":"x"}"#)
        if case .failed(.protocolMismatch, _) = client.state {} else { XCTFail() }
    }

    func testUnknownPairStatusIsProtocolMismatch() {
        let client = makeClient()
        client.start()
        yieldAsync()
        scheduler.runAll()
        let ws = factory.instances.last!
        ws.onOpen!()
        ws.onText!(#"{"type":"auth_ack","pair_status":"weird"}"#)
        if case .failed(.protocolMismatch, _) = client.state {} else { XCTFail() }
    }

    func testTokenAuthFailureIsTerminal() {
        let client = makeClient(tokenResult: { _ in
            throw V2AccountApi.ApiError.authFailed("HTTP 401")
        })
        client.start()
        let exp = expectation(description: "async token")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1)
        if case .failed(.authFailed, _) = client.state {} else { XCTFail() }
        XCTAssertEqual(factory.instances.count, 0)
    }

    func testTokenNetworkFailureRetries() {
        final class Flag: @unchecked Sendable {
            private var v = true
            private let lock = NSLock()
            func take() -> Bool { lock.lock(); defer { lock.unlock() }; let old = v; v = false; return old }
        }
        let failFirst = Flag()
        let client = makeClient(tokenResult: { _ in
            if failFirst.take() {
                throw V2AccountApi.ApiError.network("dns")
            }
            return "token-2"
        })
        client.start()
        let exp = expectation(description: "retry")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(client.state, .connecting) // 等待重连调度
        scheduler.runAll() // 执行重连任务 → connect → 异步 token
        yieldAsync()
        XCTAssertEqual(factory.instances.count, 1)
    }

    func testOutboundQueueOverflowDropsAll() {
        let client = makeClient()
        client.start()
        yieldAsync()
        scheduler.runAll()
        for i in 0..<55 { client.sendPayload("{\"n\":\(i)}") } // 超 50 上限
        let ws = factory.instances.last!
        ws.onOpen!()
        ws.onText!(#"{"type":"auth_ack","pair_status":"matched"}"#)
        // 第 51 条触发整批丢弃(1-50 全没了);52-55 共 4 条在丢弃后入队,配对时 flush
        let dataFrames = ws.sent.filter { text in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return false }
            return obj["type"] as? String == "data"
        }
        XCTAssertEqual(dataFrames.count, 4)
        // auth_init 不是 data 帧
        let initCount = ws.sent.filter { text in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return false }
            return obj["type"] as? String == "auth_init"
        }
        XCTAssertEqual(initCount.count, 1)
    }

    func testStopPreventsReconnect() {
        let client = makeClient()
        _ = pair(client)
        client.stop(reason: "user")
        XCTAssertEqual(client.state, .idle)
        let tasksBefore = scheduler.tasks.count
        clock.offset += 30
        scheduler.advance(by: 30)
        XCTAssertEqual(factory.instances.count, 1, "no reconnect after stop")
        XCTAssertTrue(tasksBefore >= 0)
    }

    func testGenerationGuardIgnoresStaleClose() {
        let client = makeClient()
        let ws = pair(client)
        // 模拟旧代次 socket 的迟到 close 回调
        client.stop(reason: "switch")
        ws.onClose?(1006, "stale") // 旧 socket 回调
        XCTAssertEqual(client.state, .idle)
        scheduler.runAll()
        XCTAssertEqual(factory.instances.count, 1)
    }

    func testNetworkLostAndRestored() {
        let client = makeClient()
        _ = pair(client)
        client.handleNetworkLost()
        XCTAssertEqual(client.state, .idle)
        client.handleNetworkRestored()
        yieldAsync()
        scheduler.runAll()
        yieldAsync()
        XCTAssertEqual(factory.instances.count, 2)
        factory.instances.last!.onOpen!()
        factory.instances.last!.onText!(#"{"type":"auth_ack","pair_status":"matched"}"#)
        XCTAssertEqual(client.state, .paired)
    }
}
