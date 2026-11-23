import SwiftUI

// MARK: - 外观偏好模型

enum AppAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.stars.fill"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum GlassBackdropStyle: String, CaseIterable, Identifiable {
    case aurora
    case minimal

    var id: String { rawValue }

    var label: String {
        switch self {
        case .aurora: return "极光毛玻璃"
        case .minimal: return "极简毛玻璃"
        }
    }
}

enum DuoLayoutPreference: String, CaseIterable, Identifiable {
    case adaptive
    case focus

    var id: String { rawValue }

    var label: String {
        switch self {
        case .adaptive: return "自适应分栏"
        case .focus: return "专注会话优先"
        }
    }
}

// MARK: - 动效曲线规范

enum Motion {
    /// 轻快响应:按钮、chip 切换、展开收起
    static let snappy = Animation.spring(response: 0.26, dampingFraction: 0.78)
    /// 顺滑过渡:面板、页面切入、选中指示器滑移
    static let smooth = Animation.spring(response: 0.36, dampingFraction: 0.86)
    /// 微弹反馈:图标弹跳、发送按钮出现、气泡浮入
    static let bouncy = Animation.spring(response: 0.42, dampingFraction: 0.68)
    /// 舒缓渐进:首屏入场、进度条填充
    static let gentle = Animation.spring(response: 0.56, dampingFraction: 0.88)
}

// MARK: - 主题色板

/// 自适应毛玻璃设计系统:兼顾日间通透光感与夜间深邃玻璃层次。
enum Theme {
    // MARK: 动态基色

    static func dynamic(light: UIColor, dark: UIColor) -> Color {
        Color(UIColor { trait in
            trait.userInterfaceStyle == .dark ? dark : light
        })
    }

    static let bgSolid = dynamic(
        light: UIColor(red: 0.962, green: 0.969, blue: 0.986, alpha: 1),
        dark: UIColor(red: 0.025, green: 0.030, blue: 0.045, alpha: 1)
    )
    static let sidebarBG = dynamic(
        light: UIColor(white: 1.0, alpha: 0.45),
        dark: UIColor(white: 0.06, alpha: 0.42)
    )
    static let inputFill = dynamic(
        light: UIColor(white: 1.0, alpha: 0.62),
        dark: UIColor(white: 1.0, alpha: 0.075)
    )

    static let cardFill = dynamic(
        light: UIColor(white: 1.0, alpha: 0.54),
        dark: UIColor(white: 1.0, alpha: 0.055)
    )
    static let cardFillStrong = dynamic(
        light: UIColor(white: 1.0, alpha: 0.72),
        dark: UIColor(white: 1.0, alpha: 0.088)
    )
    static let cardStroke = dynamic(
        light: UIColor(white: 0.0, alpha: 0.085),
        dark: UIColor(white: 1.0, alpha: 0.115)
    )
    static let hairline = dynamic(
        light: UIColor(white: 0.0, alpha: 0.075),
        dark: UIColor(white: 1.0, alpha: 0.085)
    )
    static let glassHighlightTop = dynamic(
        light: UIColor(white: 1.0, alpha: 0.92),
        dark: UIColor(white: 1.0, alpha: 0.24)
    )
    static let glassHighlightBottom = dynamic(
        light: UIColor(white: 0.0, alpha: 0.06),
        dark: UIColor(white: 1.0, alpha: 0.04)
    )
    static let shadowColor = dynamic(
        light: UIColor(red: 0.08, green: 0.14, blue: 0.28, alpha: 0.08),
        dark: UIColor(white: 0.0, alpha: 0.42)
    )

    /// 主按钮/发送键的反色填充(浅色模式深墨黑底白字,深色模式纯白底黑字)
    static let accentFill = dynamic(
        light: UIColor(red: 0.08, green: 0.09, blue: 0.13, alpha: 1),
        dark: UIColor(white: 0.97, alpha: 1)
    )
    static let onAccent = dynamic(
        light: .white,
        dark: UIColor(red: 0.05, green: 0.06, blue: 0.09, alpha: 1)
    )

    // 语义色(两种模式通用)
    static let mint = Color(red: 0.14, green: 0.74, blue: 0.48)
    static let amber = Color(red: 0.96, green: 0.62, blue: 0.12)
    static let azure = Color(red: 0.17, green: 0.49, blue: 0.96)
    static let indigo = Color(red: 0.44, green: 0.40, blue: 0.94)
    static let coral = Color(red: 0.94, green: 0.34, blue: 0.32)

    static let textPrimary = dynamic(
        light: UIColor(red: 0.07, green: 0.08, blue: 0.12, alpha: 1),
        dark: UIColor(red: 0.95, green: 0.96, blue: 0.98, alpha: 1)
    )
    static let textSecondary = dynamic(
        light: UIColor(red: 0.34, green: 0.38, blue: 0.46, alpha: 1),
        dark: UIColor(red: 0.66, green: 0.70, blue: 0.77, alpha: 1)
    )
    static let textTertiary = dynamic(
        light: UIColor(red: 0.52, green: 0.56, blue: 0.64, alpha: 1),
        dark: UIColor(red: 0.45, green: 0.49, blue: 0.56, alpha: 1)
    )

    static var specularBorderGradient: LinearGradient {
        LinearGradient(
            colors: [glassHighlightTop, cardStroke, glassHighlightBottom],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static func background(breathing: Bool = true) -> some View {
        AmbientBackground(breathing: breathing)
    }
}

// MARK: - 毛玻璃与 Liquid Glass 修饰符

extension View {
    /// 列表与内容卡片级轻量化玻璃表面:
    /// 默认不叠加实时 GPU Material 离屏模糊(避免滚动掉帧),用通透半透明着色 + 镜面高光描边 + 轻柔投影实现满帧 120Hz 玻璃质感;
    /// 仅在需要悬浮遮挡内容(如弹出上下文面板/错误浮卡)时传 `liveBlur: true` 启用真 Material 模糊。
    func frostedSurface<S: InsettableShape>(
        in shape: S,
        strong: Bool = false,
        tint: Color? = nil,
        shadowRadius: CGFloat = 0,
        liveBlur: Bool = false
    ) -> some View {
        self
            .background {
                ZStack {
                    if liveBlur {
                        shape.fill(strong ? Material.regularMaterial : Material.ultraThinMaterial)
                    }
                    shape.fill(strong ? Theme.cardFillStrong : Theme.cardFill)
                    if let tint {
                        shape.fill(tint)
                    }
                }
            }
            .overlay {
                shape.strokeBorder(Theme.specularBorderGradient, lineWidth: 0.85)
            }
            .shadow(color: shadowRadius > 0 ? Theme.shadowColor : .clear,
                    radius: shadowRadius, x: 0, y: shadowRadius * 0.4)
    }

    /// iOS 26 原生 Liquid Glass 悬浮控件修饰符
    func liquidGlassChrome<S: Shape>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        let base: Glass = {
            var g = Glass.regular
            if let tint { g = g.tint(tint) }
            if interactive { g = g.interactive(true) }
            return g
        }()
        return self.glassEffect(base, in: shape)
    }

    /// 兼容旧调用的轻弹性按钮样式
    var bouncyButtonStyle: some View { buttonStyle(bouncy()) }
}

// MARK: - 品牌标志

struct ZMark: View {
    var size: CGFloat = 34
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: scheme == .dark
                            ? [Color.white, Color(white: 0.86)]
                            : [Color(red: 0.14, green: 0.16, blue: 0.22), Color(red: 0.05, green: 0.06, blue: 0.10)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(scheme == .dark ? 0.8 : 0.32), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
            Text("Z")
                .font(.system(size: size * 0.60, weight: .black, design: .rounded))
                .foregroundStyle(Theme.onAccent)
                .offset(y: -size * 0.02)
        }
        .frame(width: size, height: size)
        .shadow(color: Theme.shadowColor, radius: size * 0.22, y: size * 0.1)
    }
}

/// 状态点(动态响应 pulsing 状态切换 + 柔和光晕呼吸)
struct StatusDot: View {
    var color: Color
    var pulsing: Bool = false
    var size: CGFloat = 8
    @State private var phase: CGFloat = 0

    var body: some View {
        ZStack {
            if pulsing {
                Circle()
                    .fill(color.opacity(0.28))
                    .frame(width: size * 1.4, height: size * 1.4)
                    .scaleEffect(1 + phase * 1.55)
                    .opacity(Double(1 - phase))
            }
            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .shadow(color: color.opacity(pulsing ? 0.55 : 0.25), radius: pulsing ? 4 : 2)
        }
        .frame(width: size * 1.6, height: size * 1.6)
        .onAppear { syncPulse(pulsing) }
        .onChange(of: pulsing) { _, next in syncPulse(next) }
    }

    private func syncPulse(_ active: Bool) {
        if active {
            phase = 0
            withAnimation(.easeOut(duration: 1.65).repeatForever(autoreverses: false)) {
                phase = 1
            }
        } else {
            withAnimation(.easeOut(duration: 0.25)) {
                phase = 0
            }
        }
    }
}

// MARK: - 通用毛玻璃控件

struct GlassCard<Content: View>: View {
    var padding: CGFloat = 18
    var cornerRadius: CGFloat = 22
    var strong: Bool = false
    var tint: Color? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frostedSurface(
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                strong: strong,
                tint: tint
            )
    }
}

struct CircleIconButton: View {
    var systemName: String
    var size: CGFloat = 42
    var tint: Color = Theme.textPrimary
    var glassTint: Color? = nil
    var action: () -> Void

    var body: some View {
        Button {
            Haptics.light()
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: size * 0.39, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .contentShape(Circle())
                .liquidGlassChrome(in: Circle(), tint: glassTint, interactive: true)
        }
        .buttonStyle(bouncy())
    }
}

struct PillBadge: View {
    var text: String
    var tint: Color = Theme.textSecondary
    var filled: Bool = false
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9.5, weight: .bold))
            }
            Text(text)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(filled ? Color.white : tint)
        .padding(.horizontal, 8.5)
        .padding(.vertical, 3.5)
        .background {
            if filled {
                Capsule().fill(
                    LinearGradient(
                        colors: [tint, tint.opacity(0.84)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            } else {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(Capsule().fill(tint.opacity(0.10)))
            }
        }
        .overlay(
            Capsule()
                .strokeBorder(filled ? Color.white.opacity(0.24) : tint.opacity(0.26), lineWidth: 0.8)
        )
    }
}

/// 大圆角玻璃质感主按钮
struct PrimaryActionButton: View {
    var title: String
    var systemName: String
    var prominent: Bool = true
    var action: () -> Void

    var body: some View {
        Button {
            Haptics.medium()
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemName)
                    .font(.system(size: 16, weight: .bold))
                Text(title)
                    .font(.system(size: 16.5, weight: .semibold))
            }
            .foregroundStyle(prominent ? Theme.onAccent : Theme.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background {
                if prominent {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Theme.accentFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [Color.white.opacity(0.32), .clear],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 0.9
                                )
                        )
                        .shadow(color: Theme.shadowColor, radius: 14, y: 7)
                } else {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.thinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(Theme.specularBorderGradient, lineWidth: 0.9)
                        )
                }
            }
        }
        .buttonStyle(bouncy())
    }
}

/// 轻弹性按钮样式
struct bouncy: ButtonStyle {
    var scale: CGFloat = 0.965

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

/// 轻微微光骨架动画(加载态)
struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geo in
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.28), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.65)
                    .offset(x: phase * geo.size.width * 1.4)
                }
                .mask(content)
            }
            .onAppear {
                withAnimation(.linear(duration: 1.45).repeatForever(autoreverses: false)) {
                    phase = 1.2
                }
            }
    }
}

extension View {
    func shimmering() -> some View {
        modifier(ShimmerModifier())
    }
}
