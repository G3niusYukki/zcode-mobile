import SwiftUI
import ZCodeMobileCore
import PhotosUI
import UniformTypeIdentifiers

/// 对话页:悬浮 Liquid Glass 顶栏/底栏 + 消息穿流折射 + 智能回底 + 快捷模型/思考/审批控制条
struct ConversationScreen: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.horizontalSizeClass) private var hSize
    @ObservedObject private var hinge = HingeObserver.shared
    @Namespace private var composerNS

    @State private var showContext = false
    @State private var copiedRowId: Int?
    @State private var lastScrollSignature = ""
    @State private var autoRetried = false
    @State private var showActions = false
    @State private var openModelsOnSheet = false
    @State private var isNearBottom = true
    @State private var scrollRequestID = 0
    @FocusState private var composerFocused: Bool

    private var state: ConversationState? { model.conversationStateForUI }

    private var currentSessionKey: String { model.selectedTask?.taskId ?? "none" }
    private var draftBinding: Binding<String> {
        Binding(get: { model.draft(for: currentSessionKey) },
                set: { model.setDraft($0, for: currentSessionKey) })
    }
    private var visibleRows: [ConversationRow] {
        (state?.rows ?? []).filter { $0.visibility == "visible" }
    }
    private var rows: [ConversationRow] { state?.rows ?? [] }
    private var interactions: [PendingInteraction] { state?.pendingInteractions ?? [] }
    private var hasDraftText: Bool {
        !model.draft(for: currentSessionKey).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var isAwaitingStreamChunk: Bool {
        guard state?.isRunning == true else { return false }
        if let last = visibleRows.last, last.kind == "assistantText", last.state == "streaming" {
            return false
        }
        return true
    }

    var body: some View {
        messageScroll
            .safeAreaInset(edge: .top, spacing: 0) {
                floatingHeader
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                floatingComposer
            }
            .overlay(alignment: .bottomTrailing) {
                if !isNearBottom && !visibleRows.isEmpty {
                    scrollToBottomButton
                        .padding(.trailing, 20)
                        .padding(.bottom, 124)
                        .transition(.scale(scale: 0.78).combined(with: .opacity))
                }
            }
            .animation(Motion.snappy, value: isNearBottom)
    }

    // MARK: - 悬浮 Liquid Glass 头部

    private var floatingHeader: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                if hSize == .compact {
                    Button {
                        model.closeConversation()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14.5, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 38, height: 38)
                            .contentShape(Circle())
                            .liquidGlassChrome(in: Circle(), interactive: true)
                    }
                    .buttonStyle(bouncy(scale: 0.92))
                    .accessibilityLabel("返回会话列表")
                } else {
                    Button {
                        model.toggleSidebar()
                    } label: {
                        Image(systemName: model.sidebarCollapsed ? "sidebar.leading" : "sidebar.left")
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 38, height: 38)
                            .contentShape(Circle())
                            .liquidGlassChrome(in: Circle(), interactive: true)
                    }
                    .buttonStyle(bouncy(scale: 0.92))
                    .accessibilityLabel(model.sidebarCollapsed ? "展开侧栏" : "收起侧栏")
                }

                // 标题毛玻璃胶囊(点击可快捷展开/收起上下文详情)
                Button {
                    Haptics.selection()
                    withAnimation(Motion.smooth) { showContext.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(state?.title ?? model.selectedTask?.title ?? "会话")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                            HStack(spacing: 5) {
                                Text(hSize == .compact ? shortSessionID : "session-\(shortSessionID)")
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(Theme.textTertiary)
                                    .lineLimit(1)
                                Text("·")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(Theme.textTertiary)
                                Text(shortModelName)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(Theme.azure)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 4)
                        statusPill
                            .fixedSize()
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .liquidGlassChrome(in: RoundedRectangle(cornerRadius: 21, style: .continuous), interactive: true)
                }
                .buttonStyle(bouncy(scale: 0.99))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .background(alignment: .top) {
            LinearGradient(
                colors: [
                    Theme.bgSolid.opacity(0.86),
                    Theme.bgSolid.opacity(0.50),
                    .clear,
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
        }
        .animation(Motion.smooth, value: state?.isRunning)
    }

    private var statusPill: some View {
        let running = state?.isRunning == true
        return HStack(spacing: 5) {
            StatusDot(color: running ? Theme.mint : Theme.textTertiary, pulsing: running, size: 6.5)
            Text(running ? "运行中" : "待机")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(running ? Theme.mint : Theme.textSecondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4.5)
        .background(
            Capsule().fill(running ? Theme.mint.opacity(0.14) : Theme.cardFill)
        )
    }

    private var shortSessionID: String {
        String((model.selectedTask?.taskId ?? state?.sessionId ?? "").replacingOccurrences(of: "sess_", with: "").prefix(8))
    }

    private var shortModelName: String {
        let full = model.currentModelLabel
        if let slash = full.lastIndex(of: "/") {
            return String(full[full.index(after: slash)...])
        }
        return full
    }

    // MARK: - 消息流

    private var messageScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if state?.hasMoreOlder == true {
                        Button {
                            Haptics.light()
                            model.loadOlder()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.up.circle")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("加载更早的消息")
                                    .font(.system(size: 12.5, weight: .medium))
                            }
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .liquidGlassChrome(in: Capsule(), interactive: true)
                        }
                        .buttonStyle(bouncy(scale: 0.96))
                        .frame(maxWidth: .infinity)
                    }

                    if rows.isEmpty && state == nil {
                        loadingPlaceholder
                    }

                    ForEach(visibleRows) { row in
                        MessageRow(
                            row: row,
                            copied: copiedRowId == row.rowId,
                            onCopy: {
                                UIPasteboard.general.string = row.text
                                Haptics.success()
                                withAnimation(Motion.bouncy) {
                                    copiedRowId = row.rowId
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                                    withAnimation(Motion.snappy) {
                                        if copiedRowId == row.rowId { copiedRowId = nil }
                                    }
                                }
                            },
                            onBranchCopy: {
                                UIPasteboard.general.string = "fork: \(row.rowId)"
                                model.showToast("已复制分支点 #\(row.rowId)", icon: "arrow.triangle.branch", tint: Theme.azure)
                            }
                        )
                        .id(row.rowId)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 8)),
                            removal: .opacity
                        ))
                    }

                    if isAwaitingStreamChunk {
                        TypingIndicator()
                            .transition(.scale(scale: 0.85, anchor: .leading).combined(with: .opacity))
                    }

                    ForEach(interactions) { interaction in
                        ApprovalCard(interaction: interaction) { option in
                            Haptics.medium()
                            model.resolve(interaction: interaction, option: option)
                        } onFreeText: { text in
                            Haptics.medium()
                            model.answerFreeText(text, interaction: interaction)
                        }
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.96).combined(with: .opacity),
                            removal: .opacity
                        ))
                    }

                    Color.clear.frame(height: 16).id("bottom-anchor")
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .animation(Motion.smooth, value: visibleRows.count)
                .animation(Motion.smooth, value: interactions.count)
                .animation(Motion.snappy, value: isAwaitingStreamChunk)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
            .onScrollGeometryChange(for: Bool.self) { geo in
                let remaining = geo.contentSize.height - geo.visibleRect.maxY
                return remaining < 90
            } action: { _, nearBottom in
                if nearBottom != isNearBottom {
                    isNearBottom = nearBottom
                }
            }
            .onChange(of: scrollRequestID) { _, _ in
                withAnimation(Motion.smooth) {
                    proxy.scrollTo("bottom-anchor", anchor: .bottom)
                }
            }
            .task(id: model.selectedTask?.taskId) {
                try? await Task.sleep(nanoseconds: 120_000_000)
                proxy.scrollTo("bottom-anchor", anchor: .bottom)
            }
            .onChange(of: model.keyboardVisible) { _, visible in
                guard visible else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    withAnimation(Motion.smooth) {
                        proxy.scrollTo("bottom-anchor", anchor: .bottom)
                    }
                }
            }
            .onChange(of: model.conversationTick) { _, _ in
                let last = rows.last
                let signature = "\(rows.count)-\(last?.rowId ?? -1)-\(last?.text.count ?? 0)-\(interactions.count)"
                guard signature != lastScrollSignature else { return }
                let wasFirstLoad = lastScrollSignature.isEmpty
                lastScrollSignature = signature
                guard isNearBottom || wasFirstLoad else { return }
                if wasFirstLoad {
                    proxy.scrollTo("bottom-anchor", anchor: .bottom)
                } else {
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo("bottom-anchor", anchor: .bottom)
                    }
                }
            }
        }
    }

    private var scrollToBottomButton: some View {
        Button {
            Haptics.light()
            scrollRequestID += 1
        } label: {
            Image(systemName: "arrow.down")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 40, height: 40)
                .contentShape(Circle())
                .liquidGlassChrome(in: Circle(), interactive: true)
                .shadow(color: Theme.shadowColor, radius: 12, y: 6)
        }
        .buttonStyle(bouncy(scale: 0.9))
        .accessibilityLabel("回到底部")
    }

    private var loadingPlaceholder: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.cardStroke)
                    .frame(width: 180, height: 14)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.cardFill)
                    .frame(maxWidth: .infinity)
                    .frame(height: 12)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.cardFill)
                    .frame(width: 220, height: 12)
            }
            .padding(16)
            .frostedSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous), shadowRadius: 6)
            .shimmering()

            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在打开会话…")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.top, 8)

            Button {
                Haptics.light()
                model.retryCurrentSession()
            } label: {
                Text("加载卡住了？点此重试")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.azure)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .liquidGlassChrome(in: Capsule(), tint: Theme.azure.opacity(0.08), interactive: true)
            }
            .buttonStyle(bouncy())
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 44)
        .task(id: model.selectedTask?.taskId) {
            autoRetried = false
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if state?.sessionId == nil, !autoRetried {
                autoRetried = true
                model.retryCurrentSession()
            }
        }
    }

    // MARK: - 悬浮 Liquid Glass 输入区

    private var floatingComposer: some View {
        VStack(spacing: 8) {
            if showContext {
                sessionInfoPanel
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.94, anchor: .bottom).combined(with: .opacity),
                        removal: .scale(scale: 0.96, anchor: .bottom).combined(with: .opacity)
                    ))
            }

            quickControlsStrip

            if !model.pendingAttachments.isEmpty {
                attachmentsRow
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            GlassEffectContainer(spacing: 10) {
                HStack(alignment: .bottom, spacing: 10) {
                    Button {
                        Haptics.light()
                        openModelsOnSheet = false
                        showActions = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 42, height: 42)
                            .contentShape(Circle())
                            .liquidGlassChrome(in: Circle(), interactive: true)
                    }
                    .buttonStyle(bouncy(scale: 0.92))
                    .accessibilityLabel("更多操作与附件")

                    HStack(alignment: .bottom, spacing: 8) {
                        TextField("描述你想要构建的内容", text: draftBinding, axis: .vertical)
                            .font(.system(size: 15))
                            .textFieldStyle(.plain)
                            .lineLimit(1...5)
                            .focused($composerFocused)
                            .submitLabel(.send)
                            .onSubmit { sendDraft() }
                            .padding(.vertical, 8)
                            .padding(.leading, 4)
                            .reservedRegionAware()

                        if hasDraftText {
                            Button {
                                sendDraft()
                            } label: {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(Theme.onAccent)
                                    .frame(width: 34, height: 34)
                                    .background(Circle().fill(Theme.accentFill))
                                    .shadow(color: Theme.shadowColor, radius: 6, y: 2)
                            }
                            .buttonStyle(bouncy(scale: 0.9))
                            .glassEffectID("composer-action", in: composerNS)
                            .glassEffectTransition(.matchedGeometry)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                            .accessibilityLabel("发送消息")
                        } else if state?.control.canStop == true {
                            Button {
                                Haptics.medium()
                                model.stop()
                            } label: {
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(Theme.coral)
                                    .frame(width: 34, height: 34)
                                    .background(Circle().fill(Theme.coral.opacity(0.16)))
                            }
                            .buttonStyle(bouncy(scale: 0.9))
                            .glassEffectID("composer-action", in: composerNS)
                            .glassEffectTransition(.matchedGeometry)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                            .accessibilityLabel("停止")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .liquidGlassChrome(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .strokeBorder(
                                composerFocused ? Theme.azure.opacity(0.5) : Color.clear,
                                lineWidth: 1.2
                            )
                    }
                    .shadow(color: composerFocused ? Theme.azure.opacity(0.16) : Theme.shadowColor, radius: composerFocused ? 14 : 10, y: 5)
                }
            }
            .animation(Motion.bouncy, value: hasDraftText)
            .animation(Motion.snappy, value: composerFocused)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .padding(.top, 10)
        .background(alignment: .bottom) {
            LinearGradient(
                colors: [
                    .clear,
                    Theme.bgSolid.opacity(0.68),
                    Theme.bgSolid.opacity(0.92),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
        }
        .animation(Motion.smooth, value: showContext)
        .animation(Motion.smooth, value: model.pendingAttachments.count)
        .sheet(isPresented: $showActions) {
            ComposerActionsSheet(initialShowModels: openModelsOnSheet)
                .environmentObject(model)
                .presentationDetents([.height(380), .medium])
                .presentationBackground(.ultraThinMaterial)
                .presentationCornerRadius(28)
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - 快捷控制毛玻璃条(上下文/模型/思考/审批模式/文件变更)

    private var quickControlsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                Button {
                    Haptics.selection()
                    withAnimation(Motion.smooth) { showContext.toggle() }
                    if !showContext { return }
                    model.refreshUsage()
                } label: {
                    HStack(spacing: 4) {
                        if let ctx = model.contextUsageSnapshot {
                            Circle()
                                .trim(from: 0, to: ctx.ratio)
                                .stroke(Theme.azure, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .background(Circle().stroke(Theme.cardStroke, lineWidth: 2))
                                .frame(width: 11, height: 11)
                            Text("\(Int(round(ctx.ratio * 100)))%")
                                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                        } else {
                            Image(systemName: "info.circle")
                                .font(.system(size: 10.5, weight: .semibold))
                            Text("上下文")
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8.5, weight: .bold))
                            .rotationEffect(.degrees(showContext ? 90 : 0))
                    }
                    .foregroundStyle(showContext ? Theme.azure : Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5.5)
                    .background(Capsule().fill(showContext ? Theme.azure.opacity(0.14) : Theme.cardFillStrong))
                    .overlay(Capsule().strokeBorder(showContext ? Theme.azure.opacity(0.35) : Theme.cardStroke, lineWidth: 0.8))
                }
                .buttonStyle(bouncy(scale: 0.95))

                Button {
                    Haptics.light()
                    openModelsOnSheet = true
                    showActions = true
                } label: {
                    chipLabel(icon: "cpu", text: shortModelName, tint: Theme.azure)
                }
                .buttonStyle(bouncy(scale: 0.95))

                Menu {
                    let levels = model.thoughtLevelsRemote.isEmpty ? model.thoughtLevels : model.thoughtLevelsRemote
                    ForEach(levels, id: \.self) { level in
                        Button {
                            Haptics.selection()
                            model.applyThought(level)
                        } label: {
                            Label(thoughtLabel(level), systemImage: level == model.selectedThought ? "checkmark" : "brain")
                        }
                    }
                } label: {
                    chipLabel(icon: "brain", text: thoughtLabel(model.selectedThought), tint: Theme.indigo)
                }

                Menu {
                    ForEach(model.availableModes) { meta in
                        Button {
                            Haptics.selection()
                            model.applyMode(meta.value)
                        } label: {
                            Label(meta.label, systemImage: meta.value == model.selectedMode ? "checkmark" : "hand.raised")
                        }
                    }
                } label: {
                    chipLabel(icon: "hand.raised", text: modeLabel(model.selectedMode), tint: Theme.mint)
                }

                if let chip = fileChangeChip {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.amber)
                        Text(chip)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5.5)
                    .background(Capsule().fill(Theme.amber.opacity(0.11)))
                    .overlay(Capsule().strokeBorder(Theme.amber.opacity(0.28), lineWidth: 0.8))
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
    }

    private func chipLabel(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 4.5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: 118)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5.5)
        .background(Capsule().fill(Theme.cardFillStrong))
        .overlay(Capsule().strokeBorder(Theme.cardStroke, lineWidth: 0.8))
    }

    /// 悬浮上下文与剩余额度毛玻璃浮窗(对齐桌面端弹窗:上下文容量/来源占比/缓存命中率 + 5h/每周/MCP 剩余额度 + 更多)
    private var sessionInfoPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let ctx = model.contextUsageSnapshot {
                let pct = Int(round(ctx.ratio * 100))
                HStack(alignment: .firstTextBaseline) {
                    Text("上下文容量")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text("\(formatShortTokens(ctx.usedTokens))/\(formatShortTokens(ctx.maxTokens)) (\(pct)%)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .monospacedDigit()
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.cardFill)
                        Capsule()
                            .fill(ctx.ratio > 0.85 ? Theme.coral : Theme.azure)
                            .frame(width: max(6, geo.size.width * ctx.ratio))
                    }
                }
                .frame(height: 6)

                if !ctx.breakdown.isEmpty {
                    VStack(spacing: 5) {
                        ForEach(Array(ctx.breakdown.prefix(5).enumerated()), id: \.element.id) { idx, item in
                            HStack(spacing: 7) {
                                Circle()
                                    .fill(Theme.azure.opacity(max(0.25, 1.0 - Double(idx) * 0.16)))
                                    .frame(width: 6.5, height: 6.5)
                                Text(item.label)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textSecondary)
                                Spacer()
                                Text(item.percent * 100 < 0.05 ? "0%" : String(format: "%.1f%%", item.percent * 100))
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(Theme.textPrimary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }

                if let hit = ctx.cacheHitRate {
                    HStack {
                        Text("平均缓存命中率")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text(String(format: "%.1f%%", hit * 100))
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary)
                    }
                }
            } else {
                HStack {
                    Label("会话上下文", systemImage: "sparkles.rectangle.stack")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text("\(rows.count) 行 · \(state?.control.phase ?? "--")")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                }
                infoRow("工作区", value: workspaceShortPath)
                infoRow("会话", value: model.selectedTask?.taskId ?? "--")
            }

            if let report = model.usageReport, !report.quotaWindows.isEmpty {
                Rectangle().fill(Theme.hairline).frame(height: 0.6)
                HStack(spacing: 6) {
                    Text("剩余额度")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if let reset = report.resetStatus, reset.totalCount > 0 {
                        Text("获得\(reset.totalCount)次重置")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Theme.mint)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Theme.mint.opacity(0.14)))
                    }
                    Spacer()
                    Button {
                        Haptics.light()
                        withAnimation(Motion.snappy) { showContext = false }
                        model.refreshUsage()
                        model.showUsageSheet = true
                    } label: {
                        HStack(spacing: 2) {
                            Text("更多")
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                        }
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.azure)
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 8) {
                    ForEach(report.quotaWindows.prefix(3)) { w in
                        let c: Color = w.accentKey == "green" ? Theme.mint : (w.accentKey == "orange" ? Theme.amber : Theme.azure)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(w.label)
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                            Text("\(Int(round(w.remainingPercent)))%")
                                .font(.system(size: 13.5, weight: .bold, design: .rounded))
                                .foregroundStyle(Theme.textPrimary)
                                .monospacedDigit()
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Theme.cardFill)
                                    Capsule().fill(c).frame(width: max(4, geo.size.width * w.remainingPercent / 100.0))
                                }
                            }
                            .frame(height: 4)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                Rectangle().fill(Theme.hairline).frame(height: 0.6)
                HStack {
                    Text(workspaceShortPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        Haptics.light()
                        withAnimation(Motion.snappy) { showContext = false }
                        model.refreshUsage()
                        model.showUsageSheet = true
                    } label: {
                        Text("查看完整统计 ›")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Theme.azure)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .frostedSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous), strong: true, shadowRadius: 16, liveBlur: true)
    }

    private func formatShortTokens(_ n: Int) -> String {
        if n >= 10_000 {
            let wan = Double(n) / 10_000
            return wan >= 100 || abs(wan.rounded() - wan) < 0.05
                ? String(format: "%.0f万", wan)
                : String(format: "%.1f万", wan)
        }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 58, alignment: .leading)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var fileChangeChip: String? {
        let writes = rows.filter {
            $0.kind == "toolCall"
                && (($0.toolName ?? "").contains("Write") || ($0.toolName ?? "").contains("Edit"))
                && $0.state == "success"
        }
        return writes.isEmpty ? nil : "\(writes.count) 个文件"
    }

    private func thoughtLabel(_ level: String) -> String {
        switch level {
        case "max": return "最深思考"
        case "high": return "深度思考"
        case "medium": return "标准思考"
        case "low": return "浅思考"
        case "none", "off", "nothink": return "关闭思考"
        default: return level
        }
    }

    private func modeLabel(_ mode: String) -> String {
        if let option = model.availableModes.first(where: { $0.value == mode }) {
            return option.label
        }
        switch mode {
        case "bypassPermissions", "full-access", "agent-full-access", "yolo": return "完全访问"
        case "acceptEdits", "auto", "autoEdit", "dontAsk", "guarded", "agent", "edit": return "自动审批"
        case "plan": return "计划"
        case "default", "build": return "默认"
        default: return mode
        }
    }

    private var attachmentsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.pendingAttachments) { attachment in
                    HStack(spacing: 6) {
                        if let thumb = attachment.thumbnail, let ui = UIImage(data: thumb) {
                            Image(uiImage: ui)
                                .resizable().scaledToFill()
                                .frame(width: 24, height: 24)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        } else {
                            Image(systemName: attachment.isUploading ? "arrow.up.circle.fill" : "doc.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(attachment.isUploading ? Theme.amber : Theme.azure)
                        }
                        Text(attachment.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .frame(maxWidth: 120)
                        if attachment.isUploading {
                            ProgressView().controlSize(.mini)
                        }
                        Button {
                            Haptics.light()
                            withAnimation(Motion.snappy) {
                                model.removeAttachment(attachment.id)
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .liquidGlassChrome(in: Capsule())
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private var workspaceShortPath: String {
        let path = model.activeWorkspace?.workspacePath
            ?? model.selectedTask?.workspacePath ?? ""
        return path.replacingOccurrences(of: "/Users/", with: "~/")
    }

    private func sendDraft() {
        let text = model.draft(for: currentSessionKey).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Haptics.medium()
        model.setDraft("", for: currentSessionKey)
        model.send(text: text)
        composerFocused = false
        scrollRequestID += 1
    }
}

// MARK: - 消息行

struct MessageRow: View {
    let row: ConversationRow
    var copied: Bool = false
    var onCopy: () -> Void = {}
    var onBranchCopy: () -> Void = {}
    @AppStorage("zcode-mobile.fontScale") private var fontScale: Double = 1.0

    var body: some View {
        switch row.kind {
        case "userInput":
            userBubble
        case "assistantText":
            assistantBlock
        case "reasoning":
            ReasoningCard(text: row.text, streaming: row.state == "streaming")
        case "toolCall":
            ToolCallCard(row: row)
        case "subagent":
            subagentChip
        case "turnHeader":
            EmptyView()
        default:
            if !row.text.isEmpty { assistantBlock }
        }
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 52)
            Text(row.text)
                .font(.system(size: 15 * CGFloat(fontScale)))
                .foregroundStyle(Theme.textPrimary)
                .lineSpacing(3)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frostedSurface(
                    in: RoundedRectangle(cornerRadius: 21, style: .continuous),
                    strong: true,
                    tint: Theme.azure.opacity(0.14),
                    shadowRadius: 10
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 21, style: .continuous)
                        .strokeBorder(Theme.azure.opacity(0.28), lineWidth: 0.9)
                }
                .textSelection(.enabled)
                .contextMenu {
                    Button {
                        onCopy()
                    } label: {
                        Label("复制消息", systemImage: "doc.on.doc")
                    }
                }
        }
    }

    private var assistantBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            MarkdownLiteText(markdown: row.text, streaming: row.state == "streaming")

            if row.state != "streaming" {
                HStack(spacing: 8) {
                    Button(action: onCopy) {
                        HStack(spacing: 5) {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10.5, weight: .semibold))
                                .contentTransition(.symbolEffect(.replace))
                            Text(copied ? "已复制" : "复制")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(copied ? Theme.mint : Theme.textTertiary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(copied ? Theme.mint.opacity(0.12) : Theme.cardFill.opacity(0.75)))
                    }
                    .buttonStyle(bouncy(scale: 0.94))

                    Button(action: onBranchCopy) {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 10.5, weight: .semibold))
                            Text("分支")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Theme.cardFill.opacity(0.75)))
                    }
                    .buttonStyle(bouncy(scale: 0.94))
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button(action: onCopy) {
                Label("复制回复", systemImage: "doc.on.doc")
            }
            Button(action: onBranchCopy) {
                Label("复制分支标记", systemImage: "arrow.triangle.branch")
            }
        }
    }

    private var subagentChip: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.2.crop.square.stack.fill")
                .font(.system(size: 13))
                .foregroundStyle(Theme.indigo)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Theme.indigo.opacity(0.14)))
            Text(row.text.isEmpty ? "子智能体运行中…" : row.text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frostedSurface(in: RoundedRectangle(cornerRadius: 15, style: .continuous), tint: Theme.indigo.opacity(0.05), shadowRadius: 6)
    }
}

// MARK: - 思考过程毛玻璃折叠卡

struct ReasoningCard: View {
    let text: String
    var streaming: Bool = false
    @State private var expanded = false

    var body: some View {
        if !text.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    Haptics.selection()
                    withAnimation(Motion.smooth) { expanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "brain.head.profile")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.indigo)
                            .symbolEffect(.pulse, isActive: streaming)
                        Text(streaming ? "正在深度思考…" : "思考过程")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                        if !expanded {
                            Text(previewLine)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if expanded {
                    HStack(alignment: .top, spacing: 10) {
                        Capsule()
                            .fill(Theme.indigo.opacity(0.55))
                            .frame(width: 2.5)
                        Text(text)
                            .font(.system(size: 12.5))
                            .lineSpacing(3)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .frostedSurface(
                in: RoundedRectangle(cornerRadius: 15, style: .continuous),
                tint: Theme.indigo.opacity(0.04),
                shadowRadius: 6
            )
        }
    }

    private var previewLine: String {
        text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 工具调用毛玻璃卡

struct ToolCallCard: View {
    let row: ConversationRow
    @State private var expanded = false
    @State private var copiedKind: String?

    private var isRunning: Bool {
        row.state == "running" || row.state == "inputStreaming"
    }

    private var toolIcon: String {
        let name = (row.toolName ?? "").lowercased()
        if name.contains("bash") || name.contains("shell") || name.contains("exec") || name.contains("terminal") {
            return "terminal.fill"
        }
        if name.contains("edit") || name.contains("write") || name.contains("patch") {
            return "pencil.and.outline"
        }
        if name.contains("read") || name.contains("file") || name.contains("view") {
            return "doc.text.fill"
        }
        if name.contains("grep") || name.contains("glob") || name.contains("search") || name.contains("find") {
            return "magnifyingglass"
        }
        if name.contains("web") || name.contains("fetch") || name.contains("http") {
            return "globe"
        }
        return "wrench.and.screwdriver.fill"
    }

    private var accentColor: Color {
        switch row.state {
        case "running", "inputStreaming", "success": return Theme.mint
        case "pendingApproval": return Theme.amber
        case "error": return Theme.coral
        default: return Theme.azure
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                Haptics.selection()
                withAnimation(Motion.smooth) { expanded.toggle() }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: toolIcon)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(accentColor)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(accentColor.opacity(0.13)))

                    Text(row.toolName ?? "工具")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)

                    statusBadge
                    Spacer()

                    Image(systemName: "chevron.down")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if let input = row.inputText, !input.isEmpty {
                        codeSnippet(label: "输入", content: input, tint: Theme.cardFillStrong, id: "in")
                    }
                    if let output = row.outputText, !output.isEmpty {
                        codeSnippet(label: "输出", content: output, tint: Theme.mint.opacity(0.08), id: "out")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frostedSurface(
            in: RoundedRectangle(cornerRadius: 16, style: .continuous),
            tint: isRunning ? Theme.mint.opacity(0.05) : nil,
            shadowRadius: 7
        )
        .overlay {
            if isRunning {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.mint.opacity(0.35), lineWidth: 1)
            }
        }
    }

    private func codeSnippet(label: String, content: String, tint: Color, id: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button {
                    UIPasteboard.general.string = content
                    Haptics.success()
                    withAnimation(Motion.bouncy) { copiedKind = id }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        withAnimation(Motion.snappy) { if copiedKind == id { copiedKind = nil } }
                    }
                } label: {
                    Image(systemName: copiedKind == id ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(copiedKind == id ? Theme.mint : Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
            Text(content)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(tint))
    }

    private var statusBadge: some View {
        Group {
            switch row.state {
            case "running", "inputStreaming":
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini).tint(Theme.mint)
                    Text("运行中")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.mint)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Theme.mint.opacity(0.14)))
            case "pendingApproval":
                PillBadge(text: "待确认", tint: Theme.amber)
            case "success":
                Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(Theme.mint)
            case "error":
                Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(Theme.coral)
            case "cancelled":
                Image(systemName: "slash.circle").font(.system(size: 13)).foregroundStyle(Theme.textTertiary)
            default:
                EmptyView()
            }
        }
    }
}

struct TypingIndicator: View {
    var body: some View {
        HStack(spacing: 8) {
            StreamingDotsView()
            Text("正在生成")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frostedSurface(in: Capsule(), shadowRadius: 5)
    }
}

// MARK: - 审批毛玻璃高优卡片

struct ApprovalCard: View {
    let interaction: PendingInteraction
    let onOption: (InteractionOption) -> Void
    let onFreeText: (String) -> Void
    @State private var freeText = ""
    @State private var showFreeText = false
    @State private var copiedDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: interaction.kind == "permission" ? "lock.shield.fill" : "questionmark.bubble.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.amber)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Theme.amber.opacity(0.16)))
                Text(headerText)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                PillBadge(text: "待确认", tint: Theme.amber)
            }

            if let summary = interaction.summary {
                Text(summary)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textPrimary)
                    .lineSpacing(2)
            }

            if let detail = interaction.detailText {
                HStack(alignment: .top, spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(detail)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary)
                            .textSelection(.enabled)
                    }
                    Button {
                        UIPasteboard.general.string = detail
                        Haptics.success()
                        withAnimation(Motion.bouncy) { copiedDetail = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            withAnimation(Motion.snappy) { copiedDetail = false }
                        }
                    } label: {
                        Image(systemName: copiedDetail ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(copiedDetail ? Theme.mint : Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(11)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.cardFillStrong))
            }

            if let prompt = interaction.prompt {
                Text(prompt)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textPrimary)
            }

            if interaction.options.isEmpty && interaction.kind == "userInput" {
                freeTextBar
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            ForEach(interaction.options, id: \.optionId) { option in
                                let c = tint(option.kind)
                                Button {
                                    onOption(option)
                                } label: {
                                    Text(option.label)
                                        .font(.system(size: 13.5, weight: .semibold))
                                        .foregroundStyle(c)
                                        .padding(.horizontal, 15)
                                        .padding(.vertical, 9)
                                        .liquidGlassChrome(in: Capsule(), tint: c.opacity(0.16), interactive: true)
                                }
                                .buttonStyle(bouncy(scale: 0.94))
                            }
                            if interaction.kind == "userInput" {
                                Button {
                                    Haptics.selection()
                                    withAnimation(Motion.smooth) { showFreeText.toggle() }
                                } label: {
                                    Text("自定义回复…")
                                        .font(.system(size: 12.5, weight: .medium))
                                        .foregroundStyle(Theme.textSecondary)
                                        .padding(.horizontal, 11)
                                        .padding(.vertical, 8)
                                        .liquidGlassChrome(in: Capsule(), interactive: true)
                                }
                                .buttonStyle(bouncy())
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                if showFreeText {
                    freeTextBar
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .padding(16)
        .frostedSurface(
            in: RoundedRectangle(cornerRadius: 20, style: .continuous),
            strong: true,
            tint: Theme.amber.opacity(0.09),
            shadowRadius: 14
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Theme.amber.opacity(0.38), lineWidth: 1)
        }
        .reservedRegionAware()
    }

    private var freeTextBar: some View {
        HStack(spacing: 8) {
            TextField("输入回复…", text: $freeText)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Theme.inputFill))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 0.8))
            Button("发送") {
                onFreeText(freeText)
                freeText = ""
                showFreeText = false
            }
            .buttonStyle(.glassProminent)
            .disabled(freeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var headerText: String {
        switch interaction.kind {
        case "permission": return "权限确认 · \(interaction.toolName ?? "工具")"
        case "userInput": return "需要你的回答"
        default: return "需要确认"
        }
    }

    private func tint(_ kind: String) -> Color {
        if kind.contains("allow") { return Theme.mint }
        if kind.contains("deny") || kind.contains("reject") { return Theme.coral }
        return Theme.azure
    }
}

// MARK: - 输入区动作毛玻璃面板(照片/文件/模型/思考/模式)

struct ComposerActionsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var initialShowModels: Bool = false

    @State private var photoItem: PhotosPickerItem?
    @State private var showFileImporter = false
    @State private var showModels = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showModels {
                modelList
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            } else {
                actions
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            }
        }
        .padding(.top, 14)
        .animation(Motion.smooth, value: showModels)
        .onAppear {
            if initialShowModels { showModels = true }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await MainActor.run {
                        Haptics.success()
                        model.attach(data: data, name: "photo-\(Int(Date().timeIntervalSince1970)).jpg", mime: "image/jpeg", thumbnail: data)
                        dismiss()
                    }
                }
                photoItem = nil
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) {
                    Haptics.success()
                    let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                    model.attach(data: data, name: url.lastPathComponent, mime: mime)
                    dismiss()
                }
            }
        }
    }

    private var actions: some View {
        ScrollView {
            VStack(spacing: 12) {
                GlassCard(padding: 4, cornerRadius: 20) {
                    VStack(spacing: 0) {
                        PhotosPicker(selection: $photoItem, matching: .images) {
                            actionRow(icon: "photo.fill", tint: Theme.azure, title: "照片与截图", detail: nil)
                        }
                        divider
                        Button {
                            Haptics.light()
                            showFileImporter = true
                        } label: {
                            actionRow(icon: "paperclip", tint: Theme.indigo, title: "上传文件", detail: nil)
                        }
                        .buttonStyle(.plain)
                    }
                }

                GlassCard(padding: 4, cornerRadius: 20) {
                    VStack(spacing: 0) {
                        Button {
                            Haptics.selection()
                            withAnimation(Motion.smooth) { showModels = true }
                        } label: {
                            actionRow(icon: "cpu", tint: Theme.azure, title: "运行模型", detail: model.currentModelLabel)
                        }
                        .buttonStyle(.plain)
                        divider
                        Menu {
                            let levels = model.thoughtLevelsRemote.isEmpty ? model.thoughtLevels : model.thoughtLevelsRemote
                            ForEach(levels, id: \.self) { level in
                                Button {
                                    Haptics.selection()
                                    model.applyThought(level)
                                    dismiss()
                                } label: {
                                    Label(thoughtText(level), systemImage: level == model.selectedThought ? "checkmark" : "brain")
                                }
                            }
                        } label: {
                            actionRow(icon: "brain", tint: Theme.indigo, title: "思考强度", detail: thoughtText(model.selectedThought))
                        }
                        divider
                        Menu {
                            ForEach(model.availableModes) { meta in
                                Button {
                                    Haptics.selection()
                                    model.applyMode(meta.value)
                                    dismiss()
                                } label: {
                                    Label(meta.label, systemImage: meta.value == model.selectedMode ? "checkmark" : "hand.raised")
                                }
                            }
                        } label: {
                            actionRow(icon: "hand.raised.fill", tint: Theme.mint, title: "审批模式", detail: modeText(model.selectedMode))
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
    }

    private var modelList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Button {
                        Haptics.light()
                        withAnimation(Motion.smooth) { showModels = false }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 12, weight: .bold))
                            Text("选择模型")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .liquidGlassChrome(in: Capsule(), interactive: true)
                    }
                    .buttonStyle(bouncy())
                    Spacer()
                }

                if model.modelCatalog.isEmpty {
                    GlassCard(padding: 16, cornerRadius: 16) {
                        Text("未获取到桌面端模型目录，请确认桌面端已连接")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    ForEach(Array(Dictionary(grouping: model.modelCatalog, by: \.providerId).keys.sorted()), id: \.self) { provider in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(provider.uppercased())
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(Theme.textTertiary)
                                .padding(.leading, 6)

                            GlassCard(padding: 6, cornerRadius: 18) {
                                VStack(spacing: 2) {
                                    ForEach(model.modelCatalog.filter { $0.providerId == provider }) { option in
                                        let selected = option.modelId == model.selectedModel
                                        Button {
                                            Haptics.selection()
                                            model.applyModel(provider: option.providerId, model: option.modelId)
                                            dismiss()
                                        } label: {
                                            HStack {
                                                Text(option.modelId)
                                                    .font(.system(size: 14.5, weight: selected ? .semibold : .regular))
                                                    .foregroundStyle(Theme.textPrimary)
                                                Spacer()
                                                if selected {
                                                    Image(systemName: "checkmark.circle.fill")
                                                        .font(.system(size: 16))
                                                        .foregroundStyle(Theme.mint)
                                                }
                                            }
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 10)
                                            .background(
                                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                    .fill(selected ? Theme.azure.opacity(0.11) : .clear)
                                            )
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
    }

    private func actionRow(icon: String, tint: Color, title: String, detail: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(Circle().fill(tint.opacity(0.14)))
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if let detail {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    private var divider: some View {
        Rectangle().fill(Theme.hairline).frame(height: 0.6).padding(.leading, 56)
    }

    private func thoughtText(_ level: String) -> String {
        switch level {
        case "max": return "最深"
        case "high": return "深度"
        case "medium": return "标准"
        case "low": return "浅"
        case "none", "off", "nothink": return "关闭"
        default: return level
        }
    }

    private func modeText(_ mode: String) -> String {
        model.availableModes.first { $0.value == mode }?.label ?? mode
    }
}
