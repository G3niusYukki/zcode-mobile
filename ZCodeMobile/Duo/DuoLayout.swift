import SwiftUI

/// Duo 布局:左 = 会话侧栏(37%),右 = 交互区。
/// 展开/宽屏:HStack 精确 37/63;紧凑(外屏):单列,openConversation 时显示对话。
struct DuoLayout<Primary: View, Detail: View>: View {
    var compactShowsDetail: Bool = false
    @Environment(\.horizontalSizeClass) private var hSize
    @ViewBuilder let primary: () -> Primary
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        GeometryReader { geo in
            if hSize == .compact {
                Group {
                    if compactShowsDetail { detail() } else { primary() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let sidebarWidth = min(max(geo.size.width * 0.37, 300), 560)
                HStack(spacing: 0) {
                    primary()
                        .frame(width: sidebarWidth)
                        .background(Theme.sidebarBG)
                    Rectangle().fill(Theme.cardFill).frame(width: 0.5)
                    detail()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.background())
                }
            }
        }
        .background(HingeHook())
    }
}
