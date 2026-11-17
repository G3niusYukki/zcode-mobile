import SwiftUI

/// Duo 真谛:右侧常驻悬浮操作栏(配对/设备、设置、刷新)
struct RightRail: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            railButton(icon: "qrcode.viewfinder", label: "配对设备") {
                model.showDeviceSheet = true
            }
            railButton(icon: "gearshape.fill", label: "设置") {
                model.showSettings = true
            }
            railButton(icon: "chart.bar.fill", label: "用量与配额") {
                model.refreshUsage()
                model.showUsageSheet = true
            }
            railButton(icon: "arrow.clockwise", label: "重新连接") {
                model.reconnect()
            }
        }
        .padding(.top, 14)
        .padding(.trailing, 16)
    }

    private func railButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.white.opacity(0.09)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        }
        .buttonStyle(bouncy())
        .accessibilityLabel(label)
    }
}

/// 设备/配对面板
struct DeviceSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("已配对桌面")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textTertiary)
                        if let device = model.pairedDevice {
                            GlassCard(padding: 16, cornerRadius: 18) {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack(spacing: 10) {
                                        Image(systemName: "desktopcomputer")
                                            .font(.system(size: 16))
                                            .foregroundStyle(Theme.azure)
                                        Text(device.deviceName ?? "我的电脑")
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(Theme.textPrimary)
                                        Spacer()
                                        HStack(spacing: 6) {
                                            StatusDot(color: model.bridgePhase == .ready ? Theme.mint : Theme.amber)
                                            Text(model.bridgePhase == .ready ? "在线" : "离线")
                                                .font(.system(size: 11))
                                                .foregroundStyle(Theme.textSecondary)
                                        }
                                    }
                                    Text(device.deviceSid)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(Theme.textTertiary)
                                    Text(device.origin.appending(device.sourceUrl == nil ? "" : ""))
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(Theme.textTertiary)
                                        .lineLimit(1)
                                }
                            }
                        } else {
                            Text("尚未配对桌面端")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }

                    VStack(spacing: 10) {
                        Button {
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                model.screen = .pairing
                            }
                        } label: {
                            Label("重新扫码配对", systemImage: "qrcode.viewfinder")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        Button {
                            model.reconnect()
                            dismiss()
                        } label: {
                            Label("重新连接", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)

                        Button("解除配对", role: .destructive) {
                            model.unpair()
                            dismiss()
                        }
                        .font(.footnote)
                    }
                }
                .padding(24)
            }
            .background(Theme.background())
            .navigationTitle("设备与配对")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
