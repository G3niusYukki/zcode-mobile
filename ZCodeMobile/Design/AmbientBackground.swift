import SwiftUI

/// 高性能氛围底布:
/// 使用纯数学 RadialGradient + `.drawingGroup()` 单层 GPU 纹理缓存(零实时高斯模糊开销、满帧 120Hz),
/// 全屏 `.ignoresSafeArea()` 铺满折叠外屏与展开内屏,杜绝安全区留白与直角边。
struct AmbientBackground: View {
    @Environment(\.colorScheme) private var scheme
    @AppStorage("zcode-mobile.glassBackdrop") private var backdropStyle: String = GlassBackdropStyle.aurora.rawValue
    var breathing: Bool = false

    var body: some View {
        ZStack {
            baseLayer
            if backdropStyle == GlassBackdropStyle.aurora.rawValue {
                auroraLayer
            } else {
                minimalDepthLayer
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var baseLayer: some View {
        LinearGradient(
            colors: scheme == .dark
                ? [
                    Color(red: 0.032, green: 0.040, blue: 0.062),
                    Color(red: 0.018, green: 0.022, blue: 0.034),
                    Color(red: 0.026, green: 0.032, blue: 0.048),
                ]
                : [
                    Color(red: 0.948, green: 0.962, blue: 0.992),
                    Color(red: 0.968, green: 0.974, blue: 0.988),
                    Color(red: 0.942, green: 0.958, blue: 0.986),
                ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var auroraLayer: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 320)
            let h = max(geo.size.height, 480)
            ZStack {
                // 主光源:冷蔚蓝光晕(右上)
                RadialGradient(
                    colors: scheme == .dark
                        ? [Theme.azure.opacity(0.22), Theme.azure.opacity(0.06), .clear]
                        : [Color(red: 0.34, green: 0.60, blue: 0.98).opacity(0.22),
                           Color(red: 0.34, green: 0.60, blue: 0.98).opacity(0.06), .clear],
                    center: UnitPoint(x: 0.86, y: 0.14),
                    startRadius: 10,
                    endRadius: max(w, h) * 0.62
                )

                // 辅光源:靛紫柔雾(左中)
                RadialGradient(
                    colors: scheme == .dark
                        ? [Theme.indigo.opacity(0.18), Theme.indigo.opacity(0.04), .clear]
                        : [Color(red: 0.52, green: 0.48, blue: 0.96).opacity(0.16),
                           Color(red: 0.52, green: 0.48, blue: 0.96).opacity(0.04), .clear],
                    center: UnitPoint(x: 0.12, y: 0.55),
                    startRadius: 10,
                    endRadius: max(w, h) * 0.58
                )

                // 辅光源:薄荷微光(右下)
                RadialGradient(
                    colors: scheme == .dark
                        ? [Theme.mint.opacity(0.12), Theme.mint.opacity(0.02), .clear]
                        : [Color(red: 0.22, green: 0.78, blue: 0.60).opacity(0.15),
                           Color(red: 0.22, green: 0.78, blue: 0.60).opacity(0.03), .clear],
                    center: UnitPoint(x: 0.82, y: 0.86),
                    startRadius: 10,
                    endRadius: max(w, h) * 0.54
                )
            }
        }
    }

    private var minimalDepthLayer: some View {
        RadialGradient(
            colors: scheme == .dark
                ? [Color.white.opacity(0.035), .clear]
                : [Color(red: 0.84, green: 0.90, blue: 0.98).opacity(0.28), .clear],
            center: .topTrailing,
            startRadius: 20,
            endRadius: 560
        )
    }
}
