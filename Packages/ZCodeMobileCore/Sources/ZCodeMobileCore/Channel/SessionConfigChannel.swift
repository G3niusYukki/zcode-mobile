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

    // 模型/模式切换统一走会话命令(sendConversationCommandV4),
    // 官方 schema:switchModelConfig{provider,model,thought} / switchCollaborationMode{mode:[build,edit,plan,yolo,guarded]}
}

// MARK: - 用量/配额(usage-stats / coding-plan-subscription 探测)

public final class UsageChannel: @unchecked Sendable {
    public struct UsageReport {
        public var raw: [String: Any]
        public var used: Double?
        public var limit: Double?
        public var resetAt: Date?
        public var provider: String
        public init(raw: [String: Any], used: Double?, limit: Double?, resetAt: Date?, provider: String) {
            self.raw = raw
            self.used = used
            self.limit = limit
            self.resetAt = resetAt
            self.provider = provider
        }
    }

    private let client: ChannelClient
    private let logger: (String) -> Void

    public init(client: ChannelClient, onLog: ((String) -> Void)? = nil) {
        self.client = client
        self.logger = onLog ?? { _ in }
    }

    public func fetchUsage() async -> UsageReport? {
        let candidates: [(String, String)] = [
            ("usage-stats", "getSummary"), ("usage-stats", "getUsage"),
            ("usage-stats", "read"), ("usage-stats", "getView"),
            ("usage-stats", "summary"), ("usage-stats", "getStats"),
            ("usage-stats", "readUsage"), ("usage-stats", "getDailyUsage"),
            ("coding-plan-subscription", "getStatus"), ("coding-plan-subscription", "readStatus"),
            ("coding-plan-subscription", "getQuota"), ("coding-plan-subscription", "status"),
            ("coding-plan-subscription", "getSubscription"), ("coding-plan-subscription", "getView"),
            ("coding-plan-subscription", "readView"), ("coding-plan-subscription", "getQuotaSummary"),
            ("coding-plan-subscription", "readQuotaSummary"),
        ]
        for (channel, method) in candidates {
            do {
                let result = try await client.call(channel, method,
                                                  args: [.object([])], timeout: 15)
                if case .json(let text) = result,
                   let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                    logger("[usage] \(channel).\(method) ok")
                    var report = UsageReport(raw: obj, used: nil, limit: nil, resetAt: nil,
                                             provider: "\(channel).\(method)")
                    extract(into: &report, from: obj)
                    return report
                }
            } catch {
                logger("[usage] \(channel).\(method) failed: \(String(describing: error))")
            }
        }
        return nil
    }

    private func extract(into report: inout UsageReport, from dict: [String: Any]) {
        for (key, value) in dict {
            let lower = key.lowercased()
            if let number = value as? Double {
                if lower.contains("used") || lower.contains("count") { report.used = report.used ?? number }
                if lower.contains("limit") || lower.contains("total") || lower.contains("quota") {
                    report.limit = report.limit ?? number
                }
                if lower.contains("percent") || lower.contains("ratio") {
                    report.limit = report.limit ?? 100
                    report.used = report.used ?? number
                }
                if lower.contains("reset") || lower.contains("expire") {
                    let seconds = number > 1e12 ? number / 1000 : number
                    report.resetAt = Date(timeIntervalSince1970: seconds)
                }
            }
            if lower.contains("reset") || lower.contains("expire"), let string = value as? String,
               let date = ISO8601DateFormatter().date(from: string) {
                report.resetAt = date
            }
            if let nested = value as? [String: Any] {
                extract(into: &report, from: nested)
            }
        }
    }
}
