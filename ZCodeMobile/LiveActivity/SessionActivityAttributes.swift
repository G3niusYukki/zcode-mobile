import ActivityKit
import Foundation

/// 主 App 与 Widget Extension 共享的实时活动模型。
struct SessionActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var phase: SessionActivityPhase
        var approvalCount: Int
        var model: String
        var modeLabel: String
        var workspaceShort: String
        var lastToolName: String?
        var updatedAt: Date
    }

    let sessionID: String
    let startedAt: Date
}

enum SessionActivityPhase: String, Codable, Hashable {
    case running
    case awaitingApproval
    case awaitingInput
    case idle
    case completed
    case failed

    var isTerminal: Bool {
        switch self {
        case .completed, .failed: return true
        case .running, .awaitingApproval, .awaitingInput, .idle: return false
        }
    }

    var label: String {
        switch self {
        case .running: return "运行中"
        case .awaitingApproval: return "待审批"
        case .awaitingInput: return "待回答"
        case .idle: return "待机"
        case .completed: return "已完成"
        case .failed: return "失败"
        }
    }

    var symbol: String {
        switch self {
        case .running: return "play.circle.fill"
        case .awaitingApproval: return "hand.raised.fill"
        case .awaitingInput: return "questionmark.bubble.fill"
        case .idle: return "pause.circle"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }
}
