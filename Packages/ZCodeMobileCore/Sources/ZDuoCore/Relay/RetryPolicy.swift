import Foundation

/// V2 重连退避策略 —— 官方 WebRemoteControlV2RetryPolicy 纯函数复刻(规格 §7.3)。
/// random/now 注入,便于单测。
public struct RetryPolicy {
    public static let spreadMs: Double = 1_500
    public static let initialMs: Double = 500
    public static let maxBackoffMs: Double = 10_000
    public static let jitter = 0.2
    public static let kickedWindowMs: Double = 60_000
    public static let kickedMinMs: Double = 2_000
    public static let kickedMaxMs: Double = 5_000

    public var failures = 0
    public var spreadNext = false
    public var lastKickAtMs: Double = 0

    private let random: () -> Double  // [0,1)
    private let nowMs: () -> Double

    public init(random: @escaping () -> Double = { Double.random(in: 0..<1) },
                nowMs: @escaping () -> Double = { Date().timeIntervalSince1970 * 1000 }) {
        self.random = random
        self.nowMs = nowMs
    }

    /// 下一次重连延迟(ms)。退避 500ms×2ⁿ ±20% 封顶 10s;连接建立后的首次重连 0~1.5s 全窗打散。
    public mutating func nextDelay() -> Double {
        if spreadNext {
            spreadNext = false
            return random() * Self.spreadMs
        }
        let exponent = min(Double(failures), 16)
        failures += 1
        let base = min(Self.maxBackoffMs, Self.initialMs * pow(2, exponent))
        let jittered = base * (1 - Self.jitter + random() * Self.jitter * 2)
        return min(Self.maxBackoffMs, jittered.rounded())
    }

    /// pair_status=matched 时调用:清退避 + 标记下次打散;不清 KICKED 窗口。
    public mutating func acknowledged() {
        failures = 0
        spreadNext = true
    }

    /// 用户显式连接(扫码/手动重连):清退避,不打散。
    public mutating func reset() {
        failures = 0
        spreadNext = false
    }

    /// KICKED 处理:首次 2~5s 随机重连自愈;60s 内第二次返回 nil ⇒ 调用方进 KICKED 终态。
    public mutating func kickedDelay() -> Double? {
        let now = nowMs()
        if lastKickAtMs != 0, now - lastKickAtMs < Self.kickedWindowMs { return nil }
        lastKickAtMs = now
        return Self.kickedMinMs + random() * (Self.kickedMaxMs - Self.kickedMinMs)
    }
}
