import SwiftUI
import ZCodeMobileCore

/// 终态失败全屏页:给出可操作的恢复路径,而不是让用户卡死。
/// 二维码过期 → 自动接续失败时落到这里,主按钮引导重新扫码。
struct FailureView: View {
    @EnvironmentObject var model: AppModel
    let failure: AppModel.TerminalFailure

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: icon)
                .font(.system(size: 52))
                .foregroundStyle(.orange)

            Text(failure.title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)

            Text(failure.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            VStack(spacing: 10) {
                // 主路径:重新扫码(拿到最新 sid,一步到位)
                Button {
                    model.terminalFailure = nil
                    model.screen = .pairing
                } label: {
                    Label("重新扫码配对", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                // 次路径:重试(SID 接续判定 keepCurrent 或临时网络问题时有效)
                Button {
                    model.terminalFailure = nil
                    model.reconnect()
                } label: {
                    Label("重试连接", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button("切换账号") {
                    model.terminalFailure = nil
                    model.logout()
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
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
