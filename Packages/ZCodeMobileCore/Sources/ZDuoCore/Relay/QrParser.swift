import Foundation

/// 配对设备模型(V2-only)。二维码 payload:
/// `https://zcode.z.ai/remote/v4?sid=<deviceSid>&mid=<mid>&name=<PC名>&app_version=<版本>`
public struct PairedDevice: Codable, Equatable, Sendable {
    public let deviceSid: String          // "d_..." — PC 的 sid
    public let passHash: String?          // V2 恒 nil;非 nil ⇒ V1(不支持)
    public let deviceMid: String?         // PC 机器 ID,WS query 参数 + SID 接续键
    public let deviceName: String?
    public let remoteUrl: String          // 去 query 的 base,如 https://zcode.z.ai/remote/v4
    public let appVersion: String?        // QR 的 app_version(官方页按它选 Web bundle 版本,不能丢)
    public let sourceUrl: String?         // 原始扫码 URL(去 fragment)—— 登录落地页优先逐字节复用

    public var origin: String { URL(string: remoteUrl)?.originString ?? "https://zcode.z.ai" }

    public init(deviceSid: String, passHash: String? = nil, deviceMid: String?,
                deviceName: String?, remoteUrl: String,
                appVersion: String? = nil, sourceUrl: String? = nil) {
        self.deviceSid = deviceSid
        self.passHash = passHash
        self.deviceMid = deviceMid
        self.deviceName = deviceName
        self.remoteUrl = remoteUrl
        self.appVersion = appVersion
        self.sourceUrl = sourceUrl
    }

    public var isV2: Bool { passHash == nil || passHash!.isEmpty }

    /// 登录落地页(WebView 收割方案入口)。
    /// 优先逐字节复用扫码 URL;重建时必须带全 sid/mid/name/app_version 四参,
    /// 缺 app_version 官方页直接判「Missing or invalid relay parameters」。
    public var landingUrl: String {
        if let source = sourceUrl, URL(string: source) != nil {
            return source
        }
        var parts = URLComponents(string: remoteUrl) ?? URLComponents(string: "https://zcode.z.ai/remote/v4")!
        var query: [URLQueryItem] = []
        query.append(URLQueryItem(name: "sid", value: deviceSid))
        if let mid = deviceMid, !mid.isEmpty { query.append(URLQueryItem(name: "mid", value: mid)) }
        if let name = deviceName, !name.isEmpty {
            query.append(URLQueryItem(name: "name", value: name)) // 空格编码 %20,官方同语义
        }
        if let version = appVersion, !version.isEmpty {
            query.append(URLQueryItem(name: "app_version", value: version))
        }
        parts.queryItems = query
        return parts.url?.absoluteString ?? remoteUrl
    }
}

public enum QrParseError: Error, Equatable {
    case invalidURL
    case missingSid
    case v1NotSupported      // 带 hash 的 V1 二维码:请升级桌面端
}

public enum QrParser {
    /// 解析二维码内容/粘贴的连接地址。V2-only(hash 非空即拒)。
    public static func parse(_ raw: String) throws -> PairedDevice {
        // 字面 '+' 预转义为 %2B'(官方 URLSearchParams 生成端同语义)
        let preprocessed = raw.replacingOccurrences(of: "+", with: "%2B")
        guard let url = URL(string: preprocessed.trimmingCharacters(in: .whitespacesAndNewlines)),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw QrParseError.invalidURL
        }
        guard url.scheme == "http" || url.scheme == "https", let host = url.host else {
            throw QrParseError.invalidURL
        }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value
        }
        guard let sid = value("sid"), !sid.isEmpty else { throw QrParseError.missingSid }
        let hash = value("hash") ?? ""
        guard hash.isEmpty else { throw QrParseError.v1NotSupported }

        var base = components
        base.queryItems = nil
        base.fragment = nil
        let remoteUrl = base.url?.absoluteString ?? "https://\(host)/remote/v4"

        // 原始 URL(去 fragment)作为落地页首选 —— 与官方 QR 参数逐字节一致
        var sourceComponents = components
        sourceComponents.fragment = nil
        let sourceUrl = sourceComponents.url?.absoluteString

        return PairedDevice(
            deviceSid: sid,
            passHash: nil,
            deviceMid: value("mid"),
            deviceName: value("name"),
            remoteUrl: remoteUrl,
            appVersion: value("app_version"),
            sourceUrl: sourceUrl
        )
    }
}

extension URL {
    /// https://host(:port) 形式
    var originString: String {
        var s = "\(scheme ?? "https")://\(host ?? "zcode.z.ai")"
        if let port = port { s += ":\(port)" }
        return s
    }
}
