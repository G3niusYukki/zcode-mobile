import SwiftUI
import ZCodeMobileCore

/// 右侧交互区首页(未打开会话时):毛玻璃工作台总览 + 工作区切换 + 快捷续聊 + 实时连接卡
struct HomePane: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("zcode-mobile.glassBackdrop") private var backdropStyle: String = GlassBackdropStyle.aurora.rawValue
    @State private var showWorkspaces = false
    @State private var appeared = false
    @State private var reconnectSpin = 0.0

    private var runningCount: Int {
        model.tasks.filter { $0.status == "running" || $0.status == "prewarming" }.count
    }

    private var recentTask: TaskEntry? {
        model.filteredTasks.first(where: { $0.status == "running" || $0.status == "prewarming" })
            ?? model.filteredTasks.first
    }

    private var greetingText: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "早上好"
        case 12..<18: return "下午好"
        default: return "晚上好"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                brandHeader
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 10)

                if !model.workspaces.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        workspaceChip
                        if showWorkspaces {
                            workspaceDropdown
                                .transition(.asymmetric(
                                    insertion: .scale(scale: 0.95, anchor: .top).combined(with: .opacity),
                                    removal: .scale(scale: 0.96, anchor: .top).combined(with: .opacity)
                                ))
                        }
                    }
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 12)
                }

                heroSection
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 14)

                if let recent = recentTask {
                    continueSessionCard(recent)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 16)
                }

                quickTilesGrid
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 18)

                connectionCard
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 20)
            }
            .padding(.horizontal, 26)
            .padding(.top, 14)
            .padding(.bottom, 28)
            .frame(maxWidth: 680, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .animation(Motion.smooth, value: showWorkspaces)
        .onAppear {
            guard !appeared else { return }
            withAnimation(Motion.gentle) { appeared = true }
        }
    }

    // MARK: - 顶部品牌行

    private var brandHeader: some View {
        HStack(spacing: 12) {
            ZMark(size: 38)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("ZCodeMobile")
                        .font(.system(size: 23, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    PillBadge(text: "DUO", tint: Theme.azure)
                }
                Text("远程掌控桌面编程工作台")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer()
        }
    }

    // MARK: - Hero 区

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(greetingText)，欢迎回来")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text("从左侧选择一个会话继续，或直接开启新的编码任务")
                    .font(.system(size: 14.5))
                    .foregroundStyle(Theme.textSecondary)
            }

            PrimaryActionButton(title: "新建会话", systemName: "plus") {
                model.newSession()
            }
        }
        .padding(.top, 6)
    }

    // MARK: - 继续最近会话

    private func continueSessionCard(_ task: TaskEntry) -> some View {
        let running = task.status == "running" || task.status == "prewarming"
        return Button {
            model.openTask(task)
        } label: {
            GlassCard(padding: 16, cornerRadius: 20, strong: true, tint: running ? Theme.mint.opacity(0.06) : Theme.azure.opacity(0.05)) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill((running ? Theme.mint : Theme.azure).opacity(0.16))
                        Image(systemName: running ? "bolt.horizontal.circle.fill" : "clock.arrow.trianglehead.counterclockwise.rotate.90")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(running ? Theme.mint : Theme.azure)
                    }
                    .frame(width: 42, height: 42)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(running ? "正在运行的会话" : "继续最近会话")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(running ? Theme.mint : Theme.azure)
                            if running {
                                StatusDot(color: Theme.mint, pulsing: true, size: 6)
                            }
                        }
                        Text(task.title)
                            .font(.system(size: 15.5, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "arrow.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 30, height: 30)
                        .liquidGlassChrome(in: Circle())
                }
            }
        }
        .buttonStyle(bouncy(scale: 0.98))
    }

    // MARK: - 快捷总览卡片网格

    private var quickTilesGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            quickTile(
                icon: "bubble.left.and.bubble.right.fill",
                tint: Theme.azure,
                title: "会话总数",
                value: "\(model.tasks.count)",
                subtitle: runningCount > 0 ? "\(runningCount) 个正在运行" : "全部待机"
            ) {
                if let first = model.filteredTasks.first {
                    model.openTask(first)
                } else {
                    model.newSession()
                }
            }

            quickTile(
                icon: "chart.bar.xaxis",
                tint: Theme.mint,
                title: "用量与配额",
                value: quotaSummary,
                subtitle: "查看上下文与套餐"
            ) {
                Haptics.light()
                model.refreshUsage()
                model.showUsageSheet = true
            }

            quickTile(
                icon: "desktopcomputer",
                tint: Theme.indigo,
                title: "已配对桌面",
                value: model.pairedDevice?.deviceName ?? "未配对",
                subtitle: model.bridgePhase == .ready ? "中继在线" : model.relayPhase
            ) {
                Haptics.light()
                model.showDeviceSheet = true
            }

            quickTile(
                icon: "sparkles",
                tint: Theme.amber,
                title: "界面与毛玻璃",
                value: (GlassBackdropStyle(rawValue: backdropStyle) ?? .aurora).label,
                subtitle: "外观、字体与触感"
            ) {
                Haptics.light()
                model.showSettings = true
            }
        }
    }

    private var quotaSummary: String {
        if let first = model.usageReport?.quotaWindows.first {
            return "剩 \(Int(round(first.remainingPercent)))%"
        }
        if let report = model.usageReport, let used = report.used, let limit = report.limit, limit > 0 {
            return String(format: "剩 %.0f%%", max(0, 100 - used / limit * 100))
        }
        return "查看配额"
    }

    private func quickTile(
        icon: String,
        tint: Color,
        title: String,
        value: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            GlassCard(padding: 14, cornerRadius: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: icon)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(tint)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(tint.opacity(0.14)))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(value)
                            .font(.system(size: 16.5, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Text(title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                        Text(subtitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(bouncy(scale: 0.975))
    }

    // MARK: - 工作区切换器

    private var workspaceChip: some View {
        Button {
            Haptics.selection()
            withAnimation(Motion.smooth) {
                showWorkspaces.toggle()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.azure)
                Text(displayWorkspaceName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(displayWorkspacePath)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                StatusDot(color: statusColor, pulsing: model.bridgePhase == .ready, size: 7)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .rotationEffect(.degrees(showWorkspaces ? 180 : 0))
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .frostedSurface(in: RoundedRectangle(cornerRadius: 15, style: .continuous), shadowRadius: 8)
        }
        .buttonStyle(bouncy(scale: 0.985))
    }

    private var workspaceDropdown: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(model.workspaces) { ws in
                let isSelected = ws.id == model.activeWorkspaceID || (model.activeWorkspaceID == nil && ws == model.workspaces.first)
                Button {
                    model.switchWorkspace(ws)
                    withAnimation(Motion.snappy) { showWorkspaces = false }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: isSelected ? "folder.fill" : "folder")
                            .font(.system(size: 13))
                            .foregroundStyle(isSelected ? Theme.azure : Theme.textSecondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ws.label)
                                .font(.system(size: 13.5, weight: isSelected ? .semibold : .medium))
                                .foregroundStyle(Theme.textPrimary)
                            Text(ws.workspacePath)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.mint)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(isSelected ? Theme.azure.opacity(0.10) : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(7)
        .frostedSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous), strong: true, shadowRadius: 18)
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

    // MARK: - 连接状态卡

    private var connectionCard: some View {
        GlassCard(padding: 15, cornerRadius: 20) {
            HStack(spacing: 12) {
                StatusDot(color: statusColor, pulsing: model.bridgePhase == .ready, size: 9)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.relayPhase)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(desktopName)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button {
                    Haptics.light()
                    withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
                        reconnectSpin += 360
                    }
                    model.reconnect()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .rotationEffect(.degrees(reconnectSpin))
                        .frame(width: 34, height: 34)
                        .liquidGlassChrome(in: Circle(), interactive: true)
                }
                .buttonStyle(bouncy(scale: 0.92))
                .accessibilityLabel("重新连接")
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
}
