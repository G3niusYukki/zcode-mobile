import SwiftUI
import ZCodeMobileCore

/// 终态失败全屏毛玻璃恢复页:给出可操作的恢复路径,而不是让用户卡死。
struct FailureView: View {
    @EnvironmentObject var model: AppModel
    let failure: AppModel.TerminalFailure
    @State private var appeared = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
            Theme.bgSolid.opacity(0.35)
                .ignoresSafeArea()

            GlassCard(padding: 26, cornerRadius: 28, strong: true, tint: Theme.amber.opacity(0.06)) {
                VStack(spacing: 18) {
                    ZStack {
                        Circle()
                            .fill(Theme.amber.opacity(0.16))
                            .frame(width: 76, height: 76)
                        Image(systemName: icon)
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(Theme.amber)
                            .symbolEffect(.pulse, value: appeared)
                    }

                    VStack(spacing: 8) {
                        Text(failure.title)
                            .font(.system(size: 21, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                            .multilineTextAlignment(.center)

                        Text(failure.message)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                            .lineSpacing(3)
                    }

                    VStack(spacing: 10) {
                        PrimaryActionButton(title: "重新扫码配对", systemName: "qrcode.viewfinder") {
                            model.terminalFailure = nil
                            withAnimation(Motion.smooth) {
                                model.screen = .pairing
                            }
                        }

                        PrimaryActionButton(title: "重试连接", systemName: "arrow.clockwise", prominent: false) {
                            model.terminalFailure = nil
                            model.reconnect()
                        }

                        Button {
                            Haptics.warning()
                            model.terminalFailure = nil
                            model.logout()
                        } label: {
                            Text("切换账号")
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(bouncy())
                    }
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: 420)
            .padding(.horizontal, 24)
            .scaleEffect(appeared ? 1 : 0.92)
            .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            Haptics.warning()
            withAnimation(Motion.bouncy) { appeared = true }
        }
    }

    private var icon: String {
        switch failure.reason {
        case .authFailed: return "qrcode"
        case .desktopDisconnected: return "desktopcomputer.trianglebadge.exclamationmark"
        case .kicked: return "person.2.wave.2"
        default: return "exclamationmark.triangle"
        }
    }
}
