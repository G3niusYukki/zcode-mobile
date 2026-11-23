import Foundation

/// 会话配置:模型目录 / 思考档位 / 审批模式(zcode-session 通道,方法带探测)。
public final class SessionConfigChannel: @unchecked Sendable {

    public struct ModelOption: Equatable, Identifiable {
        public let providerId: String
        public let modelId: String
        public let name: String
        public let thoughtLevels: [String]
        public var id: String { "\(providerId)/\(modelId)" }
    }

    public struct ModeOption: Equatable, Identifiable {
        public let value: String
        public let label: String
        public var id: String { value }
        /// 官方 switchCollaborationMode 枚举:build/edit/plan/yolo/guarded
        public static let fallback: [ModeOption] = [
            .init(value: "yolo", label: "完全访问"),
            .init(value: "edit", label: "自动审批"),
            .init(value: "guarded", label: "严格审批"),
            .init(value: "build", label: "默认"),
            .init(value: "plan", label: "计划"),
        ]
    }

    public struct WorkspaceConfig: Equatable {
        public var models: [ModelOption] = []
        public var modes: [ModeOption] = ModeOption.fallback
        public var thoughtLevels: [String] = []
        public var currentProvider: String?
        public var currentModel: String?
        public var currentThought: String?
        public var currentMode: String?
        public var raw: [String: Any] = [:]
        public static func == (a: WorkspaceConfig, b: WorkspaceConfig) -> Bool {
            a.models == b.models && a.currentProvider == b.currentProvider
                && a.currentModel == b.currentModel && a.currentThought == b.currentThought
                && a.currentMode == b.currentMode && a.thoughtLevels == b.thoughtLevels
        }
    }

    private let client: ChannelClient
    private let logger: (String) -> Void

    public init(client: ChannelClient, onLog: ((String) -> Void)? = nil) {
        self.client = client
        self.logger = onLog ?? { _ in }
    }

    // MARK: 读取模型目录(model-selection.getView)

    public func readWorkspaceConfig(workspacePath: String) async -> WorkspaceConfig? {
        _ = workspacePath
        do {
            let result = try await client.call("model-selection", "getView", args: [], timeout: 15)
            guard case .json(let text) = result,
                  let data = text.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let config = parseCatalog(obj)
            logger("[config] getView ok providers=\(Set(config.models.map(\.providerId)).count) models=\(config.models.count)")
            return config
        } catch {
            logger("[config] getView failed: \(String(describing: error))")
            return nil
        }
    }

    /// 官方结构:providers[].{providerId, providerName, models[].{modelId, config.optionSpecs.reasoningLevel.values}}
    private func parseCatalog(_ obj: [String: Any]) -> WorkspaceConfig {
        var config = WorkspaceConfig()
        config.raw = obj
        var models: [ModelOption] = []
        if let providers = obj["providers"] as? [[String: Any]] {
            for provider in providers {
                let pid = provider["providerId"] as? String ?? ""
                let providerName = provider["providerName"] as? String ?? pid
                guard !pid.isEmpty, let list = provider["models"] as? [[String: Any]] else { continue }
                for model in list {
                    let mid = model["modelId"] as? String ?? ""
                    guard !mid.isEmpty else { continue }
                    var levels: [String] = []
                    if let cfg = model["config"] as? [String: Any],
                       let specs = cfg["optionSpecs"] as? [String: Any],
                       let reasoning = specs["reasoningLevel"] as? [String: Any],
                       let values = reasoning["values"] as? [String] {
                        levels = values
                    }
                    models.append(ModelOption(providerId: pid, modelId: mid,
                                              name: "\(mid) · \(providerName)", thoughtLevels: levels))
                }
            }
        }
        config.models = models
        if let first = models.first(where: { $0.thoughtLevels.contains("high") }) ?? models.first {
            config.thoughtLevels = first.thoughtLevels
        }
        return config
    }
}

// MARK: - 用量/配额/使用统计(桌面端 usage-stats + provider-settings 真实通道)

public final class UsageChannel: @unchecked Sendable {

    // MARK: 会话上下文分解模型(对齐桌面端 snapshot.usage)

    public struct ContextBreakdownItem: Equatable, Sendable, Identifiable {
        public let source: String
        public let label: String
        public let chars: Int
        public let percent: Double // 0...1
        public var id: String { source }

        public init(source: String, label: String, chars: Int, percent: Double) {
            self.source = source
            self.label = label
            self.chars = chars
            self.percent = percent
        }
    }

    public struct ContextUsageSnapshot: Equatable, Sendable {
        public let usedTokens: Int
        public let maxTokens: Int
        public let cacheHitRate: Double? // 0...1
        public let totalInputTokens: Int?
        public let totalCacheReadTokens: Int?
        public let breakdown: [ContextBreakdownItem]

        public init(
            usedTokens: Int,
            maxTokens: Int,
            cacheHitRate: Double?,
            totalInputTokens: Int? = nil,
            totalCacheReadTokens: Int? = nil,
            breakdown: [ContextBreakdownItem] = []
        ) {
            self.usedTokens = usedTokens
            self.maxTokens = maxTokens
            self.cacheHitRate = cacheHitRate
            self.totalInputTokens = totalInputTokens
            self.totalCacheReadTokens = totalCacheReadTokens
            self.breakdown = breakdown
        }

        public var ratio: Double {
            guard maxTokens > 0 else { return 0 }
            return min(1, max(0, Double(usedTokens) / Double(maxTokens)))
        }

        /// 同时兼容桌面端真实结构 `usage.{used,size,cache,breakdown}` 与旧版 `usage.contextWindow.{usedTokens,maxTokens,cache}`
        public static func parse(from snapshotRaw: [String: Any]) -> ContextUsageSnapshot? {
            guard let usage = snapshotRaw["usage"] as? [String: Any] else { return nil }
            let window = usage["contextWindow"] as? [String: Any]

            let used = intVal(usage["used"]) ?? intVal(window?["usedTokens"]) ?? intVal(window?["used"]) ?? 0
            let maxVal = intVal(usage["size"]) ?? intVal(window?["maxTokens"]) ?? intVal(window?["size"]) ?? 0
            guard maxVal > 0 else { return nil }

            let cache = (usage["cache"] as? [String: Any]) ?? (window?["cache"] as? [String: Any])
            let hitRate = doubleVal(cache?["hitRate"])
            let totalInput = intVal(cache?["totalInputTokens"])
            let totalCacheRead = intVal(cache?["totalCacheReadTokens"])

            let rawBreakdown = (usage["breakdown"] as? [[String: Any]]) ?? (window?["breakdown"] as? [[String: Any]]) ?? []
            let breakdown = parseBreakdown(rawBreakdown)

            return ContextUsageSnapshot(
                usedTokens: used,
                maxTokens: maxVal,
                cacheHitRate: hitRate,
                totalInputTokens: totalInput,
                totalCacheReadTokens: totalCacheRead,
                breakdown: breakdown
            )
        }

        private static let sourceLabels: [String: (label: String, order: Int)] = [
            "messages": ("消息", 0),
            "system_tool_schemas": ("系统工具", 1),
            "mcp_tool_schemas": ("MCP 工具", 2),
            "meta_user_context": ("其他", 3),
            "skills": ("技能", 4),
            "system_prompt": ("系统提示词", 5),
            "tool_prompt": ("工具提示词", 6),
        ]

        private static func parseBreakdown(_ items: [[String: Any]]) -> [ContextBreakdownItem] {
            var totals: [String: Int] = [:]
            for item in items {
                guard let source = item["source"] as? String else { continue }
                let chars = intVal(item["chars"]) ?? intVal(item["tokens"]) ?? 0
                if chars >= 0 {
                    totals[source, default: 0] += chars
                }
            }
            let sum = totals.values.reduce(0, +)
            guard sum > 0 else { return [] }
            return totals.map { source, chars in
                let meta = sourceLabels[source]
                return ContextBreakdownItem(
                    source: source,
                    label: meta?.label ?? source,
                    chars: chars,
                    percent: Double(chars) / Double(sum)
                )
            }
            .sorted { a, b in
                if a.chars != b.chars { return a.chars > b.chars }
                return (sourceLabels[a.source]?.order ?? 99) < (sourceLabels[b.source]?.order ?? 99)
            }
        }
    }

    // MARK: 套餐剩余额度模型(5小时 / 每周 / 月度 / ZCode MCP)

    public struct QuotaWindow: Equatable, Sendable, Identifiable {
        public let id: String            // fiveHour | weekly | monthlyTool | serverMcp | generic-N
        public let label: String         // 5 小时 | 每周 | 月度工具 | ZCode MCP
        public let remainingPercent: Double // 0...100
        public let usedPercent: Double      // 0...100
        public let nextResetTime: Date?
        public let resetTimeStyle: String   // "dateTime" | "date"
        public let accentKey: String        // "blue" | "green" | "orange" | "purple"
        public let hasResetOpportunity: Bool
        public let remainingCount: Double?
        public let totalLimit: Double?

        public init(
            id: String,
            label: String,
            remainingPercent: Double,
            usedPercent: Double,
            nextResetTime: Date?,
            resetTimeStyle: String,
            accentKey: String,
            hasResetOpportunity: Bool = false,
            remainingCount: Double? = nil,
            totalLimit: Double? = nil
        ) {
            self.id = id
            self.label = label
            self.remainingPercent = remainingPercent
            self.usedPercent = usedPercent
            self.nextResetTime = nextResetTime
            self.resetTimeStyle = resetTimeStyle
            self.accentKey = accentKey
            self.hasResetOpportunity = hasResetOpportunity
            self.remainingCount = remainingCount
            self.totalLimit = totalLimit
        }
    }

    public struct ResetQuotaStatus: Equatable, Sendable {
        public let fiveHourCount: Int
        public let weekCount: Int
        public let earliestExpireAt: Date?

        public var totalCount: Int { fiveHourCount + weekCount }

        public init(fiveHourCount: Int, weekCount: Int, earliestExpireAt: Date? = nil) {
            self.fiveHourCount = fiveHourCount
            self.weekCount = weekCount
            self.earliestExpireAt = earliestExpireAt
        }
    }

    // MARK: 使用统计模型(7天 / 30天 / 累计)

    public struct DailyUsagePoint: Equatable, Sendable, Identifiable {
        public var id: String { date }
        public let date: String
        public let tokens: Int
        public let turns: Int

        public init(date: String, tokens: Int, turns: Int) {
            self.date = date
            self.tokens = tokens
            self.turns = turns
        }
    }

    public struct AppUsageStats: Equatable, Sendable {
        public let range: String
        public let totalTokens: Int
        public let peakDailyTokens: Int
        public let peakDailyDate: String?
        public let longestSessionMs: Int
        public let totalUsageDurationMs: Int
        public let currentStreakDays: Int
        public let longestStreakDays: Int
        public let sessionCount: Int?
        public let messageCount: Int?
        public let activeDays: Int?
        public let cacheHitRate: Double?
        public let favoriteModelName: String?
        public let totalCredits: Double?
        public let averageDailyCredits: Double?
        public let dailySeries: [DailyUsagePoint]

        public init(
            range: String,
            totalTokens: Int,
            peakDailyTokens: Int = 0,
            peakDailyDate: String? = nil,
            longestSessionMs: Int = 0,
            totalUsageDurationMs: Int = 0,
            currentStreakDays: Int = 0,
            longestStreakDays: Int = 0,
            sessionCount: Int? = nil,
            messageCount: Int? = nil,
            activeDays: Int? = nil,
            cacheHitRate: Double? = nil,
            favoriteModelName: String? = nil,
            totalCredits: Double? = nil,
            averageDailyCredits: Double? = nil,
            dailySeries: [DailyUsagePoint] = []
        ) {
            self.range = range
            self.totalTokens = totalTokens
            self.peakDailyTokens = peakDailyTokens
            self.peakDailyDate = peakDailyDate
            self.longestSessionMs = longestSessionMs
            self.totalUsageDurationMs = totalUsageDurationMs
            self.currentStreakDays = currentStreakDays
            self.longestStreakDays = longestStreakDays
            self.sessionCount = sessionCount
            self.messageCount = messageCount
            self.activeDays = activeDays
            self.cacheHitRate = cacheHitRate
            self.favoriteModelName = favoriteModelName
            self.totalCredits = totalCredits
            self.averageDailyCredits = averageDailyCredits
            self.dailySeries = dailySeries
        }
    }

    public struct UsageReport {
        public var raw: [String: Any]
        public var used: Double?
        public var limit: Double?
        public var resetAt: Date?
        public var provider: String
        public var planName: String?
        public var planLevel: String?
        public var planExpireAt: Date?
        public var providerDisplayName: String?
        public var quotaWindows: [QuotaWindow]
        public var resetStatus: ResetQuotaStatus?
        public var appUsage: AppUsageStats?
        public var unavailableReason: String?

        public init(
            raw: [String: Any],
            used: Double?,
            limit: Double?,
            resetAt: Date?,
            provider: String,
            planName: String? = nil,
            planLevel: String? = nil,
            planExpireAt: Date? = nil,
            providerDisplayName: String? = nil,
            quotaWindows: [QuotaWindow] = [],
            resetStatus: ResetQuotaStatus? = nil,
            appUsage: AppUsageStats? = nil,
            unavailableReason: String? = nil
        ) {
            self.raw = raw
            self.used = used
            self.limit = limit
            self.resetAt = resetAt
            self.provider = provider
            self.planName = planName
            self.planLevel = planLevel
            self.planExpireAt = planExpireAt
            self.providerDisplayName = providerDisplayName
            self.quotaWindows = quotaWindows
            self.resetStatus = resetStatus
            self.appUsage = appUsage
            self.unavailableReason = unavailableReason
        }
    }

    private struct ResolvedProviderCandidate {
        let providerId: String
        let accountAccess: [String: Any]?
        let isCodingPlan: Bool
        let priority: Int
    }

    private let client: ChannelClient
    private let logger: (String) -> Void

    public init(client: ChannelClient, onLog: ((String) -> Void)? = nil) {
        self.client = client
        self.logger = onLog ?? { _ in }
    }

    /// 完整读取桌面端真实配额、重置次数与使用统计
    public func fetchUsage(range: String = "30d", activeProviderId: String? = nil) async -> UsageReport? {
        let candidates = await discoverProviderCandidates(activeProviderId: activeProviderId)
        logger("[usage] discovered \(candidates.count) provider candidate(s): \(candidates.map(\.providerId))")

        // 1) 获取套餐真实剩余额度(5小时 / 每周 / 月度 / ZCode MCP)
        var entitlementRaw: [String: Any]?
        var matchedCandidate: ResolvedProviderCandidate?

        for candidate in candidates {
            if let snap = await callEntitlementSnapshot(candidate: candidate) {
                let hasQuota = (snap["quota"] as? [String: Any]) != nil || (snap["mcpQuota"] as? [String: Any]) != nil
                let hasSub = (snap["subscription"] as? [String: Any]) != nil
                if hasQuota || hasSub {
                    entitlementRaw = snap
                    matchedCandidate = candidate
                    logger("[usage] getEntitlementSnapshot matched provider=\(candidate.providerId)")
                    break
                }
                if entitlementRaw == nil {
                    entitlementRaw = snap
                    matchedCandidate = candidate
                }
            }
        }

        // 兜底:不传 preferredProviderId,让桌面端按默认凭证解析
        if entitlementRaw == nil || ((entitlementRaw?["quota"] as? [String: Any]) == nil && (entitlementRaw?["mcpQuota"] as? [String: Any]) == nil) {
            if let fallbackSnap = await callEntitlementSnapshot(candidate: nil) {
                let hasQuota = (fallbackSnap["quota"] as? [String: Any]) != nil || (fallbackSnap["mcpQuota"] as? [String: Any]) != nil
                if entitlementRaw == nil || hasQuota {
                    entitlementRaw = fallbackSnap
                    logger("[usage] getEntitlementSnapshot ok via default provider")
                }
            }
        }

        // 2) 并行获取重置额度状态 & 使用统计
        let codingCandidate = matchedCandidate ?? candidates.first(where: \.isCodingPlan)
        async let resetTask = callResetStatus(candidate: codingCandidate)
        async let appStatsTask = callAppUsageSnapshot(range: range)
        async let codingStatsTask = callCodingPlanUsageSnapshot(
            range: range == "all" ? "30d" : range,
            candidate: codingCandidate
        )

        let resetStatus = await resetTask
        let appStatsRaw = await appStatsTask
        let codingStatsRaw = await codingStatsTask

        guard entitlementRaw != nil || appStatsRaw != nil || codingStatsRaw != nil else {
            return nil
        }

        var mergedRaw: [String: Any] = [:]
        if let entitlementRaw { mergedRaw["entitlement"] = entitlementRaw }
        if let appStatsRaw { mergedRaw["appUsage"] = appStatsRaw }
        if let codingStatsRaw { mergedRaw["codingPlanUsage"] = codingStatsRaw }
        if let resetStatus {
            mergedRaw["resetStatus"] = [
                "fiveHourCount": resetStatus.fiveHourCount,
                "weekCount": resetStatus.weekCount,
            ]
        }

        let quotaWindows = parseQuotaWindows(entitlement: entitlementRaw, resetStatus: resetStatus)
        let appUsage = parseAppUsageStats(range: range, appRaw: appStatsRaw, codingRaw: codingStatsRaw)

        let providerObj = entitlementRaw?["provider"] as? [String: Any]
        let providerDisplay = providerObj?["name"] as? String
        let quotaObj = entitlementRaw?["quota"] as? [String: Any]
        let planLevel = quotaObj?["level"] as? String
        let subObj = entitlementRaw?["subscription"] as? [String: Any]
        let firstSub = (subObj?["details"] as? [[String: Any]])?.first
        let planName = (firstSub?["productName"] as? String)
            ?? (planLevel.map { "Coding Plan \($0.uppercased())" })
            ?? providerDisplay
        let planExpireAt = Self.parseDate(firstSub?["expireTime"])
        let unavailableReason = entitlementRaw?["unavailableReason"] as? String

        let primaryWindow = quotaWindows.first
        return UsageReport(
            raw: mergedRaw,
            used: primaryWindow?.usedPercent,
            limit: primaryWindow != nil ? 100 : nil,
            resetAt: primaryWindow?.nextResetTime ?? planExpireAt,
            provider: "usage-stats.getEntitlementSnapshot",
            planName: planName,
            planLevel: planLevel,
            planExpireAt: planExpireAt,
            providerDisplayName: providerDisplay,
            quotaWindows: quotaWindows,
            resetStatus: resetStatus,
            appUsage: appUsage,
            unavailableReason: unavailableReason
        )
    }

    // MARK: - 发现激活的 Coding Plan Provider

    private func discoverProviderCandidates(activeProviderId: String?) async -> [ResolvedProviderCandidate] {
        var result: [ResolvedProviderCandidate] = []
        do {
            let res = try await client.call("provider-settings", "getView", args: [], timeout: 10)
            if case .json(let text) = res,
               let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
               let providers = obj["providers"] as? [[String: Any]] {
                for p in providers {
                    guard let pid = p["providerId"] as? String, !pid.isEmpty else { continue }
                    let lower = pid.lowercased()
                    let isCoding = lower.contains("coding-plan")
                    let isStart = lower.contains("start-plan")
                    let isZhipu = isCoding || isStart || lower.contains("bigmodel") || lower.contains("zai")
                    guard isZhipu else { continue }

                    let availability = (p["accountState"] as? [String: Any])?["availability"] as? String
                    let enabled = p["enabled"] as? Bool ?? true
                    let access = normalizeAccountAccess(p["access"] as? [String: Any], providerId: pid)

                    var priority = 0
                    if pid == activeProviderId { priority += 100 }
                    if isCoding { priority += 50 }
                    if availability == "available" { priority += 30 }
                    if enabled { priority += 10 }
                    if access != nil { priority += 15 }

                    result.append(ResolvedProviderCandidate(
                        providerId: pid,
                        accountAccess: access,
                        isCodingPlan: isCoding,
                        priority: priority
                    ))
                }
            }
        } catch {
            logger("[usage] provider-settings.getView failed: \(String(describing: error))")
        }

        // 若 activeProviderId 不在列表里但属于 coding-plan,补入探测
        if let active = activeProviderId, !active.isEmpty,
           !result.contains(where: { $0.providerId == active }) {
            let isCoding = active.lowercased().contains("coding-plan")
            result.append(ResolvedProviderCandidate(
                providerId: active,
                accountAccess: nil,
                isCodingPlan: isCoding,
                priority: 80
            ))
        }

        return result.sorted { $0.priority > $1.priority }
    }

    private func normalizeAccountAccess(_ rawAccess: [String: Any]?, providerId: String) -> [String: Any]? {
        guard let rawAccess else { return nil }
        if let mode = rawAccess["mode"] as? String {
            if mode == "start-plan" || mode == "individual-coding-plan" {
                let family = (rawAccess["accountType"] as? String)
                    ?? (providerId.lowercased().contains("zai") ? "zai" : "bigmodel")
                return [
                    "type": "zhipu-account",
                    "family": family,
                    "planKind": mode,
                ]
            }
            if mode == "team-coding-plan" {
                var mapped: [String: Any] = [
                    "type": "zhipu-account",
                    "family": (rawAccess["accountType"] as? String)
                        ?? (providerId.lowercased().contains("zai") ? "zai" : "bigmodel"),
                    "planKind": mode,
                ]
                for key in ["organizationId", "projectId", "productId"] {
                    if let val = rawAccess[key] { mapped[key] = val }
                }
                return mapped
            }
        }
        if rawAccess["type"] != nil {
            return rawAccess
        }
        return nil
    }

    // MARK: - RPC 调用

    private func callEntitlementSnapshot(candidate: ResolvedProviderCandidate?) async -> [String: Any]? {
        var req: [String: Any] = [
            "includeSubscription": true,
            "allowDisabledPreferredProvider": true,
            "allowEnvApiKey": true,
        ]
        if let candidate {
            req["preferredProviderId"] = candidate.providerId
            req["requirePreferredProvider"] = false
            if let access = candidate.accountAccess {
                req["accountAccess"] = access
            }
        }
        do {
            let res = try await client.call("usage-stats", "getEntitlementSnapshot",
                                            args: [Self.toIpcValue(req)], timeout: 18)
            if case .json(let text) = res,
               let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                return obj
            }
        } catch {
            logger("[usage] getEntitlementSnapshot(\(candidate?.providerId ?? "default")) failed: \(String(describing: error))")
        }
        return nil
    }

    private func callResetStatus(candidate: ResolvedProviderCandidate?) async -> ResetQuotaStatus? {
        guard let candidate, candidate.isCodingPlan else { return nil }
        var req: [String: Any] = [
            "preferredProviderId": candidate.providerId,
            "allowEnvApiKey": true,
        ]
        if let access = candidate.accountAccess {
            req["accountAccess"] = access
        }
        do {
            let res = try await client.call("usage-stats", "getCodingPlanResetStatus",
                                            args: [Self.toIpcValue(req)], timeout: 12)
            if case .json(let text) = res,
               let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                let five = obj["available_five_hour_resets"] as? [[String: Any]] ?? []
                let week = obj["available_week_resets"] as? [[String: Any]] ?? []
                let expires = (five + week).compactMap { Self.parseDate($0["expire_at"]) }.sorted()
                logger("[usage] resetStatus five=\(five.count) week=\(week.count)")
                return ResetQuotaStatus(
                    fiveHourCount: five.count,
                    weekCount: week.count,
                    earliestExpireAt: expires.first
                )
            }
        } catch {
            logger("[usage] getCodingPlanResetStatus failed: \(String(describing: error))")
        }
        return nil
    }

    private func callAppUsageSnapshot(range: String) async -> [String: Any]? {
        let req: [String: Any] = [
            "range": range,
            "timeZone": TimeZone.current.identifier,
        ]
        do {
            let res = try await client.call("usage-stats", "getAppUsageSnapshot",
                                            args: [Self.toIpcValue(req)], timeout: 15)
            if case .json(let text) = res,
               let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                logger("[usage] getAppUsageSnapshot(\(range)) ok")
                return obj
            }
        } catch {
            logger("[usage] getAppUsageSnapshot(\(range)) failed: \(String(describing: error))")
        }
        return nil
    }

    private func callCodingPlanUsageSnapshot(range: String, candidate: ResolvedProviderCandidate?) async -> [String: Any]? {
        guard let candidate, candidate.isCodingPlan else { return nil }
        var req: [String: Any] = [
            "range": range,
            "preferredProviderId": candidate.providerId,
            "timeZone": TimeZone.current.identifier,
        ]
        if let access = candidate.accountAccess {
            req["accountAccess"] = access
        }
        do {
            let res = try await client.call("usage-stats", "getCodingPlanUsageSnapshot",
                                            args: [Self.toIpcValue(req)], timeout: 15)
            if case .json(let text) = res,
               let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                logger("[usage] getCodingPlanUsageSnapshot(\(range)) ok")
                return obj
            }
        } catch {
            logger("[usage] getCodingPlanUsageSnapshot(\(range)) failed: \(String(describing: error))")
        }
        return nil
    }

    // MARK: - 配额与统计解析

    private func parseQuotaWindows(entitlement: [String: Any]?, resetStatus: ResetQuotaStatus?) -> [QuotaWindow] {
        guard let entitlement else { return [] }
        let limits = (entitlement["quota"] as? [String: Any])?["limits"] as? [[String: Any]] ?? []
        let mcpAggregate = (entitlement["mcpQuota"] as? [String: Any])?["aggregate"] as? [String: Any]

        var windows: [QuotaWindow] = []

        // 1) 5 小时: type == TOKENS_LIMIT, unit == 3, number == 5
        if let five = limits.first(where: { matchesLimit($0, type: "TOKENS_LIMIT", unit: 3, number: 5) }) {
            if let item = makeQuotaWindow(
                id: "fiveHour", label: "5 小时", dict: five,
                resetTimeStyle: "dateTime", accentKey: "blue",
                hasResetOpportunity: (resetStatus?.fiveHourCount ?? 0) > 0
            ) {
                windows.append(item)
            }
        }

        // 2) 每周: type == TOKENS_LIMIT, unit == 6
        if let week = limits.first(where: { matchesLimit($0, type: "TOKENS_LIMIT", unit: 6, number: nil) }) {
            if let item = makeQuotaWindow(
                id: "weekly", label: "每周", dict: week,
                resetTimeStyle: "date", accentKey: "green",
                hasResetOpportunity: (resetStatus?.weekCount ?? 0) > 0
            ) {
                windows.append(item)
            }
        }

        // 3) 月度工具: type == TIME_LIMIT, unit == 5, number == 1
        if let monthly = limits.first(where: { matchesLimit($0, type: "TIME_LIMIT", unit: 5, number: 1) }) {
            if let item = makeQuotaWindow(
                id: "monthlyTool", label: "月度工具", dict: monthly,
                resetTimeStyle: "date", accentKey: "purple",
                hasResetOpportunity: false
            ) {
                windows.append(item)
            }
        }

        // 4) ZCode MCP: mcpQuota.aggregate
        if let mcpAggregate,
           let item = makeQuotaWindow(
               id: "serverMcp", label: "ZCode MCP", dict: mcpAggregate,
               resetTimeStyle: "date", accentKey: "orange",
               hasResetOpportunity: false
           ) {
            windows.append(item)
        }

        // 若未命中标准分类但 limits 非空,通用展示前 3 项
        if windows.isEmpty && !limits.isEmpty {
            let palette = ["blue", "green", "orange"]
            for (idx, dict) in limits.prefix(3).enumerated() {
                let type = dict["type"] as? String ?? "额度"
                let label = type.contains("TOKEN") ? "Token 额度" : (type.contains("TIME") ? "时长额度" : "额度 \(idx + 1)")
                if let item = makeQuotaWindow(
                    id: "generic-\(idx)", label: label, dict: dict,
                    resetTimeStyle: "date", accentKey: palette[idx % palette.count],
                    hasResetOpportunity: false
                ) {
                    windows.append(item)
                }
            }
        }

        return windows
    }

    private func matchesLimit(_ dict: [String: Any], type: String, unit: Int, number: Int?) -> Bool {
        guard let t = dict["type"] as? String, t.uppercased() == type else { return false }
        guard Self.intVal(dict["unit"]) == unit else { return false }
        if let number {
            return Self.intVal(dict["number"]) == number
        }
        return true
    }

    private func makeQuotaWindow(
        id: String,
        label: String,
        dict: [String: Any],
        resetTimeStyle: String,
        accentKey: String,
        hasResetOpportunity: Bool
    ) -> QuotaWindow? {
        let usedPct: Double
        let remainingPct: Double
        if let pct = Self.doubleVal(dict["percentage"]) {
            usedPct = min(100, max(0, pct))
            remainingPct = min(100, max(0, 100 - usedPct))
        } else if let rem = Self.doubleVal(dict["remaining"]),
                  let total = Self.doubleVal(dict["number"]) ?? Self.doubleVal(dict["limit"]),
                  total > 0 {
            remainingPct = min(100, max(0, rem / total * 100))
            usedPct = min(100, max(0, 100 - remainingPct))
        } else {
            return nil
        }

        return QuotaWindow(
            id: id,
            label: label,
            remainingPercent: remainingPct,
            usedPercent: usedPct,
            nextResetTime: Self.parseDate(dict["nextResetTime"]),
            resetTimeStyle: resetTimeStyle,
            accentKey: accentKey,
            hasResetOpportunity: hasResetOpportunity,
            remainingCount: Self.doubleVal(dict["remaining"]),
            totalLimit: Self.doubleVal(dict["limit"]) ?? Self.doubleVal(dict["number"])
        )
    }

    private func parseAppUsageStats(range: String, appRaw: [String: Any]?, codingRaw: [String: Any]?) -> AppUsageStats? {
        let appSummary = appRaw?["summary"] as? [String: Any]
        let codingActivity = codingRaw?["activity"] as? [String: Any]
        let codingSummary = codingActivity?["summary"] as? [String: Any]
        let codingDetail = (codingRaw?["detail"] as? [String: Any])?["summary"] as? [String: Any]

        guard appSummary != nil || codingSummary != nil || codingDetail != nil else { return nil }

        let totalTokens = Self.intVal(codingSummary?["totalTokens"])
            ?? Self.intVal(appSummary?["totalTokens"])
            ?? 0
        let peakDailyTokens = Self.intVal(codingSummary?["peakDailyTokens"])
            ?? Self.intVal(appSummary?["peakDayTokens"])
            ?? Self.intVal(appSummary?["peakDailyTokens"])
            ?? 0
        let peakDailyDate = (codingSummary?["peakDailyTokensDate"] as? String)
            ?? (appSummary?["peakDayDate"] as? String)
        let longestSessionMs = Self.intVal(appSummary?["longestSessionMs"]) ?? 0
        let totalUsageDurationMs = Self.intVal(codingSummary?["totalUsageDurationMs"])
            ?? Self.intVal(appSummary?["totalUsageDurationMs"])
            ?? 0
        let currentStreakDays = Self.intVal(codingSummary?["currentStreakDays"])
            ?? Self.intVal(appSummary?["currentStreakDays"])
            ?? 0
        let longestStreakDays = Self.intVal(codingSummary?["longestStreakDays"])
            ?? Self.intVal(appSummary?["longestStreakDays"])
            ?? 0
        let sessionCount = Self.intVal(appSummary?["sessionCount"]) ?? Self.intVal(appSummary?["sessions"])
        let messageCount = Self.intVal(appSummary?["messageCount"]) ?? Self.intVal(appSummary?["messages"])
        let activeDays = Self.intVal(appSummary?["activeDays"])
        let cacheHitRate = Self.doubleVal(codingDetail?["cacheHitRate"]) ?? Self.doubleVal(appSummary?["cacheHitRate"])
        let favoriteModel = (codingSummary?["favoriteModelName"] as? String)
            ?? (appSummary?["favoriteModelName"] as? String)
            ?? ((appSummary?["favoriteModel"] as? [String: Any])?["name"] as? String)
        let totalCredits = Self.doubleVal(codingDetail?["totalCredits"])
        let averageDailyCredits = Self.doubleVal(codingDetail?["averageDailyCredits"])

        let dailySeries = extractDailySeries(from: codingActivity) ?? extractDailySeries(from: appRaw) ?? []

        return AppUsageStats(
            range: range,
            totalTokens: totalTokens,
            peakDailyTokens: peakDailyTokens,
            peakDailyDate: peakDailyDate,
            longestSessionMs: longestSessionMs,
            totalUsageDurationMs: totalUsageDurationMs,
            currentStreakDays: currentStreakDays,
            longestStreakDays: longestStreakDays,
            sessionCount: sessionCount,
            messageCount: messageCount,
            activeDays: activeDays,
            cacheHitRate: cacheHitRate,
            favoriteModelName: favoriteModel,
            totalCredits: totalCredits,
            averageDailyCredits: averageDailyCredits,
            dailySeries: dailySeries
        )
    }

    private func extractDailySeries(from container: [String: Any]?) -> [DailyUsagePoint]? {
        guard let container else { return nil }
        var points: [DailyUsagePoint] = []
        if let heatmap = container["heatmap"] as? [String: Any],
           let weeks = heatmap["weeks"] as? [[String: Any]] {
            for week in weeks {
                guard let days = week["days"] as? [Any] else { continue }
                for entry in days {
                    guard let day = entry as? [String: Any],
                          let date = day["date"] as? String else { continue }
                    let tokens = Self.intVal(day["totalTokens"]) ?? Self.intVal(day["tokens"]) ?? 0
                    let turns = Self.intVal(day["turnCount"]) ?? Self.intVal(day["turns"]) ?? 0
                    points.append(DailyUsagePoint(date: date, tokens: tokens, turns: turns))
                }
            }
        } else if let daily = container["daily"] as? [[String: Any]] {
            for day in daily {
                guard let date = day["date"] as? String else { continue }
                let tokens = Self.intVal(day["totalTokens"]) ?? Self.intVal(day["tokens"]) ?? 0
                let turns = Self.intVal(day["turnCount"]) ?? Self.intVal(day["messages"]) ?? 0
                points.append(DailyUsagePoint(date: date, tokens: tokens, turns: turns))
            }
        }
        return points.isEmpty ? nil : points.sorted { $0.date < $1.date }
    }

    // MARK: - 工具函数

    private static func toIpcValue(_ value: Any) -> IpcValue {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return .json(text)
        }
        return .object([])
    }

    private static func intVal(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double, d.isFinite { return Int(d) }
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }

    private static func doubleVal(_ any: Any?) -> Double? {
        if let d = any as? Double, d.isFinite { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber {
            let v = n.doubleValue
            return v.isFinite ? v : nil
        }
        return nil
    }

    private static func parseDate(_ any: Any?) -> Date? {
        if let n = doubleVal(any), n > 0 {
            let seconds = n > 1e12 ? n / 1000 : n
            return Date(timeIntervalSince1970: seconds)
        }
        if let str = any as? String, !str.isEmpty {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: str) { return d }
            let basic = ISO8601DateFormatter()
            if let d = basic.date(from: str) { return d }
        }
        return nil
    }
}
