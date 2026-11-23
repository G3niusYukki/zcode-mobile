import SwiftUI

/// Duo 右侧常驻悬浮 Liquid Glass 操作栏(配对/设备、设置、用量、重连)
struct RightRail: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(spacing: 12) {
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
        }
        .padding(.top, 14)
        .padding(.trailing, 16)
    }

    private func railButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.light()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .liquidGlassChrome(in: Circle(), interactive: true)
        }
        .buttonStyle(bouncy(scale: 0.92))
        .accessibilityLabel(label)
    }
}

/// 设备/配对毛玻璃面板
struct DeviceSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("已配对桌面")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.leading, 4)

                        if let device = model.pairedDevice {
                            GlassCard(padding: 18, cornerRadius: 22, strong: true) {
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack(spacing: 12) {
                                        Image(systemName: "desktopcomputer")
                                            .font(.system(size: 18, weight: .semibold))
                                            .foregroundStyle(Theme.azure)
                                            .frame(width: 40, height: 40)
                                            .background(Circle().fill(Theme.azure.opacity(0.14)))

                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(device.deviceName ?? "我的电脑")
                                                .font(.system(size: 16, weight: .semibold))
                                                .foregroundStyle(Theme.textPrimary)
                                            Text(model.relayPhase)
                                                .font(.system(size: 12))
                                                .foregroundStyle(Theme.textSecondary)
                                        }

                                        Spacer()

                                        HStack(spacing: 5) {
                                            StatusDot(
                                                color: model.bridgePhase == .ready ? Theme.mint : Theme.amber,
                                                pulsing: model.bridgePhase == .ready,
                                                size: 7
                                            )
                                            Text(model.bridgePhase == .ready ? "在线" : "待连")
                                                .font(.system(size: 11.5, weight: .semibold))
                                                .foregroundStyle(model.bridgePhase == .ready ? Theme.mint : Theme.amber)
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Capsule().fill((model.bridgePhase == .ready ? Theme.mint : Theme.amber).opacity(0.14)))
                                    }

                                    Rectangle().fill(Theme.hairline).frame(height: 0.6)

                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(device.deviceSid)
                                                .font(.system(size: 11.5, design: .monospaced))
                                                .foregroundStyle(Theme.textSecondary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                            Text(device.origin)
                                                .font(.system(size: 11, design: .monospaced))
                                                .foregroundStyle(Theme.textTertiary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        Button {
                                            UIPasteboard.general.string = device.deviceSid
                                            model.showToast("已复制设备 SID", icon: "doc.on.doc.fill", tint: Theme.mint)
                                        } label: {
                                            Image(systemName: "doc.on.doc")
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundStyle(Theme.textSecondary)
                                                .frame(width: 30, height: 30)
                                                .liquidGlassChrome(in: Circle(), interactive: true)
                                        }
                                        .buttonStyle(bouncy())
                                    }
                                }
                            }
                        } else {
                            GlassCard(padding: 18, cornerRadius: 20) {
                                HStack(spacing: 12) {
                                    Image(systemName: "qrcode")
                                        .font(.system(size: 20))
                                        .foregroundStyle(Theme.textTertiary)
                                    Text("尚未配对桌面端，请点击下方扫描二维码")
                                        .font(.system(size: 13.5))
                                        .foregroundStyle(Theme.textSecondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }

                    VStack(spacing: 12) {
                        PrimaryActionButton(title: "重新扫码配对", systemName: "qrcode.viewfinder") {
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                withAnimation(Motion.smooth) {
                                    model.screen = .pairing
                                }
                            }
                        }

                        PrimaryActionButton(title: "重新连接", systemName: "arrow.clockwise", prominent: false) {
                            model.reconnect()
                            dismiss()
                        }

                        Button(role: .destructive) {
                            Haptics.warning()
                            model.unpair()
                            dismiss()
                        } label: {
                            Text("解除配对")
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(Theme.coral)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(bouncy())
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
            .scrollIndicators(.hidden)
            .navigationTitle("设备与配对")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        Haptics.light()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}
