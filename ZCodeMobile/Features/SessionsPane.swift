import SwiftUI
import ZCodeMobileCore

/// 右栏:最近会话(搜索 + 列表)
struct SessionsPane: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 标题行
            HStack(alignment: .center, spacing: 10) {
                if model.openConversation {
                    Button {
                        model.closeConversation()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 12, weight: .bold))
                            Text("会话列表")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(Capsule().fill(Color.white.opacity(0.10)))
                    }
                    .buttonStyle(bouncy())
                    .accessibilityLabel("返回会话列表")
                } else {
                    Text("会话")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                }
                Spacer()
                HStack(spacing: 8) {
                    StatusDot(color: Theme.mint)
                    Button {
                        model.newSession()
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(bouncy())
                    .accessibilityLabel("新建会话")
                }
            }
            .padding(.top, 6)

            // 工作区 chips(侧栏内的工作区切换)
            if model.workspaces.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        workspaceChipAll
                        ForEach(model.workspaces) { ws in
                            workspaceChip(ws)
                        }
                    }
                }
            }

            // 搜索框
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                TextField("搜索会话内容", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($searchFocused)
                if !model.searchText.isEmpty {
                    Button {
                        model.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 1)
            )

            // 会话列表
            if model.filteredTasks.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.filteredTasks.enumerated()), id: \.element.id) { index, task in
                            Button {
                                ZDlog("[ZCodeMobile][tap] row tapped %@", task.taskId)
                                model.openTask(task)
                            } label: {
                                SessionRow(task: task)
                            }
                            .buttonStyle(SessionRowPressStyle())
                                .transition(.asymmetric(
                                    insertion: .opacity.combined(with: .move(edge: .bottom)),
                                    removal: .opacity))
                                .animation(.spring(response: 0.35, dampingFraction: 0.85).delay(Double(min(index, 8)) * 0.03),
                                           value: model.filteredTasks.count)
                            if task.id != model.filteredTasks.last?.id {
                                Rectangle()
                                    .fill(Color.white.opacity(0.05))
                                    .frame(height: 0.5)
                                    .padding(.leading, 22)
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            Spacer(minLength: 0)

            // footer:账号 + 配对
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Color.white.opacity(0.10))
                    Text("Z").font(.system(size: 14, weight: .black)).foregroundStyle(Theme.textPrimary)
                }
                .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text("ZCode 账号")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    Text(model.pairedDevice?.deviceName ?? "未配对")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    model.showDeviceSheet = true
                } label: {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.white.opacity(0.06)))
                }
                .buttonStyle(bouncy())
                .accessibilityLabel("配对设备")
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 16)
    }

    // MARK: 工作区 chips

    private var workspaceChipAll: some View {
        Button {
            model.activeWorkspaceID = nil
        } label: {
            Text("全部")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(model.activeWorkspaceID == nil ? .black : Theme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(model.activeWorkspaceID == nil ? Color.white : Color.white.opacity(0.07)))
        }
        .buttonStyle(.plain)
    }

    private func workspaceChip(_ ws: WorkspaceInfo) -> some View {
        Button {
            model.activeWorkspaceID = (model.activeWorkspaceID == ws.id) ? nil : ws.id
        } label: {
            Text(ws.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(model.activeWorkspaceID == ws.id ? .black : Theme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(model.activeWorkspaceID == ws.id ? Color.white : Color.white.opacity(0.07)))
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            if model.isSyncingTasks {
                ProgressView()
                Text("正在同步会话列表…")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                Text("桌面端已连接,列表马上到")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            } else {
            Image(systemName: model.searchText.isEmpty ? "sparkles.rectangle.stack" : "magnifyingglass")
                .font(.system(size: 30))
                .foregroundStyle(Theme.textTertiary)
            Text(model.searchText.isEmpty ? "还没有会话" : "没有匹配的会话")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
            }
            if model.searchText.isEmpty {
                Text(model.relayPhase)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 会话行按压样式(替代手势,避免吞点击)
struct SessionRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(configuration.isPressed ? Color.white.opacity(0.06) : .clear)
            )
            .scaleEffect(configuration.isPressed ? 0.995 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// 会话行:标题 + session id + 相对时间
struct SessionRow: View {
    let task: TaskEntry
    @State private var pressed = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    if task.pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.amber)
                    }
                    Text(task.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if task.status == "running" || task.status == "prewarming" {
                        PillBadge(text: "运行中", tint: Theme.mint, filled: true)
                    }
                }
                Text("session-\(shortID)")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(relativeTime)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(pressed ? Color.white.opacity(0.06) : .clear)
        )

    }

    private var shortID: String {
        var id = task.taskId
        for prefix in ["sess_", "session_"] where id.hasPrefix(prefix) {
            id = String(id.dropFirst(prefix.count))
        }
        return String(id.prefix(8))
    }

    private var relativeTime: String {
        let date = Date(timeIntervalSince1970: task.updatedAt / 1000)
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
