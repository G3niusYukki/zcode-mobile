import SwiftUI
import ZCodeMobileCore
import PhotosUI
import UniformTypeIdentifiers

/// 对话页(重设计版):玻璃卡片消息流 + Markdown 渲染 + 操作行 + 上下文 + 悬浮工具
struct ConversationScreen: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var hinge = HingeObserver.shared
    @State private var showContext = false
    @State private var copiedRowId: Int?
    @State private var lastScrollSignature = ""
    @State private var showActions = false
    @State private var modelDraft = ""
    @State private var providerDraft = ""
    @FocusState private var composerFocused: Bool

    private var state: ConversationState? { model.conversationStateForUI }

    private var currentSessionKey: String { model.selectedTask?.taskId ?? "none" }
    private var draftBinding: Binding<String> {
        Binding(get: { model.draft(for: currentSessionKey) },
                set: { model.setDraft($0, for: currentSessionKey) })
    }
    private var rows: [ConversationRow] { state?.rows ?? [] }
    private var interactions: [PendingInteraction] { state?.pendingInteractions ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            header
            messageScroll
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            composer
        }
        .background(Theme.background())
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.conversationTick)
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                model.closeConversation()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Theme.cardFill))
            }
            .buttonStyle(bouncy())

            VStack(alignment: .leading, spacing: 3) {
                Text(state?.title ?? model.selectedTask?.title ?? "会话")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text("session-\(shortSessionID)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
            }

            Spacer()

            if state?.isRunning == true {
                HStack(spacing: 6) {
                    StatusDot(color: Theme.mint, pulsing: true)
                    Text("运行中")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.mint)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Theme.mint.opacity(0.12)))
            } else {
                HStack(spacing: 6) {
                    StatusDot(color: Theme.textTertiary)
                    Text("待机")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Theme.cardFill))
            }

            if state?.control.canStop == true {
                Button {
                    model.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.coral)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Theme.coral.opacity(0.14)))
                }
                .buttonStyle(bouncy())
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var shortSessionID: String {
        String((model.selectedTask?.taskId ?? state?.sessionId ?? "").replacingOccurrences(of: "sess_", with: "").prefix(8))
    }

    // MARK: 消息流

    private var messageScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if state?.hasMoreOlder == true {
                        Button {
                            model.loadOlder()
                        } label: {
                            Text("加载更早的消息")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(Capsule().fill(Theme.cardFill))
                        }
                        .buttonStyle(bouncy())
                        .frame(maxWidth: .infinity)
                    }

                    if rows.isEmpty && state == nil {
                        loadingPlaceholder
                    }

                    ForEach(rows.filter { $0.visibility == "visible" }) { row in
                        MessageRow(row: row,
                                   copied: copiedRowId == row.rowId,
                                   onCopy: {
                                       UIPasteboard.general.string = row.text
                                       withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                           copiedRowId = row.rowId
                                       }
                                       DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                                           withAnimation { if copiedRowId == row.rowId { copiedRowId = nil } }
                                       }
                                   })
                            .id(row.rowId)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    ForEach(interactions) { interaction in
                        ApprovalCard(interaction: interaction) { option in
                            model.resolve(interaction: interaction, option: option)
                        } onFreeText: { text in
                            model.answerFreeText(text, interaction: interaction)
                        }
                    }

                    Color.clear.frame(height: 12).id("bottom-anchor")
                }
                .padding(.horizontal, 22)
                .padding(.top, 8)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .onChange(of: model.keyboardVisible) { _, visible in
                guard visible else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                    proxy.scrollTo("bottom-anchor", anchor: .bottom)
                }
            }
            .onChange(of: model.conversationTick) { _ in
                // 仅在消息内容发生变化时滚底(纯动画帧不重复触发,避免持续滚动卡顿)
                let last = rows.last
                let signature = "\(rows.count)-\(last?.rowId ?? -1)-\(last?.text.count ?? 0)"
                guard signature != lastScrollSignature else { return }
                lastScrollSignature = signature
                proxy.scrollTo("bottom-anchor", anchor: .bottom)
            }
        }
    }

    private var loadingPlaceholder: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("正在打开会话…")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
            Button("加载卡住了?点此重试") {
                if let task = model.selectedTask {
                    model.select(task: task)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.azure)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    // MARK: 输入区

    private var composer: some View {
        VStack(spacing: 8) {
            if showContext {
                sessionInfoPanel
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            contextRow

            if !model.pendingAttachments.isEmpty {
                attachmentsRow
                    .transition(.opacity)
            }

            HStack(alignment: .bottom, spacing: 10) {
                Button {
                    showActions = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 27))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 2)

                TextField("描述你想要构建的内容", text: draftBinding, axis: .vertical)
                    .font(.system(size: 15))
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($composerFocused)
                    .submitLabel(.send)
                    .onSubmit { sendDraft() }
                    .padding(.vertical, 6)
                    .reservedRegionAware()

                if !model.draft(for: currentSessionKey).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        sendDraft()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 27))
                            .foregroundStyle(Theme.accentFill)
                    }
                    .buttonStyle(bouncy())
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Theme.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 1)
            )
            .animation(.spring(response: 0.25, dampingFraction: 0.8),
                       value: model.draft(for: currentSessionKey).isEmpty)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
        .padding(.top, 4)
        .sheet(isPresented: $showActions) {
            ComposerActionsSheet()
                .environmentObject(model)
                .presentationDetents([.height(320)])
                .presentationBackground(.thinMaterial)
        }
    }

    /// 上下文面板:当前会话的真实信息
    private var sessionInfoPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            infoRow("工作区", value: workspaceShortPath)
            infoRow("会话", value: model.selectedTask?.taskId ?? "--")
            infoRow("消息行", value: "\(rows.count)")
            infoRow("模型", value: model.currentModelLabel)
            infoRow("思考", value: model.selectedThought)
            infoRow("审批模式", value: model.availableModes.first { $0.value == model.selectedMode }?.label ?? model.selectedMode)
            infoRow("状态", value: state?.control.phase ?? "--")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.bgSolid) // 不透明底:避免消息文字透出
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        .padding(.horizontal, 4)
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 56, alignment: .leading)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 参考样式:一行「上下文 ›」+ 右侧文件变更 chip
    private var contextRow: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    showContext.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Text("上下文")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(showContext ? 90 : 0))
                }
            }
            .buttonStyle(.plain)

            if let chip = fileChangeChip {
                HStack(spacing: 5) {
                    Image(systemName: "doc.text").font(.system(size: 10))
                    Text(chip)
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Theme.cardFill))
            }

            Spacer()
        }
        .padding(.horizontal, 4)
        .overlay(alignment: .top) { EmptyView() }
    }

    /// 文件变更 chip(如「3 个文件」)
    private var fileChangeChip: String? {
        let writes = rows.filter {
            $0.kind == "toolCall"
                && (($0.toolName ?? "").contains("Write") || ($0.toolName ?? "").contains("Edit"))
                && $0.state == "success"
        }
        return writes.isEmpty ? nil : "\(writes.count) 个文件"
    }

    private func chipLabel(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: 130)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(Theme.cardFill))
    }

    private func thoughtLabel(_ level: String) -> String {
        switch level {
        case "max": return "最深思考"
        case "high": return "深度思考"
        case "medium": return "标准思考"
        case "low": return "浅思考"
        case "none", "off", "nothink": return "不思考"
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
                                .frame(width: 22, height: 22)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                        } else {
                            Image(systemName: attachment.isUploading ? "arrow.up.circle" : "doc.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(attachment.isUploading ? Theme.amber : Theme.azure)
                        }
                        Text(attachment.name)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .frame(maxWidth: 120)
                        if attachment.isUploading {
                            ProgressView().controlSize(.mini)
                        }
                        Button {
                            model.removeAttachment(attachment.id)
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Theme.cardFill))
                }
            }
            .padding(.horizontal, 22)
        }
    }

    private var contextPanel: some View {
        GlassCard(padding: 12, cornerRadius: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("上下文")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button {
                        withAnimation { showContext = false }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
                HStack(spacing: 14) {
                    contextChip(icon: "folder", text: workspaceShortPath)
                    contextChip(icon: "text.line.first.and.arrowtriangle.forward", text: "\(rows.count) 行")
                    contextChip(icon: "clock", text: state?.control.phase ?? "idle")
                }
            }
        }
        .padding(.horizontal, 20)
    }

    private func contextChip(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).font(.system(size: 11.5)).lineLimit(1)
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(Theme.cardFill))
    }

    private var workspaceShortPath: String {
        let path = model.activeWorkspace?.workspacePath
            ?? model.selectedTask?.workspacePath ?? ""
        return path.replacingOccurrences(of: "/Users/you", with: "~")
    }

    private func sendDraft() {
        let text = model.draft(for: currentSessionKey).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.setDraft("", for: currentSessionKey)
        withAnimation { model.send(text: text) }
        composerFocused = false // 发送后自动收起键盘
    }
}

// MARK: - 消息行

struct MessageRow: View {
    let row: ConversationRow
    var copied: Bool = false
    var onCopy: () -> Void = {}

    var body: some View {
        switch row.kind {
        case "userInput":
            userBubble
        case "assistantText":
            assistantBlock
        case "reasoning":
            reasoningBlock
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
            Spacer(minLength: 60)
            Text(row.text)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Theme.azure.opacity(0.18))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Theme.azure.opacity(0.25), lineWidth: 1)
                )
                .textSelection(.enabled)
        }
    }

    private var assistantBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            MarkdownLiteText(markdown: row.text, streaming: row.state == "streaming")

            HStack(spacing: 16) {
                Button(action: onCopy) {
                    HStack(spacing: 5) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11))
                        Text(copied ? "已复制" : "复制")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(copied ? Theme.mint : Theme.textTertiary)
                }
                .buttonStyle(bouncy())

                Button {
                    UIPasteboard.general.string = "fork: \(row.rowId)"
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 11))
                        Text("分支")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(bouncy())
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var reasoningBlock: some View {
        Group {
            if !row.text.isEmpty {
                DisclosureGroup {
                    Text(row.text)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "brain.head.profile").font(.system(size: 12))
                        Text("思考过程").font(.system(size: 12))
                    }
                    .foregroundStyle(Theme.textTertiary)
                }
                .tint(Theme.textTertiary)
            }
        }
    }

    private var subagentChip: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.2.crop.square.stack")
                .font(.system(size: 12))
                .foregroundStyle(Theme.azure)
            Text(row.text.isEmpty ? "子智能体运行中…" : row.text)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.cardFill))
    }
}

// MARK: - 工具调用卡

struct ToolCallCard: View {
    let row: ConversationRow
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                    Text(row.toolName ?? "工具")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    statusBadge
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if let input = row.inputText, !input.isEmpty {
                        Text(input)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(10)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cardFillStrong))
                    }
                    if let output = row.outputText, !output.isEmpty {
                        Text(output)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(14)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.mint.opacity(0.08)))
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 1)
        )
    }

    private var statusBadge: some View {
        Group {
            switch row.state {
            case "running", "inputStreaming":
                PillBadge(text: "运行中", tint: Theme.mint)
            case "pendingApproval":
                PillBadge(text: "待确认", tint: Theme.amber)
            case "success":
                Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.mint)
            case "error":
                Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.coral)
            case "cancelled":
                Image(systemName: "slash.circle").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            default:
                EmptyView()
            }
        }
    }
}

struct TypingIndicator: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Theme.textTertiary)
                    .frame(width: 6, height: 6)
                    .scaleEffect(animating ? 1.0 : 0.6)
                    .opacity(animating ? 1 : 0.5)
                    .animation(.easeInOut(duration: 0.5)
                        .repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.16), value: animating)
            }
        }
        .padding(.leading, 4)
        .onAppear { animating = true }
    }
}

// MARK: - 审批卡

struct ApprovalCard: View {
    let interaction: PendingInteraction
    let onOption: (InteractionOption) -> Void
    let onFreeText: (String) -> Void
    @State private var freeText = ""
    @State private var showFreeText = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: interaction.kind == "permission" ? "lock.shield.fill" : "questionmark.bubble.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.amber)
                Text(headerText)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                PillBadge(text: "待确认", tint: Theme.amber)
            }

            if let summary = interaction.summary {
                Text(summary).font(.system(size: 14)).foregroundStyle(Theme.textPrimary)
            }
            if let detail = interaction.detailText {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(detail)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cardFillStrong))
                }
            }
            if let prompt = interaction.prompt {
                Text(prompt).font(.system(size: 14)).foregroundStyle(Theme.textPrimary)
            }

            if interaction.options.isEmpty && interaction.kind == "userInput" {
                HStack(spacing: 8) {
                    TextField("输入回复…", text: $freeText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.cardFill))
                    Button("发送") {
                        onFreeText(freeText)
                        freeText = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(freeText.isEmpty)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(interaction.options, id: \.optionId) { option in
                            Button {
                                onOption(option)
                            } label: {
                                Text(option.label)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(tint(option.kind))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(Capsule().fill(tint(option.kind).opacity(0.14)))
                                    .overlay(Capsule().strokeBorder(tint(option.kind).opacity(0.35), lineWidth: 1))
                            }
                            .buttonStyle(bouncy())
                        }
                        if interaction.kind == "userInput" {
                            Button {
                                showFreeText.toggle()
                            } label: {
                                Text("自定义回复…")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textTertiary)
                                    .padding(.horizontal, 10)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if showFreeText {
                    HStack(spacing: 8) {
                        TextField("输入回复…", text: $freeText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14))
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.cardFill))
                        Button("发送") {
                            onFreeText(freeText)
                            freeText = ""
                            showFreeText = false
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(freeText.isEmpty)
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.amber.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.amber.opacity(0.35), lineWidth: 1)
        )
        .reservedRegionAware()
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


// MARK: - 输入区动作面板(照片/文件/模型/思考/模式)

struct ComposerActionsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var photoItem: PhotosPickerItem?
    @State private var showFileImporter = false
    @State private var showModels = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showModels {
                modelList
            } else {
                actions
            }
        }
        .padding(.top, 10)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await MainActor.run {
                        model.attach(data: data, name: "photo-\(Int(Date().timeIntervalSince1970)).jpg", mime: "image/jpeg")
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
                    let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                    model.attach(data: data, name: url.lastPathComponent, mime: mime)
                    dismiss()
                }
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 0) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                actionRow(icon: "photo", title: "照片", detail: nil)
            }
            divider
            Button { showFileImporter = true } label: {
                actionRow(icon: "paperclip", title: "文件", detail: nil)
            }
            .buttonStyle(.plain)
            divider
            Button { withAnimation { showModels = true } } label: {
                actionRow(icon: "cpu", title: "模型", detail: model.currentModelLabel)
            }
            .buttonStyle(.plain)
            divider
            Menu {
                let levels = model.thoughtLevelsRemote.isEmpty ? model.thoughtLevels : model.thoughtLevelsRemote
                ForEach(levels, id: \.self) { level in
                    Button {
                        model.applyThought(level)
                        dismiss()
                    } label: {
                        Label(thoughtText(level), systemImage: level == model.selectedThought ? "checkmark" : "brain")
                    }
                }
            } label: {
                actionRow(icon: "brain", title: "思考强度", detail: thoughtText(model.selectedThought))
            }
            divider
            Menu {
                ForEach(model.availableModes) { meta in
                    Button {
                        model.applyMode(meta.value)
                        dismiss()
                    } label: {
                        Label(meta.label, systemImage: meta.value == model.selectedMode ? "checkmark" : "hand.raised")
                    }
                }
            } label: {
                actionRow(icon: "hand.raised", title: "审批模式", detail: modeText(model.selectedMode))
            }
            Spacer(minLength: 0)
        }
    }

    private var modelList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Button {
                    withAnimation { showModels = false }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                        Text("模型").font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(Theme.textPrimary)
                }
                .buttonStyle(.plain)

                if model.modelCatalog.isEmpty {
                    Text("未获取到模型目录")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    ForEach(Array(Dictionary(grouping: model.modelCatalog, by: \.providerId).keys.sorted()), id: \.self) { provider in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(provider)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.textTertiary)
                            ForEach(model.modelCatalog.filter { $0.providerId == provider }) { option in
                                Button {
                                    model.applyModel(provider: option.providerId, model: option.modelId)
                                    dismiss()
                                } label: {
                                    HStack {
                                        Text(option.modelId)
                                            .font(.system(size: 14))
                                            .foregroundStyle(Theme.textPrimary)
                                        Spacer()
                                        if option.modelId == model.selectedModel {
                                            Image(systemName: "checkmark").foregroundStyle(Theme.mint)
                                        }
                                    }
                                    .padding(.vertical, 8)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func actionRow(icon: String, title: String, detail: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 24)
            Text(title)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if let detail {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }

    private var divider: some View {
        Rectangle().fill(Theme.cardFill).frame(height: 0.5).padding(.leading, 56)
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
