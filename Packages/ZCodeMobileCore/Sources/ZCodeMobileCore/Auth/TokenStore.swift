import Foundation
import Security

/// JWT 的 Keychain 持久化 + `exp` 读取。
/// 官方无 refresh token:过期(读 exp)即清态重登。
public final class TokenStore: @unchecked Sendable {
    public static let shared = TokenStore()

    private let service: String
    private let account = "zcodejwttoken"
    private let lock = NSLock()

    public init(service: String = "dev.workspace-a.zcode-mobile") {
        self.service = service
    }

    // MARK: - Keychain CRUD

    public func saveJWT(_ token: String) {
        lock.lock(); defer { lock.unlock() }
        let data = Data(token.utf8)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }

    public func loadJWT() -> String? {
        lock.lock(); defer { lock.unlock() }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func deleteJWT() {
        lock.lock(); defer { lock.unlock() }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - JWT exp

    /// 解析 JWT payload 的 exp(秒)。解析失败(非三段式/无 exp)返回 nil。
    public static func jwtExpiry(_ jwt: String) -> Date? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = payload["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    /// 过期判断。exp 无法解析时**不**判过期(交给服务端 401 裁决),
    /// 避免非常规 JWT 格式导致登录态收割永远被拦截。
    public static func isExpired(_ jwt: String, now: Date = Date()) -> Bool {
        guard let expiry = jwtExpiry(jwt) else { return false }
        return now >= expiry
    }

    /// 取有效 JWT;不存在或已过期返回 nil(调用方引导重登)
    public func validJWT(now: Date = Date()) -> String? {
        guard let jwt = loadJWT() else { return nil }
        if Self.isExpired(jwt, now: now) {
            deleteJWT()
            return nil
        }
        return jwt
    }
}
