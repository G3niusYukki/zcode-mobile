import SwiftUI
import ZCodeMobileCore

@main
struct ZCodeMobileApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
        }
    }
}

extension View {
    /// Duo 右侧竖向苹果原生标准尺寸 Liquid Glass 工具条;非 Duo 设备落回顶部工具条
    @ToolbarContentBuilder
    var sessionToolbar: some ToolbarContent {
        if #available(iOS 27.1, *) {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.light()
                    ZCodeMobileToolbarActions.shared.usage?()
                } label: {
                    Image(systemName: "chart.bar.fill")
                }
                .accessibilityLabel("用量与配额")
            }
            .axisBehavior(.verticalPreferred)
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.light()
                    ZCodeMobileToolbarActions.shared.device?()
                } label: {
                    Image(systemName: "qrcode.viewfinder")
                }
                .accessibilityLabel("配对设备")
            }
            .axisBehavior(.verticalPreferred)
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.light()
                    ZCodeMobileToolbarActions.shared.settings?()
                } label: {
                    Image(systemName: "gearshape.fill")
                }
                .accessibilityLabel("设置")
            }
            .axisBehavior(.verticalPreferred)
        } else {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    Haptics.light()
                    ZCodeMobileToolbarActions.shared.usage?()
                } label: {
                    Image(systemName: "chart.bar.fill")
                }
                Button {
                    Haptics.light()
                    ZCodeMobileToolbarActions.shared.device?()
                } label: {
                    Image(systemName: "qrcode.viewfinder")
                }
                Button {
                    Haptics.light()
                    ZCodeMobileToolbarActions.shared.settings?()
                } label: {
                    Image(systemName: "gearshape.fill")
                }
            }
        }
    }
}

/// 工具条动作桥(由 RootView 注入 model)
final class ZCodeMobileToolbarActions {
    static let shared = ZCodeMobileToolbarActions()
    var usage: (() -> Void)?
    var device: (() -> Void)?
    var settings: (() -> Void)?
}

/// 符合 Apple HIG 最小触控尺寸(44×44pt)的 Liquid Glass 圆形工具条按钮
struct WidgetToolbarButton: View {
    let icon: String
    var label: String = ""
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.light()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 18.5, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .liquidGlassChrome(in: Circle(), interactive: true)
        }
        .buttonStyle(bouncy(scale: 0.92))
        .accessibilityLabel(label)
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("zcode-mobile.colorScheme") private var colorSchemeRaw: String = AppAppearanceMode.system.rawValue
    @State private var toastDragOffset: CGFloat = 0

    private var appearanceMode: AppAppearanceMode {
        AppAppearanceMode(rawValue: colorSchemeRaw) ?? .system
    }

    var body: some View {
        ZStack {
            Theme.background(breathing: false)
                .ignoresSafeArea()

            Group {
                switch model.screen {
                case .login:
                    LoginView()
                        .transition(.opacity)
                case .pairing:
                    PairingView()
                        .transition(.opacity)
                case .session:
                    NavigationStack {
                        DuoLayout(
                            compactShowsDetail: model.openConversation,
                            sidebarCollapsed: model.sidebarCollapsed,
                            onSwipeBack: { model.closeConversation() },
                            primary: { SessionsPane() },
                            detail: {
                                ZStack {
                                    if model.openConversation {
                                        ConversationScreen()
                                            .id(model.selectedTask?.taskId ?? "active-conversation")
                                            .transition(.opacity)
                                    } else {
                                        HomePane()
                                            .transition(.opacity)
                                    }
                                }
                                .animation(Motion.smooth, value: model.openConversation)
                                .animation(Motion.smooth, value: model.selectedTask?.taskId)
                            }
                        )
                        .background {
                            // 直接铺在 NavigationStack 内容根层并 ignoresSafeArea,彻底消除折叠态外屏四周白边与直角边界
                            Theme.background(breathing: false)
                                .ignoresSafeArea()
                        }
                        .toolbar { sessionToolbar }
                        .toolbarBackground(.hidden, for: .navigationBar)
                        .navigationBarTitleDisplayMode(.inline)
                    }
                    .transition(.opacity)
                }
            }
            .animation(Motion.smooth, value: model.screen)
        }
        .overlay(alignment: .top) {
            if let toast = model.toast {
                toastPill(toast)
                    .offset(y: min(0, toastDragOffset))
                    .gesture(
                        DragGesture(minimumDistance: 8)
                            .onChanged { value in
                                if value.translation.height < 0 {
                                    toastDragOffset = value.translation.height
                                }
                            }
                            .onEnded { value in
                                if value.translation.height < -24 {
                                    model.dismissToast()
                                }
                                withAnimation(Motion.snappy) { toastDragOffset = 0 }
                            }
                    )
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.92)))
                    .zIndex(100)
            }
        }
        .fullScreenCover(item: $model.terminalFailure) { failure in
            FailureView(failure: failure)
                .presentationBackground(.clear)
                .preferredColorScheme(appearanceMode.colorScheme)
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsScreen()
                .environmentObject(model)
                .presentationBackground(.ultraThinMaterial)
                .presentationCornerRadius(28)
                .presentationDragIndicator(.visible)
                .preferredColorScheme(appearanceMode.colorScheme)
        }
        .sheet(isPresented: $model.showDeviceSheet) {
            DeviceSheet()
                .environmentObject(model)
                .presentationBackground(.ultraThinMaterial)
                .presentationCornerRadius(28)
                .presentationDragIndicator(.visible)
                .preferredColorScheme(appearanceMode.colorScheme)
        }
        .sheet(isPresented: $model.showUsageSheet) {
            UsageSheet()
                .environmentObject(model)
                .presentationBackground(.ultraThinMaterial)
                .presentationCornerRadius(28)
                .presentationDragIndicator(.visible)
                .preferredColorScheme(appearanceMode.colorScheme)
        }
        .preferredColorScheme(appearanceMode.colorScheme)
        .tint(Theme.azure)
        .onAppear {
            ZCodeMobileToolbarActions.shared.usage = {
                model.refreshUsage()
                model.showUsageSheet = true
            }
            ZCodeMobileToolbarActions.shared.device = { model.showDeviceSheet = true }
            ZCodeMobileToolbarActions.shared.settings = { model.showSettings = true }
        }
    }

    private func toastPill(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: model.toastIcon)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(model.toastTint)
                .symbolEffect(.bounce, value: message)
            Text(message)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .liquidGlassChrome(in: Capsule(), tint: model.toastTint.opacity(0.08))
        .shadow(color: Theme.shadowColor, radius: 14, y: 6)
        .padding(.horizontal, 24)
    }
}
