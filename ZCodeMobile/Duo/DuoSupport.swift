import SwiftUI
import Combine

/// 铰链观察者:半折叠(笔记本)姿态检测。iOS 27.1+ 的 onHingeChange;
/// 低版本/非折叠设备恒为普通姿态。
@MainActor
final class HingeObserver: ObservableObject {
    static let shared = HingeObserver()

    /// 笔记本姿态:部分展开(书本/笔记本式)→ 上屏只读、下屏输入
    @Published var isLaptopPose = false
    @Published var hingeAngleDegrees: Double?

    @available(iOS 27.1, *)
    func update(hinge: DeviceHinge?) {
        let laptop = hinge?.status == .partiallyOpen
        if laptop != isLaptopPose {
            withAnimation(.easeInOut(duration: 0.2)) {
                isLaptopPose = laptop
            }
        }
        hingeAngleDegrees = hinge?.angle.degrees
    }
}

/// 放置在 Duo 根视图上的隐形钩子,把 onHingeChange 事件喂给 HingeObserver
struct HingeHook: View {
    @ObservedObject var observer = HingeObserver.shared

    var body: some View {
        Group {
            if #available(iOS 27.1, *) {
                Color.clear
                    .onHingeChange { _, newContext in
                        observer.update(hinge: newContext.hinge)
                    }
            } else {
                EmptyView()
            }
        }
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - 保留区感知修饰符(避开折痕/前摄,Duo 内屏安全区不对称)

struct ReservedRegionAvoidance: ViewModifier {
    @State private var divisionOverlap: CGFloat = 0

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content
                .padding(.bottom, divisionOverlap)
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onGeometryChange(for: CGFloat.self) { proxy in
                                guard proxy.size.height > 0 else { return 0 }
                                // division(折痕)与元素相交的最大高度 → 底部避让
                                let regions = proxy.reservedRegions(kind: .division, options: .includeInactive)
                                let frame = proxy.frame(in: .local)
                                return regions
                                    .filter(\.isActive)
                                    .map { $0.frame.intersection(frame).height }
                                    .max() ?? 0
                            } action: { overlap in
                                if overlap != divisionOverlap {
                                    divisionOverlap = overlap
                                }
                            }
                    }
                )
        } else {
            content
        }
    }
}

extension View {
    /// 输入框/审批按钮等交互元素避开折痕(division)保留区
    func reservedRegionAware() -> some View {
        modifier(ReservedRegionAvoidance())
    }
}
