import SwiftUI
import ZCodeMobileCore

/// 用量与配额:上下文用量(快照) + 套餐配额(usage-stats/coding-plan 探测)
struct UsageSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showRaw = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    contextSection
                    quotaSection
                    if let report = model.usageReport {
                        rawSection(report)
                    }
                }
                .padding(22)
            }
            .scrollIndicators(.hidden)
            .background(Theme.background())
            .navigationTitle("用量与配额")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .task { model.refreshUsage() }
        }
    }

    // MARK: 上下文用量

    private var contextUsage: (used: Int, max: Int, cacheHit: Double?)? {
        guard let state = model.conversationStateForUI,
              let usage = state.snapshotRaw["usage"] as? [String: Any],
              let window = usage["contextWindow"] as? [String: Any] else { return nil }
        let used = window["usedTokens"] as? Int ?? 0
        let max = window["maxTokens"] as? Int ?? 0
        let cacheHit = (window["cache"] as? [String: Any])?["hitRate"] as? Double
        guard max > 0 else { return nil }
        return (used, max, cacheHit)
    }

    private var contextSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("上下文用量")
            GlassCard(padding: 16, cornerRadius: 18) {
                if let usage = contextUsage {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(format(usage.used)) / \(format(usage.max))")
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Text(String(format: "%.0f%%", Double(usage.used) / Double(usage.max) * 100))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.azure)
                        }
                        progressBar(Double(usage.used) / Double(max(1, usage.max)))
                        HStack(spacing: 14) {
                            if let hit = usage.cacheHit {
                                chip(icon: "bolt.fill", text: "缓存命中 \(String(format: "%.0f%%", hit * 100))")
                            }
                            chip(icon: "arrow.down.circle", text: "自动压缩已开启")
                        }
                    }
                } else {
                    Text("打开一个会话后显示上下文用量")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    // MARK: 套餐配额

    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("套餐配额")
            GlassCard(padding: 16, cornerRadius: 18) {
                if let report = model.usageReport {
                    VStack(alignment: .leading, spacing: 10) {
                        if let planName = report.raw["_plan_name"] as? String {
                            HStack(spacing: 6) {
                                Image(systemName: "crown.fill").font(.system(size: 11)).foregroundStyle(Theme.amber)
                                Text(planName)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.textPrimary)
                            }
                        }
                        if report.used == nil, let limit = report.limit, limit > 0 {
                            HStack(alignment: .firstTextBaseline) {
                                Text("额度 \(format(Int(limit)))")
                                    .font(.system(size: 22, weight: .bold, design: .rounded))
                                    .foregroundStyle(Theme.textPrimary)
                                if let entName = report.raw["_entitlement_name"] as? String {
                                    Text(entName)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.textTertiary)
                                }
                                Spacer()
                            }
                            if let resetAt = report.resetAt {
                                HStack(spacing: 6) {
                                    Image(systemName: "clock.badge.exclamationmark").font(.system(size: 11))
                                    Text("到期:\(resetAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.system(size: 12))
                                }
                                .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        if let used = report.used, let limit = report.limit, limit > 0 {
                            HStack(alignment: .firstTextBaseline) {
                                Text("\(format(Int(used))) / \(format(Int(limit)))")
                                    .font(.system(size: 22, weight: .bold, design: .rounded))
                                    .foregroundStyle(Theme.textPrimary)
                                Spacer()
                                Text(String(format: "%.0f%%", used / limit * 100))
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.mint)
                            }
                            progressBar(used / limit)
                        }
                        if let resetAt = report.resetAt {
                            HStack(spacing: 6) {
                                Image(systemName: "clock.arrow.circlepath").font(.system(size: 11))
                                Text("下次重置:\(resetAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.system(size: 12))
                            }
                            .foregroundStyle(Theme.textSecondary)
                        }
                        Text("数据源:\(report.provider)")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("桌面端未返回配额数据")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textSecondary)
                        Text("当前会话的上下文用量在上方;套餐配额取决于桌面端版本开放的接口。")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
        }
    }

    private func rawSection(_ report: UsageChannel.UsageReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation { showRaw.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("原始数据")
                        .font(.system(size: 12, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(showRaw ? 180 : 0))
                }
                .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)

            if showRaw, let data = try? JSONSerialization.data(withJSONObject: report.raw, options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                Text(text)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cardFillStrong))
            }
        }
    }

    // MARK: 组件

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.textTertiary)
            .padding(.leading, 2)
    }

    private func progressBar(_ fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.cardFill)
                Capsule()
                    .fill(LinearGradient(colors: [Theme.azure, Theme.mint],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 8)
    }

    private func chip(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9))
            Text(text).font(.system(size: 10.5))
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Theme.cardFill))
    }

    private func format(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}
