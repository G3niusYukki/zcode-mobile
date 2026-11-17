import Foundation

/// 中继帧构造/校验纯函数。⚠️ 最易错点:client_ts 在 auth/pair 帧是**秒**,data 信封是**毫秒**。
public enum RelayProtocol {

    public struct TerminalMeta: Equatable, Sendable {
        public let platform: String
        public let version: String
        public let name: String
        public init(platform: String, version: String, name: String) {
            self.platform = platform
            self.version = version
            self.name = name
        }
    }

    /// V2 auth_init(无 role、无 proof;device_sid = PC 的 sid;client_ts 秒)
    public static func authInit(deviceSid: String, meta: TerminalMeta, now: Date = Date()) -> String {
        let ts = Int(now.timeIntervalSince1970) // 秒!毫秒会超 zod 上限被拒
        return "{\"type\":\"auth_init\",\"device_sid\":\(jsonEscaped(deviceSid)),\"meta\":{\"platform\":\(jsonEscaped(meta.platform)),\"version\":\(jsonEscaped(meta.version)),\"name\":\(jsonEscaped(meta.name))},\"client_ts\":\(ts)}"
    }

    /// pair_status_query 心跳(client_ts 秒,无 device_sid —— strictObject 拒多余字段)
    public static func heartbeat(now: Date = Date()) -> String {
        let ts = Int(now.timeIntervalSince1970)
        return "{\"type\":\"pair_status_query\",\"client_ts\":\(ts)}"
    }

    /// data 信封(client_ts 毫秒)—— 唯一出站业务形态
    public static func dataEnvelope(payloadJSON: String, now: Date = Date()) -> String {
        let ts = Int(now.timeIntervalSince1970 * 1000)
        return "{\"type\":\"data\",\"payload\":\(payloadJSON),\"client_ts\":\(ts)}"
    }

    /// wss://<origin>/api/v1/remote/ws2?token=..&mid=..
    public static func v2RelayWsUrl(origin: String, token: String, mid: String?) -> URL? {
        var components = URLComponents(string: origin)
        guard let scheme = components?.scheme, let host = components?.host else { return nil }
        components?.scheme = (scheme == "http") ? "ws" : "wss"
        components?.host = host
        components?.path = "/api/v1/remote/ws2"
        // 手动百分号编码(URLQueryItem 不编码 '+',token 需要严格编码)
        func enc(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? s
        }
        var query = "token=\(enc(token))"
        if let mid, !mid.isEmpty { query += "&mid=\(enc(mid))" }
        components?.percentEncodedQuery = query
        return components?.url
    }

    /// Origin 头:wss://host/... → https://host(必带,缺失即 AUTH_FAILED)
    public static func originHeader(forWsUrl url: URL) -> String {
        let scheme = url.scheme == "ws" ? "http" : "https"
        var s = "\(scheme)://\(url.host ?? "")"
        if let port = url.port { s += ":\(port)" }
        return s
    }

    /// WS 端点结构化校验(Release 只放行 wss;ws 仅 debug 放行)
    public static func validateEndpoint(_ url: URL, allowInsecureWS: Bool = false) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "wss" { /* ok */ }
        else if scheme == "ws" { if !allowInsecureWS { return false } }
        else { return false }
        guard let host = url.host, !host.isEmpty else { return false }
        if url.user != nil || url.password != nil { return false }
        if let port = url.port, !(1...65535).contains(port) { return false }
        return true
    }

    static func jsonEscaped(_ s: String) -> String {
        IpcCodec.jsonEscaped(s)
    }
}

/// 中继入站帧的轻量模型
public enum RelayInbound {
    case authAck(deviceSid: String?, terminalSid: String?, pairStatus: String?, serverTs: Double?)
    case pairStatusAck(pairStatus: String?)
    case data(payload: [String: Any])
    case error(code: String, message: String?)
    case challenge   // V2 不存在,收到即协议错乱
    case unknown(type: String?)

    public static func parse(_ text: String) -> RelayInbound {
        guard let data = text.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["type"] as? String else {
            return .unknown(type: nil)
        }
        switch type {
        case "auth_ack":
            let payload = obj["payload"] as? [String: Any]
            let source = payload ?? obj
            return .authAck(
                deviceSid: source["device_sid"] as? String,
                terminalSid: source["terminal_sid"] as? String,
                pairStatus: source["pair_status"] as? String,
                serverTs: source["server_ts"] as? Double)
        case "pair_status_ack":
            let payload = obj["payload"] as? [String: Any]
            let source = payload ?? obj
            return .pairStatusAck(pairStatus: source["pair_status"] as? String)
        case "data":
            let payload = obj["payload"] as? [String: Any] ?? [:]
            return .data(payload: payload)
        case "error":
            let payload = obj["payload"] as? [String: Any]
            let source = payload ?? obj
            return .error(code: source["code"] as? String ?? "UNKNOWN", message: source["message"] as? String)
        case "auth_challenge":
            return .challenge
        default:
            return .unknown(type: type)
        }
    }
}
