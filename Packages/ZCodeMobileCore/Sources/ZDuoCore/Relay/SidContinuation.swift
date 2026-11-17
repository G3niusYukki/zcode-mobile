import Foundation

/// SID 自动接续(官方 2026-10-27 语义,规格 §8.5)。
/// 桌面每次重启/重登产生新 device_sid(MID 不变),中继不做 old→new 映射;
/// 终端在可接续失败(AUTH_FAILED / DESKTOP_DISCONNECTED)后,用 JWT 查一次设备列表,
/// 以失败 SID 的 MID 求落点。
public enum SidContinuation {

    public enum Outcome: Equatable {
        /// 旧 SID 仍在线(失败是暂时的)→ 沿用旧 SID 重建连接
        case keepCurrent
        /// 同 MID 恰好 1 个其他在线 SID → 切换到新 SID 并更新本地设备记录
        case switchTo(deviceSid: String, deviceName: String?)
        /// 0 个 / ≥2 个(歧义)/ MID 缺失 → 无法自动接续,交回用户(重新扫码)
        case none
    }

    public static func resolve(failedSid: String, failedMid: String?,
                               devices: [V2AccountApi.RemoteDevice]) -> Outcome {
        guard let failedMid, !failedMid.isEmpty else { return .none }
        let sameMid = devices.filter { $0.deviceMid == failedMid }

        // 旧 SID 仍在该 MID 的在线集合 → KeepCurrent
        if let old = sameMid.first(where: { $0.deviceSid == failedSid }), old.online {
            return .keepCurrent
        }
        // 同 MID 其他在线 SID 恰好 1 个 → Switch
        let otherOnline = sameMid.filter { $0.deviceSid != failedSid && $0.online }
        if otherOnline.count == 1, let target = otherOnline.first {
            return .switchTo(deviceSid: target.deviceSid, deviceName: target.name)
        }
        return .none
    }
}
