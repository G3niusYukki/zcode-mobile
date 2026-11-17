import SwiftUI
import ZCodeMobileCore

/// 右侧交互区首页(未打开会话时):品牌 + 欢迎 + 新建会话 + 连接/账户
struct HomePane: View {
    @EnvironmentObject var model: AppModel
    @State private var showWorkspaces = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                // 品牌行
                HStack(spacing: 10) {
                    ZMark(size: 34)
                    Text("ZCodeMobile")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    PillBadge(text: "ZCODE", tint: Theme.textSecondary)
                    Spacer()
                }
                .padding(.top, 8)

                Spacer(minLength: 30)

                VStack(alignment: .leading, spacing: 8) {
                    Text("欢迎回来")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("选择左侧会话继续,或开始一个新任务")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.bottom, 20)

                PrimaryActionButton(title: "新建会话", systemName: "plus") {
                    model.newSession()
                }

                Spacer(minLength: 0)

                connectionCard
                    .padding(.bottom, 6)
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 18)
            .padding(.trailing, 76) // 右侧悬浮操作栏让位
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: showWorkspaces)
    }

    // MARK: 工作区

    private var workspaceChip: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                showWorkspaces.toggle()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.azure)
                Text(displayWorkspaceName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(displayWorkspacePath)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                StatusDot(color: model.bridgePhase == .ready ? Theme.mint : Theme.amber,
                          pulsing: model.bridgePhase == .ready)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .rotationEffect(.degrees(showWorkspaces ? 180 : 0))
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 1)
            )
        }
        .buttonStyle(bouncy())
    }

    /// 内联下拉(替代 popover,保证可点击)
    private var workspaceDropdown: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(model.workspaces) { ws in
                Button {
                    model.switchWorkspace(ws)
                    withAnimation { showWorkspaces = false }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "folder")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ws.label)
                                .font(.system(size: 13.5, weight: .medium))
                                .foregroundStyle(Theme.textPrimary)
                            Text(ws.workspacePath)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if ws.id == model.activeWorkspaceID || (model.activeWorkspaceID == nil && ws == model.workspaces.first) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Theme.mint)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if model.workspaces.isEmpty {
                Text("暂无工作区").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                    .padding(12)
            }
        }
        .padding(6)
        .frame(maxWidth: 380, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.055, green: 0.10, blue: 0.17))
                .shadow(color: .black.opacity(0.4), radius: 20, y: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 1)
        )
    }

    private var displayWorkspaceName: String {
        model.workspaces.first(where: { $0.id == model.activeWorkspaceID })?.label
            ?? model.workspaces.first?.label
            ?? "默认工作区"
    }

    private var displayWorkspacePath: String {
        let path = model.workspaces.first(where: { $0.id == model.activeWorkspaceID })?.workspacePath
            ?? model.workspaces.first?.workspacePath
            ?? ""
        return path.replacingOccurrences(of: "/Users/", with: "~/")
    }

    // MARK: 连接状态

    private var connectionCard: some View {
        GlassCard(padding: 14, cornerRadius: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    StatusDot(color: statusColor, pulsing: model.bridgePhase == .ready)
                    Text(model.relayPhase)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Button {
                        model.reconnect()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(bouncy())
                }
                Text(desktopName)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    private var desktopName: String {
        if let d = model.pairedDevice { return "\(d.deviceName ?? "桌面端") · \(d.deviceSid)" }
        return "未配对桌面端"
    }

    private var statusColor: Color {
        switch model.bridgePhase {
        case .ready: return Theme.mint
        case .failed: return Theme.coral
        default: return Theme.amber
        }
    }

    // MARK: 账户

    private var accountRow: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.white.opacity(0.10))
                Text("Z").font(.system(size: 15, weight: .black)).foregroundStyle(Theme.textPrimary)
            }
            .frame(width: 34, height: 34)
            Text("ZCode 账号")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
        }
    }
}
