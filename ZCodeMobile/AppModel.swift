import Foundation
import SwiftUI
import Network
import ZCodeMobileCore
import Combine

/// App 编排核心:登录 → 配对 → 连接(中继+桥+通道) → 会话交互。
/// 所有 UI 状态在主线程发布;协议层回调统一调度回主线程。
@MainActor
final class AppModel: ObservableObject {

    // MARK: - 发布状态

    enum AppScreen { case login, pairing, session }
    @Published var screen: AppScreen = .login
    @Published var jwtReady = false

    @Published var relayPhase: String = "未连接"          // 展示用摘要
    @Published var bridgePhase: BridgeSession.Status.Phase = .idle
    @Published var tasks: [TaskEntry] = []
    @Published var selectedTask: TaskEntry?
    @Published var workspaces: [WorkspaceInfo] = []
    @Published var errorMessage: String?
    @Published var conversationTick = 0                   // 对话状态变更计数(驱动刷新)
    @Published var searchText = ""
    @Published var showSettings = false
    #if DEBUG
    var autoOpened = false
    #endif
    @Published var openConversation = false
    @Published var showDeviceSheet = false
    @Published var activeWorkspaceID: String?
    @Published var toast: String?
    @Published var pendingAttachments: [PendingAttachment] = []
    @Published var modelCatalog: [SessionConfigChannel.ModelOption] = []
    @Published var availableModes: [SessionConfigChannel.ModeOption] = SessionConfigChannel.ModeOption.fallback
    @Published var selectedMode: String = "default"
    @Published var selectedThought: String = "high"
    @Published var selectedModel: String = ""
    @Published var selectedProvider: String = ""
    @Published var usageReport: UsageChannel.UsageReport?
    @Published var showUsageSheet = false
    @Published var drafts: [String: String] = [:]
    @Published var keyboardVisible = false
    private var backgroundedAt: Date?
    private var selectingTaskID: String?
    #if DEBUG
    private var configTested = false
    #endif

    struct PendingAttachment: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var mime: String
        var bytes: Int
        var ref: String?          // 上传完成后的 zcode-artifact ref
        var isUploading: Bool
        var thumbnail: Data?
    }
    /// 终态失败(二维码过期/被踢/桌面离线超时):全屏恢复页
    @Published var terminalFailure: TerminalFailure?

    struct TerminalFailure: Identifiable {
        let id = UUID()
        let reason: RelayClient.FailureReason
        let title: String
        let message: String
    }

    var conversation: ConversationChannel? { bridge?.activeConversation }
    private(set) var device: PairedDevice?
    var pairedDevice: PairedDevice? { device }
    var activeWorkspace: WorkspaceInfo? { bridge?.activeConversationWorkspace }
    #if DEBUG
    private var demoState: ConversationState?
    #endif

    /// UI 数据源:真实会话状态,或 DEBUG 演示状态
    var conversationStateForUI: ConversationState? {
        #if DEBUG
        if let demoState { return demoState }
        #endif
        return conversation?.state
    }


    /// 会话列表(搜索 + 工作区过滤)
    var filteredTasks: [TaskEntry] {
        var list = tasks
        if let wsID = activeWorkspaceID {
            list = list.filter { ($0.workspaceIdentity ?? $0.workspacePath) == wsID }
        }
        let q = searchText.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            list = list.filter {
                $0.title.localizedCaseInsensitiveContains(q) || $0.taskId.localizedCaseInsensitiveContains(q)
            }
        }
        return list
    }

    static func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }

    func draft(for sessionId: String) -> String {
        drafts[sessionId] ?? ""
    }

    func setDraft(_ text: String, for sessionId: String) {
        if text.isEmpty {
            drafts.removeValue(forKey: sessionId)
        } else {
            drafts[sessionId] = text
        }
        UserDefaults.standard.set(drafts, forKey: "zcode-mobile.drafts")
    }

    func openTask(_ task: TaskEntry) {
        Self.dismissKeyboard()
        select(task: task)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            openConversation = true
        }
    }

    func closeConversation() {
        Self.dismissKeyboard()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            openConversation = false
        }
        LiveActivityManager.shared.end()
    }

    /// 新建会话(命令失败给出提示)
    func newSession() {
        guard let workspace = activeWorkspace ?? workspaces.first, let conversation else {
            showToast("尚未连接桌面端")
            return
        }
        Task {
            do {
                let ack = try await conversation.createSession(
                    workspacePath: workspace.workspacePath,
                    workspaceIdentity: workspace.workspaceIdentity)
                if !ack.isSuccess {
                    await MainActor.run { self.showToast("新建失败:\(ack.message ?? ack.status)") }
                }
            } catch {
                await MainActor.run { self.showToast("新建失败:\(String(describing: error))") }
            }
        }
    }

    func switchWorkspace(_ ws: WorkspaceInfo) {
        activeWorkspaceID = ws.id
        openConversation = false
    }

    func showToast(_ text: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            withAnimation { if self.toast == text { self.toast = nil } }
        }
    }

    // MARK: - 协议栈

    private let tokenStore = TokenStore()
    private let api = V2AccountApi()
    private var relay: RelayClient?
    private var bridge: BridgeSession?
    private var sidContinuationUsed = false               // 一次性预算:配对成功前不再二次接续
    private let networkMonitor = NWPathMonitor()
    private var cancellables = Set<AnyCancellable>()

    private static let deviceKey = "zcode-mobile.pairedDevice"

    // MARK: - 启动

    init() {
        if let jwt = tokenStore.validJWT() {
            jwtReady = true
        }
        if let data = UserDefaults.standard.data(forKey: Self.deviceKey),
           let device = try? JSONDecoder().decode(PairedDevice.self, from: data) {
            self.device = device
        }
        // 联调钩子:SIMCTL_CHILD_ZCODEMOBILE_LANDING_URL=... 启动直接进入登录页
        if let landing = ProcessInfo.processInfo.environment["ZCODEMOBILE_LANDING_URL"],
           (try? QrParser.parse(landing)) != nil {
            _ = pair(with: landing)
            screen = jwtReady ? .session : .login
        }
        // 登录页需要有效 sid(官方页无 sid 会报「连接失效」),所以未配对时先走配对
        if jwtReady {
            screen = device != nil ? .session : .pairing
        } else {
            screen = device != nil ? .login : .pairing
        }
        drafts = (UserDefaults.standard.dictionary(forKey: "zcode-mobile.drafts") as? [String: String]) ?? [:]
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillShowNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.keyboardVisible = true
        }
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillHideNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.keyboardVisible = false
        }
        startNetworkMonitor()
        loadDemoDataIfNeeded()
        // 冷启动自动连接(之前必须手动扫码/登录才连;演示模式跳过)
        let isDemo = ProcessInfo.processInfo.environment["ZCODEMOBILE_DEMO"] == "1"
        if jwtReady, device != nil, !isDemo {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.connect()
            }
        }
        // 锁屏/切后台回来:按后台时长与连接健康度自动重连
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.backgroundedAt = Date()
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self, self.jwtReady, self.device != nil else { return }
            let isDemo = ProcessInfo.processInfo.environment["ZCODEMOBILE_DEMO"] == "1"
            guard !isDemo else { return }
            let backgrounded = self.backgroundedAt.map { Date().timeIntervalSince($0) } ?? 0
            self.backgroundedAt = nil

            let relayHealthy: Bool = {
                guard let relay = self.relay else { return false }
                if case .paired = relay.state { return true }
                return false
            }()

            if backgrounded > 20 || !relayHealthy {
                // 长时间后台(socket 基本已被系统回收)或非配对状态 → 整套重连
                ZDlog("[ZCodeMobile] foreground resume after %.0fs, reconnecting (healthy=%@)",
                      backgrounded, relayHealthy ? "yes" : "no")
                self.reconnect()
            } else {
                ZDlog("[ZCodeMobile] foreground resume after %.0fs, connection healthy", backgrounded)
                // 短时间后台:清心跳残留,保持连接
            }
        }
    }

    // MARK: - 登录/登出

    func loginHarvested(jwt: String) {
        ZDlog("[ZCodeMobile] loginHarvested len=%d device=%@", jwt.count, device == nil ? "nil" : "set")
        tokenStore.saveJWT(jwt)
        jwtReady = true
        screen = device != nil ? .session : .pairing
        if device != nil { connect() }
    }

    func logout() {
        disconnect()
        tokenStore.deleteJWT()
        jwtReady = false
        screen = .login
    }

    // MARK: - 配对

    func pair(with raw: String) -> String? {
        do {
            let device = try QrParser.parse(raw)
            guard device.isV2 else { return "请升级桌面端 ZCode(需 3.16+)" }
            self.device = device
            if let data = try? JSONEncoder().encode(device) {
                UserDefaults.standard.set(data, forKey: Self.deviceKey)
            }
            return nil
        } catch QrParseError.v1NotSupported {
            return "旧版二维码(V1 协议):请把桌面端 ZCode 升级到 3.16 以上"
        } catch QrParseError.missingSid {
            return "二维码里缺少 sid,请重新生成"
        } catch {
            return "无法识别的连接地址"
        }
    }

    /// 配对完成后的流转:已登录 → 直接连;未登录 → 带着 sid 进登录页(官方页需要有效 sid 才显示登录入口)
    func pairAndProceed(raw: String) -> String? {
        if let error = pair(with: raw) { return error }
        if jwtReady {
            connect()
        } else {
            screen = .login
        }
        return nil
    }

    func unpair() {
        disconnect()
        device = nil
        UserDefaults.standard.removeObject(forKey: Self.deviceKey)
        screen = .pairing
    }

    // MARK: - 连接

    func connect() {
        guard let device, jwtReady else { return }
        disconnect()
        screen = .session

        let deps = RelayClient.Dependencies(
            tokenFetcher: { [weak self] in
                guard let self else { throw V2AccountApi.ApiError.authFailed("app gone") }
                guard let jwt = self.tokenStore.validJWT() else {
                    throw V2AccountApi.ApiError.authFailed("登录已过期")
                }
                let token = try await self.api.fetchRelayToken(origin: device.origin, jwt: jwt)
                return token.token
            },
            wsFactory: URLSessionWSFactory(),
            now: { Date() },
            random: { Double.random(in: 0..<1) }
        )

        let client = RelayClient(device: device, deps: deps)
        let session = BridgeSession(relay: client, appVersion: "3.6.5") { line in
            DispatchQueue.main.async { ZDlog("[ZCodeMobile] %@", line) }
        }

        client.onStateChange = { [weak self] state in
            DispatchQueue.main.async { self?.handleRelayState(state) }
        }
        session.onStatusChange = { [weak self] status in
            DispatchQueue.main.async {
                self?.bridgePhase = status.phase
                self?.workspaces = status.workspaces
                if case .ready = status.phase {
                    self?.sidContinuationUsed = false // 配对成功,接续预算复位
                    self?.ensureTaskListLoaded()
                    #if DEBUG
                    if ProcessInfo.processInfo.environment["ZCODEMOBILE_PROBE_API"] == "1" {
                        self?.probeServiceMethods()
                    }
                    #endif
                }
            }
        }
        session.controller.onUpdated = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.tasks = self.bridge?.controller.visibleTasks ?? []
                #if DEBUG
                // 联调:ZCODEMOBILE_AUTO_OPEN_TASK=1 自动打开第一个会话并抓日志
                if ProcessInfo.processInfo.environment["ZCODEMOBILE_AUTO_OPEN_TASK"] == "1", !self.autoOpened, let first = self.tasks.first {
                    self.autoOpened = true
                    ZDlog("[ZCodeMobile][auto] auto-open task=%@", first.taskId)
                    self.openTask(first)
                }
                #endif
            }
        }

        relay = client
        bridge = session
        client.start()
    }

    func disconnect() {
        terminalFailure = nil
        LiveActivityManager.shared.end()
        relay?.stop(reason: "user")
        relay = nil
        bridge = nil
        tasks = []
        selectedTask = nil
        workspaces = []
        bridgePhase = .idle
        relayPhase = "未连接"
    }

    func reconnect() {
        connect()
    }

    private func handleRelayState(_ state: RelayClient.State) {
        switch state {
        case .idle: relayPhase = "未连接"
        case .connecting: relayPhase = "连接中…"
        case .authenticating: relayPhase = "认证中…"
        case .waitingPeer: relayPhase = "等待桌面端开启远程控制…"
        case .paired: relayPhase = "已配对"
        case .failed(let reason, let message):
            relayPhase = "连接失败"
            guard reason.isTerminal else { return }
            // 可接续失败(AUTH_FAILED=device-not-owned / 桌面离线超时):先自动接续新 SID
            if reason == .authFailed || reason == .desktopDisconnected {
                maybeContinueSidAfterFailure()
            }
            // 接续未果/不可接续 → 全屏失败页(重新扫码 / 重试 / 切换账号)
            if terminalFailure == nil {
                terminalFailure = TerminalFailure(reason: reason, title: title(for: reason), message: detail(for: reason, message))
            }
        }
    }

    private func title(for reason: RelayClient.FailureReason) -> String {
        switch reason {
        case .authFailed: return "连接已失效"
        case .desktopDisconnected: return "桌面端不在线"
        case .kicked: return "连接被接管"
        case .protocolMismatch: return "协议不兼容"
        default: return "连接失败"
        }
    }

    private func detail(for reason: RelayClient.FailureReason, _ message: String?) -> String {
        switch reason {
        case .authFailed: return "二维码已过期或桌面端已重新生成连接(每次打开远程控制都会刷新)。应用已尝试自动找回,未成功 —— 请在桌面端打开最新的二维码重新扫一次。"
        case .desktopDisconnected: return "桌面端 ZCode 已离线超过 15 秒。请确认电脑端 ZCode 正在运行且远程控制已开启,然后重试。"
        case .kicked: return "同一台桌面同时只能一个手机端在线,连接已被其他客户端接管(如官方网页端)。"
        case .protocolMismatch: return "协议版本不匹配:\(message ?? "")。请升级 App 或桌面端。"
        default: return message ?? "未知错误"
        }
    }

    /// SID 自动接续:查账号设备列表,按 MID 找新 sid;一次性预算,Paired 后复位
    private func maybeContinueSidAfterFailure() {
        guard !sidContinuationUsed,
              let device = device,
              device.deviceSid == relay?.device.deviceSid,
              let jwt = tokenStore.validJWT() else { return }
        sidContinuationUsed = true
        let origin = device.origin
        let failedSid = device.deviceSid
        let failedMid = device.deviceMid
        Task { [weak self] in
            guard let self else { return }
            guard let devices = try? await self.api.listDevices(origin: origin, jwt: jwt) else { return }
            let outcome = SidContinuation.resolve(failedSid: failedSid, failedMid: failedMid, devices: devices)
            await MainActor.run {
                switch outcome {
                case .keepCurrent:
                    ZDlog("[ZCodeMobile] sid continuation: keep current, reconnecting")
                    self.terminalFailure = nil
                    self.reconnect()
                case .switchTo(let newSid, let newName):
                    ZDlog("[ZCodeMobile] sid continuation: switch to %@ (%@)", newSid, newName ?? "-")
                    var next = device
                    if let newDevice = try? QrParser.parse("\(device.remoteUrl)?sid=\(newSid)&mid=\(failedMid ?? "")&name=\(newName ?? "")") {
                        next = newDevice
                    } else {
                        next = PairedDevice(deviceSid: newSid, passHash: nil, deviceMid: failedMid,
                                            deviceName: newName ?? device.deviceName, remoteUrl: device.remoteUrl,
                                            appVersion: device.appVersion)
                    }
                    if let data = try? JSONEncoder().encode(next) {
                        UserDefaults.standard.set(data, forKey: Self.deviceKey)
                    }
                    self.device = next
                    self.terminalFailure = nil
                    self.reconnect()
                case .none:
                    ZDlog("[ZCodeMobile] sid continuation: none, user must re-scan")
                    // terminalFailure 保持/由调用方设置
                }
            }
        }
    }

    // MARK: - 会话交互

    func select(task: TaskEntry) {
        if task.taskId == selectedTask?.taskId, openConversation { return }
        if task.taskId == selectingTaskID { return } // 同一目标订阅中,避免重复订阅
        selectingTaskID = task.taskId
        ZDlog("[ZCodeMobile][tap] select begin %@", task.taskId)
        selectedTask = task
        let sessionTarget = task
        Task {
            defer {
                Task { @MainActor [weak self] in self?.selectingTaskID = nil }
            }
            guard let bridge = self.bridge else {
                await MainActor.run { self.showToast("尚未连接桌面端") }
                return
            }
            ZDlog("[ZCodeMobile] select session=%@ ws=%@", sessionTarget.taskId, sessionTarget.workspacePath)
            do {
                // 每工作区独立 bridge:按任务所属工作区选择/创建
                let workspace = self.workspaces.first {
                    ($0.workspaceIdentity ?? $0.workspacePath) == (sessionTarget.workspaceIdentity ?? sessionTarget.workspacePath)
                } ?? WorkspaceInfo(workspacePath: sessionTarget.workspacePath,
                                   workspaceIdentity: sessionTarget.workspaceIdentity,
                                   label: (sessionTarget.workspacePath as NSString).lastPathComponent)
                try await bridge.selectSession(sessionTarget.taskId, workspace: workspace)
                // 新工作区桥的会话流:挂上刷新回调
                await MainActor.run {
                    bridge.activeConversation?.state.onUpdated = { [weak self] in
                        self?.scheduleConversationRefresh()
                    }
                    self.refreshSessionConfig()
                    self.refreshUsage()
                    #if DEBUG
                    // 联调:ZCODEMOBILE_TEST_CONFIG=1 自动验证模式/思考切换
                    if ProcessInfo.processInfo.environment["ZCODEMOBILE_TEST_CONFIG"] == "1", !self.configTested {
                        self.configTested = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            ZDlog("[ZCodeMobile][test] catalog models=%d modes=%d", self.modelCatalog.count, self.availableModes.count)
                            self.applyMode("edit")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                self.applyThought("max")
                            }
                        }
                    }
                    #endif
                }
                ZDlog("[ZCodeMobile] subscribe ok session=%@", sessionTarget.taskId)
            } catch {
                ZDlog("[ZCodeMobile] subscribe FAILED session=%@ err=%@", sessionTarget.taskId, String(describing: error))
                await MainActor.run {
                    self.showToast("打开会话失败:桌面端未接受订阅")
                }
            }
        }
    }

    func send(text: String) {
        guard let task = selectedTask, let conversation, let bridge else { return }
        let workspace = bridge.activeConversationWorkspace
        let attachments = pendingAttachments.compactMap { pending -> ConversationChannel.Attachment? in
            guard let ref = pending.ref else { return nil }
            return ConversationChannel.Attachment(ref: ref, fileName: pending.name,
                                                  mime: pending.mime, bytes: pending.bytes)
        }
        let uploading = pendingAttachments.contains { $0.isUploading }
        if uploading {
            showToast("附件上传中,请稍候")
            return
        }
        Task {
            do {
                _ = try await conversation.sendText(
                    text, sessionId: task.taskId,
                    workspacePath: workspace?.workspacePath ?? task.workspacePath,
                    workspaceIdentity: task.workspaceIdentity ?? workspace?.workspaceIdentity,
                    attachments: attachments)
                await MainActor.run {
                    self.pendingAttachments.removeAll()
                }
            } catch {
                await MainActor.run {
                    self.showToast("发送失败:\(String(describing: error))")
                }
            }
        }
    }

    func stop() {
        guard let task = selectedTask, let conversation, let bridge else { return }
        let workspace = bridge.activeConversationWorkspace
        Task {
            _ = try? await conversation.stop(
                sessionId: task.taskId,
                workspacePath: workspace?.workspacePath ?? task.workspacePath,
                workspaceIdentity: task.workspaceIdentity ?? workspace?.workspaceIdentity,
                expectedForegroundExecutionId: nil)
        }
    }

    func resolve(interaction: PendingInteraction, option: InteractionOption) {
        answerInteraction(interaction, optionId: option.optionId)
    }

    func answerFreeText(_ text: String, interaction: PendingInteraction) {
        answerInteraction(interaction, freeText: text)
    }

    private func answerInteraction(_ interaction: PendingInteraction, optionId: String? = nil, freeText: String? = nil) {
        guard let task = selectedTask, let conversation, let bridge else { return }
        let workspace = bridge.activeConversationWorkspace
        Task {
            do {
                _ = try await conversation.resolveInteraction(
                    interactionId: interaction.interactionId,
                    optionId: optionId, freeText: freeText,
                    sessionId: task.taskId,
                    workspacePath: workspace?.workspacePath ?? task.workspacePath,
                    workspaceIdentity: task.workspaceIdentity ?? workspace?.workspaceIdentity)
            } catch {
                await MainActor.run {
                    errorMessage = "应答失败:\(String(describing: error))"
                }
            }
        }
    }

    func loadOlder() {
        guard let task = selectedTask, let conversation, let bridge else { return }
        let workspace = bridge.activeConversationWorkspace
        Task {
            _ = try? await conversation.loadOlder(
                sessionId: task.taskId,
                workspacePath: workspace?.workspacePath ?? task.workspacePath,
                workspaceIdentity: task.workspaceIdentity ?? workspace?.workspaceIdentity)
        }
    }

    // MARK: - DEBUG 服务方法探测

    private var probeRan = false

    private func probeServiceMethods() {
        #if DEBUG
        guard !probeRan, let client = bridge?.servicesClient() else { return }
        probeRan = true
        // 第二轮:完整 getView + 带 sessionId 的配置写入(错误信息即 schema)
        if ProcessInfo.processInfo.environment["ZCODEMOBILE_PROBE2"] == "1" {
            Task {
                do {
                    let view = try await client.call("model-selection", "getView", args: [], timeout: 10)
                    if case .json(let text) = view {
                        ZDlog("[ZCodeMobile][probe2] model-selection.getView len=%d", text.count)
                        ZDlog("[ZCodeMobile][probe2] VIEW-BEGIN %@", String(text.prefix(2400)))
                        ZDlog("[ZCodeMobile][probe2] VIEW-END")
                    }
                } catch { ZDlog("[ZCodeMobile][probe2] getView fail %@", String(describing: error)) }

                // 等会话就绪
                var sessionID: String?
                for _ in 0..<20 where sessionID == nil {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    sessionID = await MainActor.run { self.selectedTask?.taskId }
                }
                guard let sid = sessionID else {
                    ZDlog("[ZCodeMobile][probe2] no session for config probe")
                    return
                }
                ZDlog("[ZCodeMobile][probe2] session=%@", sid)
                let attempts: [(String, String, [IpcValue])] = [
                    ("zcode-session", "setMode", [.object([("sessionId", .string(sid)), ("mode", .string("default"))])]),
                    ("zcode-session", "setMode", [.object([("sessionId", .string(sid)), ("mode", .string("build"))])]),
                    ("zcode-session", "setMode", [.object([("sessionId", .string(sid)), ("mode", .string("acceptEdits"))])]),
                    ("zcode-session", "setThoughtLevel", [.object([("sessionId", .string(sid)), ("thought", .string("high"))])]),
                    ("zcode-session", "setThoughtLevel", [.object([("sessionId", .string(sid)), ("thoughtLevel", .string("high"))])]),
                    ("zcode-session", "setModel", [.object([("sessionId", .string(sid))])]),
                ]
                for (channel, method, args) in attempts {
                    do {
                        let result = try await client.call(channel, method, args: args, timeout: 8)
                        let text: String = {
                            if case .json(let t) = result { return String(t.prefix(300)) }
                            return "\(result)"
                        }()
                        ZDlog("[ZCodeMobile][probe2] OK %@.%@ → %@", channel, method, text)
                    } catch {
                        ZDlog("[ZCodeMobile][probe2] FAIL %@.%@ → %@", channel, method, String(String(describing: error).prefix(400)))
                    }
                }
                ZDlog("[ZCodeMobile][probe2] done")
            }
            return
        }
        let candidates: [(String, String, [IpcValue])] = [
            ("model-selection", "getView", []),
            ("model-selection", "getView", [.object([])]),
            ("provider-settings", "getView", []),
            ("usage-stats", "getView", []),
            ("usage-stats", "getUsage", [.object([])]),
            ("coding-plan-subscription", "getView", []),
            ("coding-plan-subscription", "getStatus", [.object([])]),
            ("zcode-session", "readWorkspaceState", [.object([("workspacePath", .string("/Users/you"))])]),
            ("zcode-session", "setMode", [.object([("workspacePath", .string("/Users/you")), ("mode", .string("default"))])]),
            ("zcode-session", "setThoughtLevel", [.object([("workspacePath", .string("/Users/you")), ("thought", .string("high"))])]),
            ("zcode-session", "setModel", [.object([("workspacePath", .string("/Users/you"))])]),
            ("zcode-session", "readWorkspaceRuntimeIdentity", [.object([("workspacePath", .string("/Users/you"))])]),
        ]
        Task {
            for (channel, method, args) in candidates {
                do {
                    let result = try await client.call(channel, method, args: args, timeout: 8)
                    let text: String
                    if case .json(let t) = result { text = String(t.prefix(220)) } else { text = "\(result)" }
                    ZDlog("[ZCodeMobile][probe-api] OK %@.%@ → %@", channel, method, text)
                } catch {
                    ZDlog("[ZCodeMobile][probe-api] FAIL %@.%@ → %@", channel, method, String(String(describing: error).prefix(120)))
                }
            }
            ZDlog("[ZCodeMobile][probe-api] done")
        }
        #endif
    }

    // MARK: - DEBUG 演示数据(UI 走查用)

    private func loadDemoDataIfNeeded() {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["ZCODEMOBILE_DEMO"] == "1" else { return }
        screen = .session
        jwtReady = true
        let now = Date().timeIntervalSince1970 * 1000
        workspaces = [
            WorkspaceInfo(workspacePath: "/Users/you", workspaceIdentity: nil,
                          label: "workspace-a", kind: "local", connectionState: "connected"),
            WorkspaceInfo(workspacePath: "/Users/you/project-b", workspaceIdentity: nil,
                          label: "project-b", kind: "local", connectionState: "connected"),
        ]
        let demoTitles: [(String, Double)] = [
            ("研究一个技术问题怎么实现", now - 5 * 3600_000),
            ("安装一个插件", now - 7 * 3600_000),
            ("处理一封申请邮件", now - 3 * 86400_000),
            ("排查版本功能差异", now - 3600_000),
            ("清理多余的应用", now - 4 * 86400_000),
            ("行业白模介绍与可行性", now - 5 * 86400_000),
            ("格式转换任务", now - 6 * 86400_000),
            ("安全评估请求", now - 7 * 86400_000),
            ("清理本地空间", now - 14 * 86400_000),
        ]
        let demoIDs = ["ef061eb9", "92c6ecfc", "d02cb6ac", "31b43296", "90370561", "b21e6b9f", "8a82a41b", "4a1818d6", "ef061eba"]
        tasks = demoTitles.enumerated().map { i, pair in
            TaskEntry(taskId: "sess_\(demoIDs[i % demoIDs.count])c72b4a5f",
                      workspacePath: i < 3 ? "/Users/you" : "/Users/you/project-b",
                      workspaceIdentity: nil,
                      title: pair.0,
                      status: i == 0 ? "running" : "idle",
                      updatedAt: pair.1,
                      pinned: i == 0, archived: false)
        }
        selectedTask = tasks.first
        if let demoDevice = try? QrParser.parse("https://zcode.z.ai/remote/v4?sid=d_demo0000000000000000&mid=demo-mid&name=Demo%20Mac&app_version=3.18.2") {
            device = demoDevice
        }
        openConversation = ProcessInfo.processInfo.environment["ZCODEMOBILE_DEMO_CONV"] == "1"
        showSettings = ProcessInfo.processInfo.environment["ZCODEMOBILE_DEMO_SETTINGS"] == "1"
        bridgePhase = .ready
        relayPhase = "已配对 · 就绪"

        // 演示会话状态(走真实归约器)
        let state = ConversationState()
        let snapshot: [String: Any] = [
            "sessionId": "sess_ef061eb9",
            "logEpoch": "demo-epoch",
            "revision": 3,
            "meta": ["title": demoTitles[0].0],
            "control": ["phase": "running", "canStop": true, "stopState": "stoppable"],
            "config": ["model": "zcode/GLM-5.3-Flash", "thought": "max", "mode": "yolo"],
            "pendingInteractions": [[
                "interactionId": "perm_demo",
                "kind": "permission",
                "payload": [
                    "toolName": "Bash",
                    "summary": "运行定时检查脚本验证抓取逻辑",
                    "detail": ["command": "python3 check.py --once"],
                    "options": [
                        ["optionId": "opt_allow", "label": "允许一次", "kind": "allowOnce"],
                        ["optionId": "opt_always", "label": "始终允许", "kind": "allowAlways"],
                        ["optionId": "opt_deny", "label": "拒绝", "kind": "deny"],
                    ],
                ],
            ]],
            "rows": ["window": [
                ["rowId": 1, "kind": "userInput", "visibility": "visible",
                 "text": "研究一个技术问题怎么实现"],
                ["rowId": 2, "kind": "reasoning", "visibility": "visible",
                 "text": "先确认仓库动态,再设计定时检查任务。用户关注的是 eSIM 限制相关的 issue。", "state": "complete"],
                ["rowId": 3, "kind": "assistantText", "visibility": "visible", "state": "complete",
                 "text": """
                 分两步做完了,和你说下现在的状态:

                 1. **GitHub 订阅**:已经用你的账号对 `owner/repo` 点了 Watch (All Activity),所以 issue、发版有动静,GitHub 会直接推送通知。不想收就执行 `gh api -X DELETE repos/owner/repo/subscription` 取消。
                 2. **定时检查**:我建了一个每天 10:00 和 20:00 自动运行的检查任务,执行 `check.py`。它比对 sys tag、新提交、新关闭的 issue,状态存在 `state.json`;只有真的有新变化时,才会在这个会话里告诉你。
                 """],
                ["rowId": 4, "kind": "toolCall", "visibility": "visible",
                 "toolName": "Bash", "status": "success", "state": "success",
                 "inputText": #"{"command": "python3 check.py --once"}"#,
                 "output": ["text": "checked 12 commits, 3 issues — no change"]],
                ["rowId": 5, "kind": "assistantText", "visibility": "visible", "state": "complete",
                 "text": """
                 判断是否相关时,检查任务会读取 release 说明、提交和 issue 正文,专门盯 **#5、#7、#8、#9、#10、#11、#12** 这几条;如果只是 sideload 兼容这类无关修改,就一句话带过。

                 想改频率或者停掉监控,直接说一声就行。
                 """],
            ], "totalCount": 5, "firstRowId": 1],
        ]
        let dict: [String: Any] = [
            "topic": "conversation/sess_ef061eb9", "subscriptionId": "sub-demo",
            "fromSeq": 0, "toSeq": 21,
            "payload": ["kind": "snapshot", "snapshot": snapshot],
        ]
        if let frame = TopicFrame(dict: dict) {
            state.apply(frame: frame)
        }
        demoState = state
        #endif
    }

    // MARK: - 会话配置(模型/思考/模式)

    private var snapshotConfig: [String: Any] {
        conversationStateForUI?.snapshotRaw["config"] as? [String: Any] ?? [:]
    }

    var currentProvider: String { snapshotConfig["provider"] as? String ?? "" }
    var currentModel: String { snapshotConfig["model"] as? String ?? "GLM-5.3" }
    var currentThought: String { snapshotConfig["thought"] as? String ?? "high" }
    var currentMode: String { snapshotConfig["mode"] as? String ?? "yolo" }

    var thoughtLevels: [String] {
        (snapshotConfig["thoughtLevels"] as? [String]) ?? ["max", "high", "medium", "low", "none"]
    }

    static let modeLabels: [(id: String, label: String)] = [
        ("build", "构建"), ("edit", "编辑"), ("plan", "计划"), ("yolo", "自动"),
    ]


    // MARK: - 附件

    func attach(data: Data, name: String, mime: String, thumbnail: Data? = nil) {
        guard let task = selectedTask, let conversation else {
            showToast("请先打开一个会话")
            return
        }
        let ws = activeWorkspace
        var pending = PendingAttachment(name: name, mime: mime, bytes: data.count,
                                        ref: nil, isUploading: true, thumbnail: thumbnail)
        pendingAttachments.append(pending)
        let attachmentID = pending.id
        Task {
            do {
                let uploaded = try await conversation.uploadAttachment(
                    data: [UInt8](data), fileName: name, mime: mime,
                    sessionId: task.taskId,
                    workspacePath: ws?.workspacePath ?? task.workspacePath,
                    workspaceIdentity: task.workspaceIdentity ?? ws?.workspaceIdentity)
                await MainActor.run {
                    if let idx = self.pendingAttachments.firstIndex(where: { $0.id == attachmentID }) {
                        self.pendingAttachments[idx].ref = uploaded.ref
                        self.pendingAttachments[idx].isUploading = false
                    }
                }
            } catch {
                await MainActor.run {
                    self.pendingAttachments.removeAll { $0.id == attachmentID }
                    self.showToast("附件上传失败:\(name)")
                }
            }
        }
    }

    func removeAttachment(_ id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    // MARK: - 会话配置(模型目录/模式/用量)

    private var configChannel: SessionConfigChannel? {
        guard let client = bridge?.servicesClient() else { return nil }
        return SessionConfigChannel(client: client, onLog: { ZDlog("[ZCodeMobile][config] %@", $0) })
    }

    private var usageChannel: UsageChannel? {
        guard let client = bridge?.servicesClient() else { return nil }
        return UsageChannel(client: client, onLog: { ZDlog("[ZCodeMobile][usage] %@", $0) })
    }

    var currentModelLabel: String {
        let model = selectedModel.isEmpty ? (conversationStateForUI?.snapshotRaw["config"] as? [String: Any])?["model"] as? String ?? "" : selectedModel
        return model.isEmpty ? "GLM-5.3" : model
    }

    func refreshSessionConfig() {
        guard let task = selectedTask, let channel = configChannel else { return }
        let path = activeWorkspace?.workspacePath ?? task.workspacePath
        Task {
            guard let config = await channel.readWorkspaceConfig(workspacePath: path) else { return }
            await MainActor.run {
                if !config.models.isEmpty { self.modelCatalog = config.models }
                if !config.thoughtLevels.isEmpty { self.thoughtLevelsRemote = config.thoughtLevels }
                // 当前选择:优先会话快照 config,其次目录首项
                let snapshot = self.conversationStateForUI?.snapshotRaw["config"] as? [String: Any] ?? [:]
                if let model = snapshot["model"] as? String, !model.isEmpty {
                    self.selectedModel = model
                } else if self.selectedModel.isEmpty, let first = config.models.first {
                    self.selectedModel = first.modelId
                }
                if let provider = snapshot["provider"] as? String, !provider.isEmpty {
                    self.selectedProvider = provider
                } else if self.selectedProvider.isEmpty,
                          let matched = config.models.first(where: { $0.modelId == self.selectedModel }) {
                    self.selectedProvider = matched.providerId
                }
                if let thought = snapshot["thought"] as? String, !thought.isEmpty {
                    self.selectedThought = thought
                } else if let match = config.models.first(where: { $0.modelId == self.selectedModel }),
                          let last = match.thoughtLevels.last {
                    self.selectedThought = last
                }
            }
        }
    }

    @Published var thoughtLevelsRemote: [String] = []

    func applyMode(_ mode: String) {
        selectedMode = mode // 乐观更新
        isApplyingMode = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.isApplyingMode = false
        }
        guard let task = selectedTask, let conversation = conversation else { return }
        let path = activeWorkspace?.workspacePath ?? task.workspacePath
        Task {
            do {
                let revision = self.conversationStateForUI?.revision
                let ack = try await conversation.switchMode(mode, sessionId: task.taskId,
                                                            workspacePath: path,
                                                            workspaceIdentity: task.workspaceIdentity,
                                                            baseRevision: revision)
                ZDlog("[ZCodeMobile][config] switchCollaborationMode %@ → %@", mode, ack.status)
                await MainActor.run {
                    if ack.isSuccess { self.showToast("模式已切换") }
                    else { self.showToast("模式切换被拒:\(ack.message ?? ack.status)") }
                }
            } catch {
                ZDlog("[ZCodeMobile][config] switchMode failed: %@", String(describing: error))
                await MainActor.run { self.showToast("模式切换失败") }
            }
        }
    }

    func applyModel(provider: String, model: String) {
        selectedProvider = provider
        selectedModel = model
        guard let task = selectedTask, let conversation = conversation else { return }
        let path = activeWorkspace?.workspacePath ?? task.workspacePath
        let thought = selectedThought.isEmpty ? "high" : selectedThought
        Task {
            do {
                let revision = self.conversationStateForUI?.revision
                let ack = try await conversation.switchModel(provider: provider, model: model, thought: thought,
                                                             sessionId: task.taskId, workspacePath: path,
                                                             workspaceIdentity: task.workspaceIdentity,
                                                             baseRevision: revision)
                ZDlog("[ZCodeMobile][config] switchModelConfig %@/%@ thought=%@ → %@",
                      provider, model, thought, ack.status)
                await MainActor.run {
                    self.showToast(ack.isSuccess ? "模型已切换" : "模型切换被拒:\(ack.message ?? ack.status)")
                }
            } catch {
                ZDlog("[ZCodeMobile][config] switchModel failed: %@", String(describing: error))
                await MainActor.run { self.showToast("模型切换失败") }
            }
        }
    }

    func applyThought(_ level: String) {
        selectedThought = level
        let provider = selectedProvider.isEmpty ? currentProvider : selectedProvider
        applyModel(provider: provider, model: currentModelLabel)
    }

    func refreshUsage() {
        Task {
            // 1) 官方计费 REST(coding plan 用量/重置)
            if let device = self.device, let jwt = self.tokenStore.validJWT(),
               let billing = try? await self.api.fetchBilling(origin: device.origin, jwt: jwt) {
                if let report = self.makeBillingReport(billing, provider: "coding-plan.billing") {
                    await MainActor.run { self.usageReport = report }
                    return
                }
            }
            // 2) 通道探测(桌面版本开放时可用)
            guard let channel = usageChannel else { return }
            if let report = await channel.fetchUsage() {
                await MainActor.run { self.usageReport = report }
            }
        }
    }

    /// 解析计费 JSON:启发式提取用量/总量/百分比/重置时间
    private func makeBillingReport(_ dict: [String: Any], provider: String) -> UsageChannel.UsageReport? {
        var report = UsageChannel.UsageReport(raw: dict, used: nil, limit: nil, resetAt: nil, provider: provider)

        // coding-plan:plans[].entitlements[].grant_units / ends_at
        if let plans = dict["plans"] as? [[String: Any]], let plan = plans.first {
            if let ends = plan["ends_at"] as? Double {
                report.resetAt = Date(timeIntervalSince1970: ends)
            }
            if let entitlements = plan["entitlements"] as? [[String: Any]], let ent = entitlements.first {
                if let grant = ent["grant_units"] as? Double { report.limit = grant }
                if let used = ent["used_units"] as? Double { report.used = used }
                if let name = ent["show_name"] as? String {
                    report.raw["_entitlement_name"] = name
                }
            }
            if let name = plan["name"] as? String {
                report.raw["_plan_name"] = name
            }
        }
        func scan(_ d: [String: Any]) {
            for (key, value) in d {
                let lower = key.lowercased()
                if let n = value as? Double {
                    let seconds = n > 1e12 ? n / 1000 : n
                    if lower.contains("reset") || lower.contains("expire") || lower.contains("renew") {
                        report.resetAt = Date(timeIntervalSince1970: seconds)
                    } else if lower.contains("percent") || lower.contains("usedratio") {
                        report.limit = report.limit ?? 100
                        report.used = report.used ?? n
                    } else if lower.contains("used") || lower.contains("consumed") || lower.contains("count") {
                        report.used = report.used ?? n
                    } else if lower.contains("limit") || lower.contains("total") || lower.contains("quota") || lower.contains("max") {
                        report.limit = report.limit ?? n
                    }
                    _ = seconds
                } else if let str = value as? String,
                          lower.contains("reset") || lower.contains("expire") || lower.contains("renew") {
                    if let date = ISO8601DateFormatter().date(from: str) { report.resetAt = date }
                } else if let nested = value as? [String: Any] {
                    scan(nested)
                }
            }
        }
        if let plans = dict["plans"],
           let data = try? JSONSerialization.data(withJSONObject: plans, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            ZDlog("[ZCodeMobile][billing] PLANS %@", String(text.prefix(1500)))
        }
        scan(dict)
        ZDlog("[ZCodeMobile][billing] parsed used=%@ limit=%@ reset=%@",
              String(describing: report.used), String(describing: report.limit),
              report.resetAt.map { "\($0)" } ?? "nil")
        return report
    }

    /// 把当前会话投影到实时活动(锁屏 + 灵动岛)
    func updateLiveActivity() {
        guard openConversation, let task = selectedTask else {
            LiveActivityManager.shared.end()
            return
        }
        let state = conversationStateForUI
        let interactions = state?.pendingInteractions ?? []
        let permissions = interactions.filter { $0.kind == "permission" }.count
        let inputs = interactions.filter { $0.kind == "userInput" }.count

        let phase: SessionActivityPhase
        if permissions > 0 {
            phase = .awaitingApproval
        } else if inputs > 0 {
            phase = .awaitingInput
        } else if state?.isRunning == true {
            phase = .running
        } else if let rawPhase = state?.control.phase, rawPhase.hasPrefix("error") {
            phase = .failed
        } else {
            phase = .idle
        }

        let lastTool = state?.rows.last(where: { $0.kind == "toolCall" && $0.state == "running" })?.toolName
        LiveActivityManager.shared.sync(
            sessionID: task.taskId,
            title: state?.title ?? task.title,
            phase: phase,
            approvalCount: permissions + inputs,
            model: currentModelLabel,
            modeLabel: availableModes.first { $0.value == selectedMode }?.label ?? selectedMode,
            workspaceShort: workspaceShortPathForActivity,
            lastToolName: lastTool)
    }

    private var workspaceShortPathForActivity: String {
        let path = activeWorkspace?.workspacePath ?? selectedTask?.workspacePath ?? ""
        return path.replacingOccurrences(of: "/Users/", with: "~/")
    }

    /// 从会话快照同步当前 模型/思考/模式(桌面端为准)
    func syncSelectionsFromState() {
        guard let config = conversationStateForUI?.snapshotRaw["config"] as? [String: Any] else { return }
        if let mode = config["mode"] as? String, !mode.isEmpty,
           mode != selectedMode, !isApplyingMode {
            selectedMode = normalizedMode(mode)
        }
        if let model = config["model"] as? String, !model.isEmpty {
            selectedModel = model
        }
        if let provider = config["provider"] as? String, !provider.isEmpty {
            selectedProvider = provider
        }
        if let thought = config["thought"] as? String, !thought.isEmpty {
            selectedThought = thought
        }
    }

    private var isApplyingMode = false

    private func normalizedMode(_ raw: String) -> String {
        switch raw.lowercased() {
        case "full-access", "agent-full-access", "bypasspermissions": return "yolo"
        case "auto", "authedits", "autoedit", "dontask", "agent", "edit": return "edit"
        case "guarded": return "guarded"
        case "plan": return "plan"
        case "default", "build": return "build"
        default: return raw
        }
    }

    /// 会话列表空窗自愈:桥就绪但 3 秒内没有任务 → 重新订阅 controller(最多 4 次)
    private var taskListRetries = 0
    private func ensureTaskListLoaded() {
        guard tasks.isEmpty, taskListRetries < 4 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.tasks.isEmpty, self.bridgePhase == .ready else { return }
            self.taskListRetries += 1
            ZDlog("[ZCodeMobile] task list still empty, retry controller #%d", self.taskListRetries)
            self.bridge?.retryController()
            self.ensureTaskListLoaded()
        }
    }

    var isSyncingTasks: Bool { bridgePhase == .ready && tasks.isEmpty }

    // MARK: - 会话刷新节流(50ms 合并多次帧更新)

    private var pendingRefresh: DispatchWorkItem?

    private func scheduleConversationRefresh() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.pendingRefresh == nil {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.syncSelectionsFromState()
                    self.updateLiveActivity()
                    self.conversationTick += 1
                    self.pendingRefresh = nil
                }
                self.pendingRefresh = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
            }
        }
    }

    // MARK: - 网络监听

    private func startNetworkMonitor() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            DispatchQueue.main.async {
                guard let relay = self.relay else { return }
                if path.status == .satisfied {
                    relay.handleNetworkRestored()
                } else {
                    relay.handleNetworkLost()
                }
            }
        }
        networkMonitor.start(queue: DispatchQueue(label: "zcode-mobile.network"))
    }
}
