import SwiftUI
import ZCodeMobileCore

/// 会话侧栏:毛玻璃搜索 + 滑移工作区切换 + 选中高亮动画 + 下拉刷新
struct SessionsPane: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.horizontalSizeClass) private var hSize
    @FocusState private var searchFocused: Bool
    @Namespace private var workspaceNS
    @Namespace private var activeRowNS

    private var connectionColor: Color {
        switch model.bridgePhase {
        case .ready: return Theme.mint
        case .failed: return Theme.coral
        default: return Theme.amber
        }
    }

    private var connectionLabel: String {
        switch model.bridgePhase {
        case .ready: return "在线"
        case .failed: return "异常"
        default: return "连接中"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow
                .padding(.top, 6)

            if model.workspaces.count > 1 {
                workspaceChipsRow
            }

            searchBar

            if model.filteredTasks.isEmpty {
                emptyState
            } else {
                sessionList
            }

            footerCard
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    // MARK: - 头部栏

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 10) {
            if model.openConversation && hSize != .compact {
                Button {
                    model.closeConversation()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "house.fill")
                            .font(.system(size: 11.5, weight: .semibold))
                        Text("首页")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .liquidGlassChrome(in: Capsule(), interactive: true)
                }
                .buttonStyle(bouncy(scale: 0.94))
                .transition(.scale(scale: 0.9).combined(with: .opacity))
                .accessibilityLabel("返回首页")
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("会话")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    if !model.filteredTasks.isEmpty {
                        Text("\(model.filteredTasks.count)")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.textTertiary)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                }
                .transition(.opacity)
            }

            Spacer()

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        Haptics.light()
                        model.showDeviceSheet = true
                    } label: {
                        HStack(spacing: 6) {
                            StatusDot(color: connectionColor, pulsing: model.bridgePhase == .ready, size: 7)
                            Text(connectionLabel)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .liquidGlassChrome(in: Capsule(), tint: connectionColor.opacity(0.08), interactive: true)
                    }
                    .buttonStyle(bouncy(scale: 0.94))
                    .accessibilityLabel("连接状态")

                    Button {
                        model.newSession()
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 34, height: 34)
                            .liquidGlassChrome(in: Circle(), interactive: true)
                    }
                    .buttonStyle(bouncy(scale: 0.92))
                    .accessibilityLabel("新建会话")
                }
            }
        }
        .animation(Motion.smooth, value: model.openConversation)
    }

    // MARK: - 工作区滑移 Chips

    private var workspaceChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                workspaceChip(id: nil, title: "全部")
                ForEach(model.workspaces) { ws in
                    workspaceChip(id: ws.id, title: ws.label)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func workspaceChip(id: String?, title: String) -> some View {
        let isSelected = model.activeWorkspaceID == id
        return Button {
            Haptics.selection()
            withAnimation(Motion.smooth) {
                if id == nil {
                    model.activeWorkspaceID = nil
                } else {
                    model.activeWorkspaceID = (model.activeWorkspaceID == id) ? nil : id
                }
            }
        } label: {
            Text(title)
                .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Theme.onAccent : Theme.textSecondary)
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(Theme.accentFill)
                            .matchedGeometryEffect(id: "ws-active-pill", in: workspaceNS)
                            .shadow(color: Theme.shadowColor, radius: 6, y: 3)
                    } else {
                        Capsule()
                            .fill(Theme.cardFill)
                            .overlay(Capsule().strokeBorder(Theme.specularBorderGradient, lineWidth: 0.8))
                    }
                }
        }
        .buttonStyle(bouncy(scale: 0.95))
    }

    // MARK: - 毛玻璃搜索框

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(searchFocused ? Theme.azure : Theme.textTertiary)
                TextField("搜索会话内容", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14.5))
                    .focused($searchFocused)
                if !model.searchText.isEmpty {
                    Button {
                        Haptics.light()
                        withAnimation(Motion.snappy) { model.searchText = "" }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 13)
            .frame(height: 42)
            .background {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(Theme.inputFill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(
                        searchFocused ? Theme.azure.opacity(0.6) : Theme.cardStroke,
                        lineWidth: searchFocused ? 1.25 : 0.9
                    )
            }
            .shadow(color: searchFocused ? Theme.azure.opacity(0.16) : .clear, radius: 10, y: 3)

            if searchFocused {
                Button("取消") {
                    Haptics.light()
                    withAnimation(Motion.snappy) {
                        model.searchText = ""
                        searchFocused = false
                    }
                }
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Theme.azure)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(Motion.snappy, value: searchFocused)
        .animation(Motion.snappy, value: model.searchText.isEmpty)
    }

    // MARK: - 会话列表

    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(model.filteredTasks) { task in
                    let isSelected = model.openConversation && model.selectedTask?.taskId == task.taskId
                    Button {
                        ZDlog("[ZCodeMobile][tap] row tapped %@", task.taskId)
                        model.openTask(task)
                    } label: {
                        SessionRow(
                            task: task,
                            isSelected: isSelected,
                            workspaceLabel: workspaceBadge(for: task),
                            selectionNamespace: activeRowNS
                        )
                    }
                    .buttonStyle(SessionRowPressStyle())
                    .contextMenu {
                        Button {
                            model.openTask(task)
                        } label: {
                            Label("打开会话", systemImage: "bubble.left.and.bubble.right")
                        }
                        Button {
                            UIPasteboard.general.string = task.taskId
                            model.showToast("已复制会话 ID", icon: "doc.on.doc.fill", tint: Theme.mint)
                        } label: {
                            Label("复制会话 ID", systemImage: "doc.on.doc")
                        }
                        Button {
                            UIPasteboard.general.string = task.title
                            model.showToast("已复制会话标题", icon: "checkmark.circle.fill", tint: Theme.mint)
                        } label: {
                            Label("复制标题", systemImage: "text.quote")
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
            }
            .padding(.vertical, 4)
            .animation(Motion.smooth, value: model.filteredTasks.map(\.id))
        }
        .scrollIndicators(.hidden)
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .refreshable {
            Haptics.light()
            model.reconnect()
        }
    }

    private func workspaceBadge(for task: TaskEntry) -> String? {
        guard model.activeWorkspaceID == nil, model.workspaces.count > 1 else { return nil }
        return model.workspaces.first {
            ($0.workspaceIdentity ?? $0.workspacePath) == (task.workspaceIdentity ?? task.workspacePath)
        }?.label
    }

    // MARK: - 底部毛玻璃账户卡

    private var footerCard: some View {
        HStack(spacing: 10) {
            ZMark(size: 30)
            VStack(alignment: .leading, spacing: 1.5) {
                Text(model.pairedDevice?.deviceName ?? "ZCode 账号")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(model.relayPhase)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button {
                Haptics.light()
                model.showDeviceSheet = true
            } label: {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 32, height: 32)
                    .liquidGlassChrome(in: Circle(), interactive: true)
            }
            .buttonStyle(bouncy(scale: 0.92))
            .accessibilityLabel("配对设备")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frostedSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous), strong: false, shadowRadius: 8)
    }

    // MARK: - 空态与微光骨架

    private var emptyState: some View {
        VStack(spacing: 14) {
            if model.isSyncingTasks {
                VStack(spacing: 10) {
                    ForEach(0..<5, id: \.self) { idx in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 7) {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Theme.cardStroke)
                                    .frame(width: idx.isMultiple(of: 2) ? 168 : 132, height: 14)
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Theme.cardFill)
                                    .frame(width: 92, height: 10)
                            }
                            Spacer()
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Theme.cardFill)
                                .frame(width: 38, height: 10)
                        }
                        .padding(14)
                        .frostedSurface(in: RoundedRectangle(cornerRadius: 16, style: .continuous), shadowRadius: 4)
                        .shimmering()
                    }
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在同步会话列表…")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.top, 8)
                }
                .padding(.top, 8)
                Spacer()
            } else {
                Spacer()
                Image(systemName: model.searchText.isEmpty ? "sparkles.rectangle.stack" : "magnifyingglass")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .symbolEffect(.pulse, value: model.filteredTasks.isEmpty)
                Text(model.searchText.isEmpty ? "还没有会话" : "没有匹配的会话")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                if model.searchText.isEmpty {
                    Text(model.relayPhase)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 会话行按压样式(避免吞点击,带柔和弹压感)
struct SessionRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.78), value: configuration.isPressed)
    }
}

/// 会话行:选中态滑移毛玻璃卡片 + 实时状态指示 + 标题 + 元数据
struct SessionRow: View {
    let task: TaskEntry
    var isSelected: Bool = false
    var workspaceLabel: String? = nil
    var selectionNamespace: Namespace.ID

    private var isRunning: Bool {
        task.status == "running" || task.status == "prewarming"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if isRunning {
                Capsule()
                    .fill(Theme.mint)
                    .frame(width: 3, height: 28)
                    .shadow(color: Theme.mint.opacity(0.6), radius: 4)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    if task.pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(Theme.amber)
                    }
                    Text(task.title)
                        .font(.system(size: 14.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if isRunning {
                        PillBadge(text: "运行中", tint: Theme.mint, filled: true)
                    }
                }

                HStack(spacing: 6) {
                    Text("session-\(shortID)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                    if let ws = workspaceLabel {
                        Text("·")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                        Text(ws)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Theme.cardFill))
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 6)

            Text(relativeTime)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(isSelected ? Theme.azure : Theme.textTertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.cardFillStrong)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Theme.azure.opacity(0.11))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [Theme.azure.opacity(0.45), Theme.glassHighlightTop.opacity(0.5), Theme.azure.opacity(0.18)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
                    .matchedGeometryEffect(id: "active-session-bg", in: selectionNamespace)
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.cardFill.opacity(0.55))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 0.6)
                    )
            }
        }
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
