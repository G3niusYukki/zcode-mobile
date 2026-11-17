import Foundation

/// 账号侧 REST(/api/v1/remote/*)。统一信封 {code,msg,data,logid}。
/// 鉴权失败(HTTP 401/403 或业务码拒绝)必须与网络错误区分 —— 真机教训 T10。
public actor V2AccountApi {
    public enum ApiError: Error, Equatable {
        case authFailed(String)     // JWT 失效 → 终态,引导重登
        case rejected(String)       // 业务拒绝(code != 0)
        case network(String)        // DNS/超时/重置 → 可重试
    }

    public struct RelayToken: Equatable, Sendable {
        public let token: String
        public let expiresIn: Int
    }

    public struct RemoteDevice: Equatable, Sendable {
        public let deviceSid: String
        public let deviceMid: String?
        public let online: Bool
        public let createdAt: Double?
        public let name: String?
        public let platform: String?
        public let version: String?

        init(dict: [String: Any]) {
            deviceSid = dict["device_sid"] as? String ?? ""
            deviceMid = dict["device_mid"] as? String
            online = dict["online"] as? Bool ?? false
            createdAt = dict["created_at"] as? Double
            let meta = dict["meta"] as? [String: Any]
            name = meta?["name"] as? String
            platform = meta?["platform"] as? String
            version = meta?["version"] as? String
        }
    }

    private let session: URLSession
    private var inFlightTokens: [String: Task<RelayToken, Error>] = [:]

    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - POST /api/v1/remote/token

    /// JWT 换 relay token(60s 短时效,不缓存;单飞:并发共享一次往返)
    public func fetchRelayToken(origin: String, jwt: String, role: String = "terminal") async throws -> RelayToken {
        let key = "\(origin)|\(role)|\(jwt.suffix(16))"
        if let existing = inFlightTokens[key] {
            return try await existing.value
        }
        let task = Task<RelayToken, Error> { [origin, jwt, role] in
            let body = try JSONSerialization.data(withJSONObject: ["role": role])
            let envelope: [String: Any] = try await self.request(
                method: "POST", url: "\(origin)/api/v1/remote/token", jwt: jwt, body: body)
            guard let data = envelope["data"] as? [String: Any],
                  let token = data["token"] as? String, !token.isEmpty else {
                throw ApiError.rejected(envelope["msg"] as? String ?? "token response missing data")
            }
            return RelayToken(token: token, expiresIn: data["expires_in"] as? Int ?? 60)
        }
        inFlightTokens[key] = task
        defer { inFlightTokens[key] = nil }
        return try await task.value
    }

    // MARK: - 计费/配额(coding plan)

    /// 拉取套餐计费信息(含用量与重置时间)。合并 current + balance 两个端点。
    public func fetchBilling(origin: String, jwt: String) async throws -> [String: Any]? {
        let endpoints = [
            ("current", "\(origin)/api/v1/zcode-plan/billing/current"),
            ("balance", "\(origin)/api/v1/zcode-plan/billing/balance"),
        ]
        var merged: [String: Any] = [:]
        for (name, url) in endpoints {
            do {
                let envelope = try await request(method: "GET", url: url, jwt: jwt, body: nil)
                if let data = envelope["data"] as? [String: Any] {
                    if let raw = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]),
                       let text = String(data: raw, encoding: .utf8) {
                        ZDlog("[ZCodeMobile][billing] %@ → %@", name, String(text.prefix(600)))
                    }
                    for (k, v) in data { merged[k] = v }
                }
            } catch {
                ZDlog("[ZCodeMobile][billing] %@ failed: %@", name, String(describing: error))
            }
        }
        return merged.isEmpty ? nil : merged
    }

    // MARK: - GET /api/v1/remote/device

    /// 账号绑定设备列表(data 为数组或 {"devices":[...]} 包裹,两种都解析)
    public func listDevices(origin: String, jwt: String) async throws -> [RemoteDevice] {
        let envelope = try await request(method: "GET", url: "\(origin)/api/v1/remote/device", jwt: jwt, body: nil)
        let data = envelope["data"]
        let rawDevices: [[String: Any]]
        if let array = data as? [[String: Any]] {
            rawDevices = array
        } else if let wrapped = data as? [String: Any], let array = wrapped["devices"] as? [[String: Any]] {
            rawDevices = array
        } else {
            rawDevices = []
        }
        return rawDevices.map(RemoteDevice.init(dict:))
    }

    // MARK: - 通用请求

    private func request(method: String, url: String, jwt: String, body: Data?) async throws -> [String: Any] {
        guard let requestURL = URL(string: url) else { throw ApiError.network("bad url") }
        var request = URLRequest(url: requestURL, timeoutInterval: 15)
        request.httpMethod = method
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ApiError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ApiError.network("no http response")
        }
        // 鉴权失败分类(401/403 → authFailed 终态)
        if http.statusCode == 401 || http.statusCode == 403 {
            throw ApiError.authFailed("HTTP \(http.statusCode)")
        }
        guard 200..<300 ~= http.statusCode else {
            throw ApiError.network("HTTP \(http.statusCode)")
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ApiError.network("invalid json")
        }
        let code = obj["code"] as? Int ?? -1
        if code != 0 {
            let msg = obj["msg"] as? String ?? "code=\(code)"
            // 业务码拒绝中的鉴权类也归 authFailed
            if msg.lowercased().contains("unauthorized") || msg.lowercased().contains("token") {
                throw ApiError.authFailed(msg)
            }
            throw ApiError.rejected(msg)
        }
        return obj
    }
}
