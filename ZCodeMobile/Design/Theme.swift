import SwiftUI

/// ZCodeMobile 设计系统:深蓝夜航 + 玻璃卡片 + 点阵世界底纹(对齐 whaleness 质感)
enum Theme {
    // 品牌/背景
    static let bgTop = Color(red: 0.035, green: 0.070, blue: 0.130)
    static let bgMid = Color(red: 0.043, green: 0.118, blue: 0.208)
    static let bgBottom = Color(red: 0.020, green: 0.043, blue: 0.078)
    static let glow = Color(red: 0.16, green: 0.42, blue: 0.72)

    // 玻璃
    static let cardFill = Color.white.opacity(0.055)
    static let cardFillStrong = Color.white.opacity(0.085)
    static let cardStroke = Color.white.opacity(0.09)

    // 语义色
    static let mint = Color(red: 0.35, green: 0.85, blue: 0.64)
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.30)
    static let azure = Color(red: 0.38, green: 0.66, blue: 1.0)
    static let coral = Color(red: 1.0, green: 0.45, blue: 0.42)

    static let textPrimary = Color.white.opacity(0.94)
    static let textSecondary = Color.white.opacity(0.64)
    static let textTertiary = Color.white.opacity(0.42)

    static func background() -> some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.025, green: 0.09, blue: 0.17),
                                    Color(red: 0.02, green: 0.06, blue: 0.12),
                                    Color.black.opacity(0.92)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            // 中央光晕
            RadialGradient(colors: [glow.opacity(0.22), .clear],
                           center: .init(x: 0.32, y: 0.22),
                           startRadius: 40, endRadius: 520)
                .blur(radius: 30)
            // 点阵世界地图底纹(圆形遮罩)
            DotField()
                .opacity(0.30)
                .mask(
                    RadialGradient(colors: [.white.opacity(0.9), .clear],
                                   center: .init(x: 0.42, y: 0.40),
                                   startRadius: 60, endRadius: 620)
                )
        }
        .ignoresSafeArea()
    }
}

/// 点阵底纹:细密网格点,边缘渐隐
struct DotField: View {
    var spacing: CGFloat = 26
    var radius: CGFloat = 0.8

    var body: some View {
        Canvas { context, size in
            let color = Color.white.opacity(0.10)
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = 0
                while x < size.width {
                    // 轻微打散,避免机械化
                    let jitterX = (sin(x * 0.7 + y) * 0.8)
                    let jitterY = (cos(y * 0.9 + x) * 0.8)
                    let rect = CGRect(x: x + jitterX, y: y + jitterY, width: radius * 2, height: radius * 2)
                    context.fill(Path(ellipseIn: rect), with: .color(color))
                    x += spacing
                }
                y += spacing
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 玻璃卡片

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
                    .background(.ultraThinMaterial.opacity(0.25), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.22), radius: 18, y: 10)
    }
}

// MARK: - 品牌标志

struct ZMark: View {
    var size: CGFloat = 34
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(.white)
            Text("Z")
                .font(.system(size: size * 0.62, weight: .black))
                .foregroundStyle(.black)
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
                .background(Circle().fill(Color.white.opacity(0.08)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
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
            .foregroundStyle(filled ? .black : tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(filled ? tint : Color.white.opacity(0.08))
            )
            .overlay(filled ? nil : Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
    }
}

/// 大圆角主按钮(新建会话)
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
            .foregroundStyle(Theme.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.azure.opacity(0.16))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Theme.azure.opacity(0.45), lineWidth: 1)
            )
        }
        .buttonStyle(bouncy())
    }
}

/// 轻弹性按钮样式(动效)
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
