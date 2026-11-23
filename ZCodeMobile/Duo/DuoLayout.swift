import SwiftUI

/// Duo 布局:
/// - 展开/宽屏:毛玻璃会话侧栏(36.5%,支持一键折叠专注模式) + 镜面分割线 + 右侧交互区
/// - 紧凑(外屏):全屏无留白出血背景 + 仅左边缘 22pt 滑动返回条(绝不拦截 ScrollView 上下滚动)
struct DuoLayout<Primary: View, Detail: View>: View {
    var compactShowsDetail: Bool = false
    var sidebarCollapsed: Bool = false
    var onSwipeBack: (() -> Void)? = nil
    @Environment(\.horizontalSizeClass) private var hSize
    @ObservedObject private var hinge = HingeObserver.shared
    @ViewBuilder let primary: () -> Primary
    @ViewBuilder let detail: () -> Detail

    @State private var edgeDragOffset: CGFloat = 0
    @State private var edgeDragging = false

    var body: some View {
        GeometryReader { geo in
            if hSize == .compact {
                compactBody(width: geo.size.width)
            } else {
                expandedBody(size: geo.size)
            }
        }
        .overlay(alignment: .bottom) {
            if hinge.isLaptopPose {
                laptopPosePill
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.smooth, value: hinge.isLaptopPose)
        .background(HingeHook())
    }

    // MARK: - 外屏紧凑布局(全屏无白边 + 仅左边缘 22pt 手势条,完全不干扰上下滚动)

    private func compactBody(width: CGFloat) -> some View {
        let progress = min(1, max(0, edgeDragOffset / max(width, 1)))
        return ZStack {
            primary()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scaleEffect(compactShowsDetail ? (0.965 + 0.035 * progress) : 1.0)
                .opacity(compactShowsDetail ? (0.30 + 0.70 * progress) : 1.0)
                .allowsHitTesting(!compactShowsDetail)
                .animation(edgeDragging ? nil : Motion.smooth, value: compactShowsDetail)

            if compactShowsDetail {
                detail()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        Theme.background(breathing: false)
                            .ignoresSafeArea()
                    }
                    .overlay(alignment: .leading) {
                        // 仅在屏幕最左侧 22pt 监听边缘右滑返回,彻底释放中间区域的 ScrollView 上下滑动!
                        Color.clear
                            .frame(width: 22)
                            .contentShape(Rectangle())
                            .gesture(edgeSwipeBackGesture(width: width))
                    }
                    .modifier(ConditionalDragClip(active: edgeDragOffset > 1))
                    .shadow(color: Color.black.opacity(edgeDragOffset > 2 ? 0.22 : 0), radius: 22, x: -6)
                    .offset(x: edgeDragOffset)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing),
                        removal: .move(edge: .trailing)
                    ))
            }
        }
        .animation(edgeDragging ? nil : Motion.smooth, value: compactShowsDetail)
    }

    private func edgeSwipeBackGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .onChanged { value in
                guard value.translation.width > 0 else { return }
                if !edgeDragging {
                    guard abs(value.translation.width) > abs(value.translation.height) * 1.1 else { return }
                    edgeDragging = true
                }
                edgeDragOffset = value.translation.width
            }
            .onEnded { value in
                guard edgeDragging else { return }
                edgeDragging = false
                let threshold = min(100, width * 0.28)
                let projected = value.predictedEndTranslation.width
                if value.translation.width > threshold || projected > width * 0.42 {
                    Haptics.light()
                    withAnimation(Motion.snappy) {
                        edgeDragOffset = 0
                        onSwipeBack?()
                    }
                } else {
                    withAnimation(Motion.smooth) {
                        edgeDragOffset = 0
                    }
                }
            }
    }

    // MARK: - Duo 展开双栏布局

    private func expandedBody(size: CGSize) -> some View {
        let sidebarWidth = min(max(size.width * 0.365, 300), 520)
        return HStack(spacing: 0) {
            if !sidebarCollapsed {
                primary()
                    .frame(width: sidebarWidth)
                    .background {
                        ZStack {
                            Rectangle().fill(.ultraThinMaterial)
                            Rectangle().fill(Theme.sidebarBG)
                        }
                        .ignoresSafeArea()
                    }
                    .overlay(alignment: .trailing) {
                        LinearGradient(
                            colors: [Theme.glassHighlightTop.opacity(0.55), Theme.hairline, Theme.glassHighlightBottom],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(width: 0.75)
                        .ignoresSafeArea()
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            detail()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(Motion.smooth, value: sidebarCollapsed)
    }

    private var laptopPosePill: some View {
        HStack(spacing: 6) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.azure)
            Text("半折叠姿态")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .liquidGlassChrome(in: Capsule())
    }
}

/// 仅在边缘拖拽过程中裁切圆角,静止态完全不裁切安全区外出血背景(彻底消除折叠外屏四周白边与直角)
private struct ConditionalDragClip: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
        } else {
            content
        }
    }
}
