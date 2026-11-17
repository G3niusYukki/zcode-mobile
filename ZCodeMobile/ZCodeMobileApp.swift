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
    /// Duo 右侧竖向工具条(配对/设置);非 Duo 设备落回顶部工具条
    @ToolbarContentBuilder
    var sessionToolbar: some ToolbarContent {
        if #available(iOS 27.1, *) {
            ToolbarItem(placement: .topBarTrailing) {
                WidgetToolbarButton(icon: "qrcode.viewfinder") { ZCodeMobileToolbarActions.shared.device?() }
            }
            .axisBehavior(.verticalPreferred)
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .topBarTrailing) {
                WidgetToolbarButton(icon: "gearshape.fill") { ZCodeMobileToolbarActions.shared.settings?() }
            }
            .axisBehavior(.verticalPreferred)
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { ZCodeMobileToolbarActions.shared.device?() } label: { Image(systemName: "qrcode.viewfinder") }
                Button { ZCodeMobileToolbarActions.shared.settings?() } label: { Image(systemName: "gearshape.fill") }
            }
        }
    }
}

/// 工具条动作桥(由 RootView 注入 model)
final class ZCodeMobileToolbarActions {
    static let shared = ZCodeMobileToolbarActions()
    var device: (() -> Void)?
    var settings: (() -> Void)?
}

struct WidgetToolbarButton: View {
    let icon: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Theme.cardStroke))
                .overlay(Circle().strokeBorder(Theme.cardStroke, lineWidth: 1))
        }
        .buttonStyle(bouncy())
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            switch model.screen {
            case .login:
                LoginView()
            case .pairing:
                PairingView()
            case .session:
                NavigationStack {
                    DuoLayout(
                        compactShowsDetail: model.openConversation,
                        primary: { SessionsPane() },
                        detail: {
                            if model.openConversation {
                                ConversationScreen()
                            } else {
                                HomePane()
                            }
                        }
                    )
                    .toolbar { sessionToolbar }
                    .toolbarBackground(.hidden, for: .navigationBar)
                    .navigationBarTitleDisplayMode(.inline)
                }
                .background(Theme.background().ignoresSafeArea())
            }
        }
        .background(Theme.background())
        .overlay(alignment: .top) {
            if let toast = model.toast {
                Text(toast)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Capsule().fill(Color.black.opacity(0.65)))
                    .overlay(Capsule().strokeBorder(Theme.cardStroke))
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .fullScreenCover(item: $model.terminalFailure) { failure in
            FailureView(failure: failure)
                .presentationBackground(.thinMaterial)
        }
        .fullScreenCover(isPresented: $model.showSettings) {
            SettingsScreen()
                .environmentObject(model)
        }
        .fullScreenCover(isPresented: $model.showDeviceSheet) {
            DeviceSheet()
                .environmentObject(model)
        }
        .fullScreenCover(isPresented: $model.showUsageSheet) {
            UsageSheet()
                .environmentObject(model)
        }
        .tint(Theme.azure)
        .onAppear {
            ZCodeMobileToolbarActions.shared.device = { model.showDeviceSheet = true }
            ZCodeMobileToolbarActions.shared.settings = { model.showSettings = true }
        }
    }
}
