import SwiftUI
import ZCodeMobileCore

/// 设置页(对齐参考应用的卡片式分组)
struct SettingsScreen: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section("连接") {
                        SettingsCard {
                            settingRow("桌面端点", value: model.pairedDevice?.origin.replacingOccurrences(of: "https://", with: "wss://") .appending("/api/v1/remote/ws2") ?? "未配对")
                            divider
                            HStack {
                                Text("状态").font(.system(size: 15))
                                Spacer()
                                HStack(spacing: 6) {
                                    StatusDot(color: model.bridgePhase == .ready ? Theme.mint : Theme.amber)
                                    Text(model.relayPhase)
                                        .font(.system(size: 13))
                                        .foregroundStyle(Theme.textSecondary)
                                }
                            }
                            .padding(.vertical, 13)
                            divider
                            settingRow("连接方式", value: "WebSocket")
                            divider
                            Button {
                                model.reconnect()
                                dismiss()
                            } label: {
                                rowLabel("重新连接", tint: Theme.azure, chevron: true)
                            }
                            .buttonStyle(.plain)
                            divider
                            Button {
                                model.disconnect()
                                dismiss()
                            } label: {
                                rowLabel("断开连接", tint: Theme.coral, chevron: false)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    section("账号") {
                        SettingsCard {
                            settingRow("登录状态", value: model.jwtReady ? "已登录" : "未登录")
                            divider
                            Button {
                                model.logout()
                                dismiss()
                            } label: {
                                rowLabel("退出登录", tint: Theme.coral, chevron: false)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    section("会话默认配置 · 由桌面端决定", footer: "与桌面端使用同一份部署级设置,修改仅影响之后新建的会话。") {
                        SettingsCard {
                            settingRow("Agent 预设", value: "标准模式", chevron: true)
                            divider
                            settingRow("运行模型", value: model.currentModelLabel, chevron: true)
                            divider
                            settingRow("权限", value: "工作区写入", chevron: true)
                        }
                    }

                    section("用量") {
                        SettingsCard {
                            Button {
                                model.refreshUsage()
                                dismiss()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                    model.showUsageSheet = true
                                }
                            } label: {
                                rowLabel("用量与配额", tint: Theme.textPrimary, chevron: true)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    section("真后台推送(可选)", footer: "配合仓库内 server/ 的 APNs 网关使用:锁屏后仍能收到审批与状态更新。") {
                        SettingsCard {
                            Toggle(isOn: Binding(
                                get: { model.pushEnabled },
                                set: { model.updatePushSettings(enabled: $0, url: model.pushSyncURL, secret: model.pushSecret) }
                            )) {
                                Text("启用真后台更新")
                                    .font(.system(size: 15))
                                    .foregroundStyle(Theme.textPrimary)
                            }
                            .tint(Theme.azure)
                            .padding(.vertical, 10)
                            divider
                            pushField(title: "中转地址", text: Binding(
                                get: { model.pushSyncURL },
                                set: { model.updatePushSettings(enabled: model.pushEnabled, url: $0, secret: model.pushSecret) }
                            ), placeholder: "https://your-worker.workers.dev")
                            divider
                            pushField(title: "密钥", text: Binding(
                                get: { model.pushSecret },
                                set: { model.updatePushSettings(enabled: model.pushEnabled, url: model.pushSyncURL, secret: $0) }
                            ), placeholder: "与网关一致的 secret", secure: true)
                        }
                    }

                    section("外观") {
                        SettingsCard {
                            settingRow("界面", value: "跟随系统", chevron: true)
                            divider
                            settingRow("字体大小", value: "100%", chevron: true)
                            divider
                            settingRow("Duo 布局", value: "自适应分栏", chevron: true)
                        }
                    }

                    section("关于") {
                        SettingsCard {
                            settingRow("当前版本", value: "1.0.0", chevron: true)
                            divider
                            settingRow("协议", value: "ZCode Relay V2", chevron: true)
                            divider
                            settingRow("中继端点", value: "zcode.z.ai", chevron: true)
                        }
                    }
                }
                .padding(24)
            }
            .scrollIndicators(.hidden)
            .background(Theme.background())
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, footer: String? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .padding(.leading, 4)
            content()
            if let footer {
                Text(footer)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 6)
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.cardFill).frame(height: 0.5)
    }

    private func settingRow(_ title: String, value: String, chevron: Bool = false) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Text(value)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.vertical, 13)
    }

    private func pushField(title: String, text: Binding<String>, placeholder: String, secure: Bool = false) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Group {
                if secure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .font(.system(size: 12.5, design: .monospaced))
            .multilineTextAlignment(.trailing)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .frame(maxWidth: 190)
        }
        .padding(.vertical, 11)
    }

    private func rowLabel(_ title: String, tint: Color, chevron: Bool) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 15))
                .foregroundStyle(tint)
            Spacer()
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.vertical, 13)
    }
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
                .padding(.horizontal, 16)
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.cardFillStrong)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 1)
        )
    }
}
