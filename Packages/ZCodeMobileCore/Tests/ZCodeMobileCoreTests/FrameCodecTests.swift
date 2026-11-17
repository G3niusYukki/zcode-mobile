import XCTest
@testable import ZCodeMobileCore

final class FrameCodecTests: XCTestCase {

    // MARK: - Varint 金样本(docs/specs/frame-codec.md §2.1)

    func testVarintGoldenTable() throws {
        let cases: [(UInt32, [UInt8])] = [
            (0, [0x00]),
            (1, [0x01]),
            (127, [0x7F]),
            (128, [0x80, 0x01]),
            (300, [0xAC, 0x02]),
            (16384, [0x80, 0x80, 0x01]),
            (100, [0x64]),
            (2_147_483_647, [0xFF, 0xFF, 0xFF, 0xFF, 0x07]),
        ]
        for (value, expected) in cases {
            var w = VarintWriter()
            w.writeVarint(value)
            XCTAssertEqual(w.bytes, expected, "varint(\(value))")
            let r = VarintReader(expected)
            XCTAssertEqual(try r.readVarint(), value, "roundtrip(\(value))")
            XCTAssertEqual(r.remaining, 0)
        }
    }

    func testVarintOverflowRejected() {
        // shift==28 且高 4 位非零 → 溢出
        XCTAssertThrowsError(try VarintReader([0xFF, 0xFF, 0xFF, 0xFF, 0x7F]).readVarint())
        // 截断 → 数据不足
        XCTAssertThrowsError(try VarintReader([0x80]).readVarint())
    }

    // MARK: - CRC32

    func testCrc32Golden() {
        XCTAssertEqual(Crc32.hex(Data("123456789".utf8)), "cbf43926")
        XCTAssertEqual(Crc32.hex(Data()), "00000000")
    }

    // MARK: - IPC 值编码金样本(§2.5)

    func testIpcValueGolden() {
        XCTAssertEqual(IpcCodec.encode(.string("")), [0x01, 0x00])
        XCTAssertEqual(IpcCodec.encode(.string("AB")), [0x01, 0x02, 0x41, 0x42])
        XCTAssertEqual(IpcCodec.encode(.int(0)), [0x06, 0x00])
        XCTAssertEqual(IpcCodec.encode(.int(300)), [0x06, 0xAC, 0x02])
        XCTAssertEqual(IpcCodec.encode(.json("true")), [0x05, 0x04, 0x74, 0x72, 0x75, 0x65])
        XCTAssertEqual(IpcCodec.encode(.json("null")), [0x05, 0x04, 0x6E, 0x75, 0x6C, 0x6C])
        XCTAssertEqual(IpcCodec.encode(.json("3.5")), [0x05, 0x03, 0x33, 0x2E, 0x35])
        XCTAssertEqual(IpcCodec.encode(.array([])), [0x04, 0x00])
        XCTAssertEqual(IpcCodec.encode(.bytes([0xFF])), [0x03, 0x01, 0xFF])
        XCTAssertEqual(IpcCodec.encode(.undefined), [0x00])
    }

    func testIpcValueRoundtrip() throws {
        let values: [IpcValue] = [
            .undefined, .string("你好 zcode"), .string(""), .int(0), .int(1), .int(Int(Int32.max)),
            .bytes([0x00, 0xFF, 0x42]), .array([]),
            .array([.string("a"), .int(7), .array([.int(1)]), .bytes([0x01])]),
            .json("{\"k\":[1,2,{\"n\":true}]}"),
            .object([("workspacePath", .string("/w")), ("sessionId", .string("abc"))]),
        ]
        for v in values {
            let encoded = IpcCodec.encode(v)
            let decoded = try IpcCodec.decode(encoded)
            XCTAssertEqual(decoded, v, "roundtrip \(v)")
        }
    }

    func testUnknownTagRejected() {
        XCTAssertThrowsError(try IpcCodec.decode([0x07]))
    }

    // MARK: - RPC 报文布局(§2.8 三个机器验证示例)

    func testExample1MinimalCall() {
        // serialize([100, 0, "zcode-agent", "ping"]) ++ serialize([])
        let bytes = IpcCodec.encodeRequest(type: 100, id: 0, channel: "zcode-agent", method: "ping", args: [])
        XCTAssertEqual(bytes.count, 27)
        XCTAssertEqual(
            bytes,
            [0x04, 0x04, 0x06, 0x64, 0x06, 0x00,
             0x01, 0x0B] + Array("zcode-agent".utf8) +
            [0x01, 0x04] + Array("ping".utf8) +
            [0x04, 0x00])
        XCTAssertEqual(Data(bytes).base64EncodedString(), "BAQGZAYAAQt6Y29kZS1hZ2VudAEEcGluZwQA")
        XCTAssertEqual(Crc32.hex(Data(bytes)), "0919741f")
    }

    func testExample2ObjectArg() {
        let arg = IpcValue.object([("workspacePath", .string("/w")), ("sessionId", .string("abc"))])
        let bytes = IpcCodec.encodeRequest(
            type: 100, id: 0, channel: "zcode-agent",
            method: "subscribeConversationV4", args: [arg])
        XCTAssertEqual(bytes.count, 88)
        XCTAssertEqual(Crc32.hex(Data(bytes)), "c117de4b")
        XCTAssertEqual(
            Data(bytes).base64EncodedString(),
            "BAQGZAYAAQt6Y29kZS1hZ2VudAEXc3Vic2NyaWJlQ29udmVyc2F0aW9uVjQEAQUoeyJ3b3Jrc3BhY2VQYXRoIjoiL3ciLCJzZXNzaW9uSWQiOiJhYmMifQ==")
        // JSON 文本必须恰为 40 字节(保序写出)
        XCTAssertEqual("{\"workspacePath\":\"/w\",\"sessionId\":\"abc\"}".utf8.count, 40)
    }

    func testExample3EventFrame() {
        // 规格文档示例 3 有笔误:204 的 ULEB128 是 CC 01(两字节),JSON 文本 14 字节,总 23 字节。
        // 此处以正确 ULEB128 语义断言(示例 1/2 金样本已验证编码器逐字节一致)。
        let bytes = IpcCodec.encodeEvent(type: 204, id: 7, arg: .json("{\"delta\":\"hi\"}"))
        XCTAssertEqual(bytes.count, 23)
        XCTAssertEqual(
            bytes,
            [0x04, 0x02, 0x06, 0xCC, 0x01, 0x06, 0x07,
             0x05, 0x0E] + Array("{\"delta\":\"hi\"}".utf8))
        // varint(204) 单独验证
        var w = VarintWriter(); w.writeVarint(204)
        XCTAssertEqual(w.toBytes(), [0xCC, 0x01])
    }

    // MARK: - rpc-frame 传输层

    func testTransportRoundtripSingleFragment() throws {
        let identity = RpcFrameTransport.BridgeIdentity(bridgeSessionId: "bridge-1", bridgeGeneration: 1, recoveryId: "rec-1")
        let sender = RpcFrameTransport(identity: identity)
        let receiver = RpcFrameTransport(identity: identity)
        var delivered: [Data] = []
        receiver.onMessage = { delivered.append($0) }
        var acks: [String] = []
        sender.sendPayload = { text in receiver.acceptPayloadString(text) }
        receiver.sendPayload = { acks.append($0) }

        let message = Data("hello zcode".utf8)
        try sender.sendMessage(message)
        XCTAssertEqual(delivered, [message])
        XCTAssertEqual(acks.count, 1)
        let ackObj = try JSONSerialization.jsonObject(with: Data(acks[0].utf8)) as! [String: Any]
        XCTAssertEqual(ackObj["bridgeSessionId"] as? String, "bridge-1")
        XCTAssertEqual(ackObj["bridgeGeneration"] as? Int, 1)
        XCTAssertEqual(ackObj["recoveryId"] as? String, "rec-1")
        XCTAssertEqual(ackObj["ackMessageSeq"] as? Int, 1)
    }

    func testTransportRoundtripMultiFragment() throws {
        let chunk = 16
        let identity = RpcFrameTransport.BridgeIdentity(bridgeSessionId: "bridge-m", bridgeGeneration: 2)
        let sender = RpcFrameTransport(identity: identity, chunkBytes: chunk)
        let receiver = RpcFrameTransport(identity: identity, chunkBytes: chunk)

        var envelopes: [[String: Any]] = []
        sender.sendPayload = { text in
            envelopes.append(try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any])
        }
        var acks: [String] = []
        var delivered: [Data] = []
        receiver.onMessage = { delivered.append($0) }
        receiver.sendPayload = { acks.append($0) }

        let message = Data((0..<100).map { UInt8($0 & 0xFF) }) // 100 字节 → 7 片
        try sender.sendMessage(message)

        // seq 严格连续 1...7,messageSeq 恒 1
        for (i, env) in envelopes.enumerated() {
            XCTAssertEqual(env["seq"] as? Int, i + 1)
            XCTAssertEqual(env["messageSeq"] as? Int, 1)
            XCTAssertEqual(env["fragmentIndex"] as? Int, i)
            XCTAssertEqual(env["fragmentCount"] as? Int, 7)
            XCTAssertEqual(env["messageBytes"] as? Int, 100)
            XCTAssertEqual(env["bridgeGeneration"] as? Int, 2)
        }
        XCTAssertEqual(envelopes.count, 7)

        // 乱序投递(容忍):先发最后一片
        for env in envelopes.reversed() { receiver.acceptPayload(env) }
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first, message)

        // ack:回带完整身份(含 bridgeGeneration=2),ackMessageSeq=1
        XCTAssertEqual(acks.count, 1)
        let ackObj = try! JSONSerialization.jsonObject(with: Data(acks[0].utf8)) as! [String: Any]
        XCTAssertEqual(ackObj["zcode_type"] as? String, "rpc-frame-ack")
        XCTAssertEqual(ackObj["bridgeSessionId"] as? String, "bridge-m")
        XCTAssertEqual(ackObj["bridgeGeneration"] as? Int, 2)
        XCTAssertNil(ackObj["recoveryId"]) // 身份里没有 recoveryId → ack 也不带
        XCTAssertEqual(ackObj["ackMessageSeq"] as? Int, 1)
    }

    func testIdentityMismatchRejected() throws {
        let identity = RpcFrameTransport.BridgeIdentity(bridgeSessionId: "bridge-a", bridgeGeneration: 1)
        let other = RpcFrameTransport.BridgeIdentity(bridgeSessionId: "bridge-b", bridgeGeneration: 1)
        let sender = RpcFrameTransport(identity: identity, chunkBytes: 1024)
        let receiver = RpcFrameTransport(identity: other, chunkBytes: 1024)
        var delivered: [Data] = []
        receiver.onMessage = { delivered.append($0) }
        sender.sendPayload = { text in
            let obj = try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
            receiver.acceptPayload(obj)
        }
        try sender.sendMessage(Data("x".utf8))
        XCTAssertTrue(delivered.isEmpty)
    }

    func testDegradedStopsTraffic() throws {
        let identity = RpcFrameTransport.BridgeIdentity(bridgeSessionId: "bridge-d")
        let sender = RpcFrameTransport(identity: identity, chunkBytes: 1024)
        let receiver = RpcFrameTransport(identity: identity, chunkBytes: 1024)
        var degradedReasons: [String] = []
        receiver.onDegraded = { degradedReasons.append($0) }
        var deliveredCount = 0
        receiver.onMessage = { _ in deliveredCount += 1 }
        var pending: [[String: Any]] = []
        sender.sendPayload = { text in
            pending.append(try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any])
        }
        try sender.sendMessage(Data("before".utf8))
        for env in pending { receiver.acceptPayload(env) }
        XCTAssertEqual(deliveredCount, 1)

        // degraded 后不再收;协调层会将两端都标记 degraded
        receiver.acceptPayload(["zcode_type": "bridge-degraded", "bridgeSessionId": "bridge-d", "reason": "rpc-frame-gap"])
        XCTAssertEqual(degradedReasons, ["rpc-frame-gap"])
        sender.markDegraded()
        XCTAssertThrowsError(try sender.sendMessage(Data("after".utf8))) // 发送端拒绝
        var more: [[String: Any]] = []
        sender.sendPayload = nil // 已拒绝,不会有新帧
        for env in more { receiver.acceptPayload(env) }
        XCTAssertEqual(deliveredCount, 1)
    }

    func testEmptyMessageRejected() {
        let t = RpcFrameTransport(identity: .init(bridgeSessionId: "b"))
        XCTAssertThrowsError(try t.sendMessage(Data())) { e in
            XCTAssertEqual(e as? RpcFrameTransport.TransportError, .emptyMessage)
        }
    }

    func testSwapBridgeResetsCounters() throws {
        let t = RpcFrameTransport(identity: .init(bridgeSessionId: "b1"), chunkBytes: 8)
        var seqs: [Int] = []
        t.sendPayload = { text in
            let obj = try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
            seqs.append(obj["seq"] as! Int)
        }
        try t.sendMessage(Data(repeating: 0x41, count: 20)) // 3 片: seq 1,2,3
        XCTAssertEqual(seqs, [1, 2, 3])
        t.swapBridge(.init(bridgeSessionId: "b2"))
        seqs.removeAll()
        try t.sendMessage(Data(repeating: 0x42, count: 20))
        XCTAssertEqual(seqs, [1, 2, 3]) // 新桥从 1 重新开始
    }
}

extension RpcFrameTransport {
    /// 测试便捷:直接消费信封文本
    func acceptPayloadString(_ text: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
        acceptPayload(obj)
    }
}
