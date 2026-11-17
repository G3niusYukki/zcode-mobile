import ActivityKit
import Foundation
import ZCodeMobileCore

/// 把当前会话投影为系统实时活动(锁屏卡 + 灵动岛)。
/// 本地更新只在前台/短后台有效;长时间离屏依赖系统展示的最后状态(staleDate 兜底)。
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private var activity: Activity<SessionActivityAttributes>?
    private var currentSessionID: String?
    private var pendingUpdate: Task<Void, Never>?
    private var startedAtBySession: [String: Date] = [:]
    private var tokenTask: Task<Void, Never>?
    private let staleInterval: TimeInterval = 15 * 60

    /// 推送 token / 状态变化(用于上报中转,由 AppModel 消费)
    var onPushTokenOrStateChanged: (() -> Void)?
    private(set) var latestPushTokenHex: String?
    private(set) var latestStateJSON: String?

    /// 收集活动推送 token(Live Activity 远程更新凭据)
    private func observeToken(_ activity: Activity<SessionActivityAttributes>) {
        tokenTask?.cancel()
        tokenTask = Task { [weak self] in
            for await tokenData in activity.pushTokenUpdates {
                let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                await MainActor.run {
                    self?.latestPushTokenHex = hex
                    self?.onPushTokenOrStateChanged?()
                }
            }
        }
    }

    // MARK: 同步入口(节流 0.6s)

    func sync(sessionID: String, title: String, phase: SessionActivityPhase,
              approvalCount: Int, model: String, modeLabel: String,
              workspaceShort: String, lastToolName: String?) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        if phase.isTerminal {
            end(sessionID: sessionID, finalPhase: phase)
            return
        }

        let startedAt = startedAtBySession[sessionID] ?? Date()
        startedAtBySession[sessionID] = startedAt
        let state = SessionActivityAttributes.ContentState(
            title: title, phase: phase, approvalCount: approvalCount,
            model: model, modeLabel: modeLabel, workspaceShort: workspaceShort,
            lastToolName: lastToolName, updatedAt: Date())

        pendingUpdate?.cancel()
        pendingUpdate = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            await self?.apply(sessionID: sessionID, title: title,
                              startedAt: startedAt, state: state)
        }
    }

    private func apply(sessionID: String, title: String,
                       startedAt: Date, state: SessionActivityAttributes.ContentState) async {
        if let existing = activity, currentSessionID == sessionID {
            let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(staleInterval))
            await existing.update(content)
            latestStateJSON = Self.encodeState(state)
            onPushTokenOrStateChanged?()
            return
        }
        // 换了会话:结束旧的,起新的
        if let existing = activity {
            await existing.end(nil, dismissalPolicy: .immediate)
            activity = nil
            currentSessionID = nil
        }
        let attributes = SessionActivityAttributes(sessionID: sessionID,
                                                   startedAt: startedAt)
        do {
            let created = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state,
                                         staleDate: Date().addingTimeInterval(staleInterval)),
                pushType: .token)
            activity = created
            currentSessionID = sessionID
            observeToken(created)
            latestStateJSON = Self.encodeState(state)
            onPushTokenOrStateChanged?()
            ZDlog("[ZCodeMobile][live] started activity for %@", sessionID)
        } catch {
            ZDlog("[ZDuo][live] request failed: %@", String(describing: error))
        }
    }

    static func encodeState(_ state: SessionActivityAttributes.ContentState) -> String? {
        guard let data = try? JSONEncoder().encode(state) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 结束(离开会话/任务终止)
    func end(sessionID: String? = nil, finalPhase: SessionActivityPhase = .completed) {
        guard let existing = activity else { return }
        if let sessionID, currentSessionID != sessionID { return }
        let finalState = existing.content.state
        let content = ActivityContent(
            state: SessionActivityAttributes.ContentState(
                title: finalState.title, phase: finalPhase,
                approvalCount: 0, model: finalState.model, modeLabel: finalState.modeLabel,
                workspaceShort: finalState.workspaceShort, lastToolName: nil,
                updatedAt: Date()),
            staleDate: nil)
        let activityToEnd = existing
        activity = nil
        currentSessionID = nil
        latestPushTokenHex = nil
        latestStateJSON = nil
        tokenTask?.cancel()
        Task { await activityToEnd.end(content, dismissalPolicy: .after(Date().addingTimeInterval(30))) }
        ZDlog("[ZDuo][live] end activity")
    }
}
