import SwiftUI
import ZCodeMobileCore

/// 会话/任务列表(Controller 通道权威数据源)
struct TasksScreen: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List(selection: $model.selectedTask) {
            Section {
                ForEach(model.tasks) { task in
                    TaskRow(task: task)
                        .tag(task)
                }
            } header: {
                statusHeader
            } footer: {
                if model.workspaces.count > 1 {
                    Text("工作区:\(model.workspaces.map(\.label).joined(separator: " · "))")
                        .lineLimit(1)
                }
            }
        }
        .overlay {
            if model.tasks.isEmpty {
                emptyState
            }
        }
        .navigationTitle("会话")
    }

    private var statusHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
            Text("\(model.relayPhase) · \(bridgePhaseText)")
                .font(.caption)
            Spacer()
            Button {
                model.reconnect()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
        }
    }

    private var statusIcon: String {
        switch model.bridgePhase {
        case .ready: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        default: return "antenna.radiowaves.left.and.right"
        }
    }

    private var statusColor: Color {
        switch model.bridgePhase {
        case .ready: return .green
        case .failed: return .orange
        default: return .blue
        }
    }

    private var bridgePhaseText: String {
        switch model.bridgePhase {
        case .idle: return "待命"
        case .connecting: return "连接中"
        case .bootstrapping: return "启动中"
        case .openingBridge: return "建立通道"
        case .ready: return "就绪"
        case .failed: return "失败"
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(model.relayPhase)
                .font(.callout)
                .foregroundStyle(.secondary)
            if let error = model.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button("重试") { model.reconnect() }
                    .buttonStyle(.bordered)
            }
        }
        .padding()
    }
}

struct TaskRow: View {
    let task: TaskEntry

    var body: some View {
        HStack(spacing: 10) {
            statusDot
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    if task.pinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Text(task.title)
                        .lineLimit(1)
                }
                Text(task.workspacePath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(relativeTime)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private var statusDot: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    private var color: Color {
        switch task.status {
        case "running", "prewarming": return .green
        case "waiting": return .orange
        case "error": return .red
        default: return .gray.opacity(0.5)
        }
    }

    private var relativeTime: String {
        let date = Date(timeIntervalSince1970: task.updatedAt / 1000)
        return date.formatted(.relative(presentation: .named))
    }
}
