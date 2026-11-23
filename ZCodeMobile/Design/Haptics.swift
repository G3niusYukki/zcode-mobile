import SwiftUI
import UIKit

/// 统一触感反馈引擎(遵循用户在设置中的「触感反馈」开关)
@MainActor
enum Haptics {
    private static let enabledKey = "zcode-mobile.hapticsEnabled"

    static var isEnabled: Bool {
        if UserDefaults.standard.object(forKey: enabledKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: enabledKey)
    }

    static func selection() {
        guard isEnabled else { return }
        let gen = UISelectionFeedbackGenerator()
        gen.prepare()
        gen.selectionChanged()
    }

    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light, intensity: CGFloat = 0.85) {
        guard isEnabled else { return }
        let gen = UIImpactFeedbackGenerator(style: style)
        gen.prepare()
        gen.impactOccurred(intensity: intensity)
    }

    static func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        guard isEnabled else { return }
        let gen = UINotificationFeedbackGenerator()
        gen.prepare()
        gen.notificationOccurred(type)
    }

    static func light() { impact(.light, intensity: 0.75) }
    static func soft() { impact(.soft, intensity: 0.7) }
    static func medium() { impact(.medium, intensity: 0.9) }
    static func rigid() { impact(.rigid, intensity: 0.85) }
    static func success() { notification(.success) }
    static func warning() { notification(.warning) }
    static func error() { notification(.error) }
}
