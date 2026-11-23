import SwiftUI
import ZCodeMobileCore

/// 设置页:真毛玻璃分组卡片 + 实时可交互的外观/毛玻璃/字体缩放/触感/Duo布局设置
struct SettingsScreen: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @AppStorage("zcode-mobile.colorScheme") private var colorSchemeRaw: String = AppAppearanceMode.system.rawValue
    @AppStorage("zcode-mobile.glassBackdrop") private var backdropRaw: String = GlassBackdropStyle.aurora.rawValue
    @AppStorage("zcode-mobile.fontScale") private var fontScale: Double = 1.0
    @AppStorage("zcode-mobile.hapticsEnabled") private var hapticsEnabled: Bool = true
    @AppStorage("zcode-mobile.duoLayoutMode") private var duoLayoutRaw: String = DuoLayoutPreference.adaptive.rawValue

    private let fontScales: [(Double, String)] = [
        (0.9, "90%"),
        (1.0, "100%"),
        (1.1, "110%"),
        (1.2, "120%"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section("外观与毛玻璃", footer: "切换外观主题、毛玻璃底布风格与触感反馈，立即生效。") {
                        SettingsCard {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("界面外观")
                                    .font(.system(size: 14.5, weight: .medium))
                                    .foregroundStyle(Theme.textPrimary)
                                HStack(spacing: 8) {
                                    ForEach(AppAppearanceMode.allCases) { mode in
                                        let active = colorSchemeRaw == mode.rawValue
                                        Button {
                                            Haptics.selection()
                                            withAnimation(Motion.snappy) {
                                                colorSchemeRaw = mode.rawValue
                                            }
                                        } label: {
                                            HStack(spacing: 5) {
                                                Image(systemName: mode.icon)
                                                    .font(.system(size: 11.5, weight: .semibold))
                                                Text(mode.label)
                                                    .font(.system(size: 12.5, weight: active ? .semibold : .medium))
                                            }
                                            .foregroundStyle(active ? Theme.onAccent : Theme.textSecondary)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 8)
                                            .background(
                                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                    .fill(active ? Theme.accentFill : Theme.cardFill)
                                            )
                                        }
                                        .buttonStyle(bouncy(scale: 0.96))
                                    }
                                }
                            }
                            .padding(.vertical, 12)

                            divider

                            VStack(alignment: .leading, spacing: 10) {
                                Text("毛玻璃氛围")
                                    .font(.system(size: 14.5, weight: .medium))
                                    .foregroundStyle(Theme.textPrimary)
                                HStack(spacing: 8) {
                                    ForEach(GlassBackdropStyle.allCases) { style in
                                        let active = backdropRaw == style.rawValue
                                        Button {
                                            Haptics.selection()
                                            withAnimation(Motion.snappy) {
                                                backdropRaw = style.rawValue
                                            }
                                        } label: {
                                            Text(style.label)
                                                .font(.system(size: 12.5, weight: active ? .semibold : .medium))
                                                .foregroundStyle(active ? Theme.onAccent : Theme.textSecondary)
                                                .frame(maxWidth: .infinity)
                                                .padding(.vertical, 8)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                        .fill(active ? Theme.accentFill : Theme.cardFill)
                                                )
                                        }
                                        .buttonStyle(bouncy(scale: 0.96))
                                    }
                                }
                            }
                            .padding(.vertical, 12)

                            divider

                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("对话字体大小")
                                        .font(.system(size: 14.5, weight: .medium))
                                        .foregroundStyle(Theme.textPrimary)
                                    Spacer()
                                    Text("\(Int(round(fontScale * 100)))%")
                                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                                        .foregroundStyle(Theme.azure)
                                        .monospacedDigit()
                                }
                                HStack(spacing: 8) {
                                    ForEach(fontScales, id: \.0) { scale, label in
                                        let active = abs(fontScale - scale) < 0.01
                                        Button {
                                            Haptics.selection()
                                            withAnimation(Motion.snappy) {
                                                fontScale = scale
                                            }
                                        } label: {
                                            Text(label)
                                                .font(.system(size: 12.5, weight: active ? .semibold : .medium, design: .rounded))
                                                .foregroundStyle(active ? Theme.onAccent : Theme.textSecondary)
                                                .frame(maxWidth: .infinity)
                                                .padding(.vertical, 7)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                                        .fill(active ? Theme.accentFill : Theme.cardFill)
                                                )
                                        }
                                        .buttonStyle(bouncy(scale: 0.96))
                                    }
                                }
                            }
                            .padding(.vertical, 12)

                            divider

                            HStack {
                                Text("Duo 布局")
                                    .font(.system(size: 15))
                                    .foregroundStyle(Theme.textPrimary)
                                Spacer()
                                Picker("Duo 布局", selection: $duoLayoutRaw) {
                                    ForEach(DuoLayoutPreference.allCases) { pref in
                                        Text(pref.label).tag(pref.rawValue)
                                    }
                                }
                                .pickerStyle(.menu)
                                .tint(Theme.azure)
                            }
                            .padding(.vertical, 8)

                            divider

                            Toggle(isOn: $hapticsEnabled) {
                                Text("触感反馈")
                                    .font(.system(size: 15))
                                    .foregroundStyle(Theme.textPrimary)
                            }
                            .tint(Theme.azure)
                            .padding(.vertical, 10)
                            .onChange(of: hapticsEnabled) { _, on in
                                if on { Haptics.light() }
                            }
                        }
                    }

                    section("连接") {
                        SettingsCard {
                            Button {
                                if let endpoint = endpointURL {
                                    UIPasteboard.general.string = endpoint
                                    model.showToast("已复制桌面端点", icon: "doc.on.doc.fill", tint: Theme.mint)
                                }
                            } label: {
                                settingRow("桌面端点", value: endpointURL ?? "未配对")
                            }
                            .buttonStyle(.plain)

                            divider

                            HStack {
                                Text("状态")
                                    .font(.system(size: 15))
                                    .foregroundStyle(Theme.textPrimary)
                                Spacer()
                                HStack(spacing: 6) {
                                    StatusDot(
                                        color: connectionColor,
                                        pulsing: model.bridgePhase == .ready,
                                        size: 7
                                    )
                                    Text(model.relayPhase)
                                        .font(.system(size: 13.5))
                                        .foregroundStyle(Theme.textSecondary)
                                }
                            }
                            .padding(.vertical, 13)

                            divider
                            settingRow("连接方式", value: "WebSocket V2")
                            divider

                            Button {
                                Haptics.light()
                                model.reconnect()
                                dismiss()
                            } label: {
                                rowLabel("重新连接", icon: "arrow.clockwise", tint: Theme.azure, chevron: true)
                            }
                            .buttonStyle(.plain)

                            divider

                            Button {
                                Haptics.warning()
                                model.disconnect()
                                dismiss()
                            } label: {
                                rowLabel("断开连接", icon: "wifi.slash", tint: Theme.coral, chevron: false)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    section("账号") {
                        SettingsCard {
                            settingRow("登录状态", value: model.jwtReady ? "已登录" : "未登录")
                            divider
                            Button {
                                Haptics.warning()
                                model.logout()
                                dismiss()
                            } label: {
                                rowLabel("退出登录", icon: "rectangle.portrait.and.arrow.right", tint: Theme.coral, chevron: false)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    section("会话配置", footer: "当前会话的模型、思考与审批模式可在对话输入栏上方一键切换。") {
                        SettingsCard {
                            settingRow("运行模型", value: model.currentModelLabel)
                            divider
                            settingRow("思考强度", value: model.selectedThought)
                            divider
                            settingRow("审批模式", value: model.availableModes.first { $0.value == model.selectedMode }?.label ?? model.selectedMode)
                        }
                    }

                    section("用量") {
                        SettingsCard {
                            Button {
                                Haptics.light()
                                model.refreshUsage()
                                dismiss()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                    model.showUsageSheet = true
                                }
                            } label: {
                                rowLabel("用量与配额", icon: "chart.bar.xaxis", tint: Theme.textPrimary, chevron: true)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    section("真后台推送(可选)", footer: "配合仓库内 server/ 的 APNs 网关使用：锁屏后仍能实时上岛并推送审批状态。") {
                        SettingsCard {
                            Toggle(isOn: Binding(
                                get: { model.pushEnabled },
                                set: {
                                    Haptics.selection()
                                    model.updatePushSettings(enabled: $0, url: model.pushSyncURL, secret: model.pushSecret)
                                }
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

                    section("关于") {
                        SettingsCard {
                            settingRow("当前版本", value: "1.1.0")
                            divider
                            settingRow("协议", value: "ZCode Relay V2")
                            divider
                            settingRow("中继端点", value: "zcode.z.ai")
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
            .scrollIndicators(.hidden)
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
            .navigationTitle("设置")
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

    private var connectionColor: Color {
        switch model.bridgePhase {
        case .ready: return Theme.mint
        case .failed: return Theme.coral
        default: return Theme.amber
        }
    }

    private var endpointURL: String? {
        model.pairedDevice?.origin
            .replacingOccurrences(of: "https://", with: "wss://")
            .appending("/api/v1/remote/ws2")
    }

    private func section<Content: View>(_ title: String, footer: String? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .padding(.leading, 6)
            content()
            if let footer {
                Text(footer)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 8)
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.hairline).frame(height: 0.6)
    }

    private func settingRow(_ title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Text(value)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 13)
        .contentShape(Rectangle())
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
            .frame(maxWidth: 195)
        }
        .padding(.vertical, 11)
    }

    private func rowLabel(_ title: String, icon: String, tint: Color, chevron: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24)
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint)
            Spacer()
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
                .padding(.horizontal, 16)
        }
        .frostedSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous), strong: true, shadowRadius: 10)
    }
}
