import SwiftUI

/// 极简主题:跟随系统外观 —— 日间纯白、夜间纯黑,无背景特效。
enum Theme {
    // MARK: 动态基色

    static func dynamic(light: UIColor, dark: UIColor) -> Color {
        Color(UIColor { trait in
            trait.userInterfaceStyle == .dark ? dark : light
        })
    }

    static let bgSolid = dynamic(light: .white, dark: .black)
    static let sidebarBG = dynamic(
        light: UIColor(red: 0.965, green: 0.965, blue: 0.972, alpha: 1),
        dark: UIColor(white: 0.055, alpha: 1))
    static let inputFill = dynamic(
        light: UIColor(white: 0, alpha: 0.055),
        dark: UIColor(white: 1, alpha: 0.075))

    static let cardFill = dynamic(
        light: UIColor(white: 0, alpha: 0.045),
        dark: UIColor(white: 1, alpha: 0.055))
    static let cardFillStrong = dynamic(
        light: UIColor(white: 0, alpha: 0.06),
        dark: UIColor(white: 1, alpha: 0.085))
    static let cardStroke = dynamic(
        light: UIColor(white: 0, alpha: 0.09),
        dark: UIColor(white: 1, alpha: 0.09))

    /// 主按钮/发送键的反色填充(浅色模式黑底白字,深色模式白底黑字)
    static let accentFill = dynamic(light: .black, dark: .white)
    static let onAccent = dynamic(light: .white, dark: .black)

    // 语义色(两种模式通用)
    static let mint = Color(red: 0.18, green: 0.72, blue: 0.44)
    static let amber = Color(red: 0.96, green: 0.63, blue: 0.11)
    static let azure = Color(red: 0.16, green: 0.47, blue: 0.90)
    static let coral = Color(red: 0.93, green: 0.33, blue: 0.30)

    static let textPrimary = dynamic(light: UIColor(white: 0.07, alpha: 1),
                                     dark: UIColor(white: 0.94, alpha: 1))
    static let textSecondary = dynamic(light: UIColor(white: 0.42, alpha: 1),
                                       dark: UIColor(white: 0.64, alpha: 1))
    static let textTertiary = dynamic(light: UIColor(white: 0.58, alpha: 1),
                                      dark: UIColor(white: 0.42, alpha: 1))

    static func background() -> some View {
        bgSolid
    }
}

// MARK: - 品牌标志

struct ZMark: View {
    var size: CGFloat = 34
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(Theme.accentFill)
            Text("Z")
                .font(.system(size: size * 0.62, weight: .black))
                .foregroundStyle(Theme.onAccent)
                .offset(y: -size * 0.02)
        }
        .frame(width: size, height: size)
    }
}

/// 状态点(带呼吸光晕)
struct StatusDot: View {
    var color: Color
    var pulsing: Bool = false
    @State private var phase: CGFloat = 0

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(color.opacity(0.5), lineWidth: 1)
                    .scaleEffect(1 + phase * 2.2)
                    .opacity(pulsing ? 1 - phase : 0)
            )
            .onAppear {
                guard pulsing else { return }
                withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

// MARK: - 通用控件

struct GlassCard<Content: View>: View {
    var padding: CGFloat = 18
    var cornerRadius: CGFloat = 22
    var strong: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(strong ? Theme.cardFillStrong : Theme.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 1)
            )
    }
}

struct CircleIconButton: View {
    var systemName: String
    var size: CGFloat = 44
    var tint: Color = Theme.textPrimary
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(Circle().fill(Theme.cardFill))
                .overlay(Circle().strokeBorder(Theme.cardStroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct PillBadge: View {
    var text: String
    var tint: Color = Theme.textSecondary
    var filled: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(filled ? Theme.onAccent : tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(filled ? tint : Theme.cardFill)
            )
            .overlay(filled ? nil : Capsule().strokeBorder(Theme.cardStroke, lineWidth: 1))
    }
}

/// 大圆角主按钮
struct PrimaryActionButton: View {
    var title: String
    var systemName: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemName)
                    .font(.system(size: 16, weight: .semibold))
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundStyle(Theme.accentFill)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.cardFillStrong)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 1)
            )
        }
        .buttonStyle(bouncy())
    }
}

/// 轻弹性按钮样式
struct bouncy: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

extension View {
    var bouncyButtonStyle: some View { buttonStyle(bouncy()) }
}
