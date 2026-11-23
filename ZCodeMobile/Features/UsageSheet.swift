import SwiftUI
import ZCodeMobileCore

/// 用量与配额(对齐桌面端 ZCode):
/// 1) 当前会话上下文容量(总量/来源分解/平均缓存命中率)
/// 2) 真实套餐剩余额度(5 小时 / 每周 / 月度 / ZCode MCP + 重置额度次数)
/// 3) 使用统计(7天/30天/累计 Token、峰值、连续天数、最常用模型与每日趋势)
struct UsageSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showRaw = false
    @State private var animateBars = false
    @State private var copiedRaw = false

    private let ranges: [(id: String, label: String)] = [
        ("7d", "7 天"),
        ("30d", "30 天"),
        ("all", "累计"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    contextSection
                    quotaSection
                    usageStatsSection
                    if let report = model.usageReport {
                        rawSection(report)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
            .scrollIndicators(.hidden)
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
            .navigationTitle("用量与配额")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Haptics.light()
                        model.refreshUsage()
                    } label: {
                        if model.isRefreshingUsage {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 14, weight: .semibold))
                        }
                    }
                    .accessibilityLabel("刷新用量")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        Haptics.light()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .task {
                model.refreshUsage()
                withAnimation(Motion.gentle.delay(0.08)) {
                    animateBars = true
                }
            }
        }
    }

    // MARK: - 1. 上下文容量 + 来源分解 + 平均缓存命中率

    private var contextSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("当前会话上下文")
            GlassCard(padding: 18, cornerRadius: 22, strong: true) {
                if let usage = model.contextUsageSnapshot {
                    let pct = Int(round(usage.ratio * 100))
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("上下文容量")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Text("\(formatCNTokens(usage.usedTokens))/\(formatCNTokens(usage.maxTokens)) (\(pct)%)")
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundStyle(Theme.textSecondary)
                                .monospacedDigit()
                        }

                        progressBar(
                            animateBars ? usage.ratio : 0,
                            colors: usage.ratio > 0.85 ? [Theme.coral, Theme.amber] : [Theme.azure, Color(red: 0.28, green: 0.62, blue: 1.0)]
                        )

                        if !usage.breakdown.isEmpty {
                            VStack(spacing: 9) {
                                ForEach(Array(usage.breakdown.enumerated()), id: \.element.id) { index, item in
                                    HStack(spacing: 10) {
                                        Circle()
                                            .fill(breakdownDotColor(index: index))
                                            .frame(width: 8, height: 8)
                                        Text(item.label)
                                            .font(.system(size: 14))
                                            .foregroundStyle(Theme.textSecondary)
                                        Spacer()
                                        Text(formatBreakdownPercent(item.percent))
                                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                                            .foregroundStyle(Theme.textPrimary)
                                            .monospacedDigit()
                                    }
                                }
                            }
                            .padding(.top, 2)
                        }

                        if let hitRate = usage.cacheHitRate {
                            Rectangle().fill(Theme.hairline).frame(height: 0.6)
                            HStack {
                                Text("平均缓存命中率")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Theme.textSecondary)
                                Spacer()
                                Text(String(format: "%.1f%%", hitRate * 100))
                                    .font(.system(size: 14.5, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Theme.textPrimary)
                                    .monospacedDigit()
                            }
                        }
                    }
                } else {
                    HStack(spacing: 12) {
                        Image(systemName: "text.alignleft")
                            .font(.system(size: 18))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(Theme.cardFill))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("暂无会话上下文数据")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text("打开任意会话后，此处将实时显示上下文容量、来源占比与平均缓存命中率。")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 2. 剩余额度(5 小时 / 每周 / ZCode MCP + 重置额度)

    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("套餐剩余额度")
            GlassCard(padding: 18, cornerRadius: 22, strong: true) {
                if let report = model.usageReport, !report.quotaWindows.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 8) {
                            Text("剩余额度")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .fixedSize()

                            if let reset = report.resetStatus, reset.totalCount > 0 {
                                HStack(spacing: 4) {
                                    Image(systemName: "gift.fill")
                                        .font(.system(size: 10.5))
                                    Text("获得\(reset.totalCount)次重置额度")
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .lineLimit(1)
                                }
                                .fixedSize()
                                .foregroundStyle(Theme.mint)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Theme.mint.opacity(0.14)))
                            }

                            Spacer(minLength: 4)
                        }

                        let columns = Array(
                            repeating: GridItem(.flexible(), spacing: 10),
                            count: min(max(report.quotaWindows.count, 1), 3)
                        )
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(report.quotaWindows) { window in
                                quotaWindowCard(window)
                            }
                        }

                        if report.planName != nil || report.providerDisplayName != nil || report.planExpireAt != nil {
                            Rectangle().fill(Theme.hairline).frame(height: 0.6)
                            HStack(spacing: 8) {
                                if let planName = report.planName {
                                    PillBadge(text: planName, tint: Theme.azure)
                                } else if let providerName = report.providerDisplayName {
                                    Text(providerName)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(Theme.textTertiary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if let exp = report.planExpireAt {
                                    Text("\(formatMonthDay(exp)) 到期")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(Theme.textTertiary)
                                }
                            }
                        }
                    }
                } else if let report = model.usageReport,
                          (report.limit ?? 0) > 0 || report.planName != nil {
                    legacyBillingQuota(report)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            if model.isRefreshingUsage {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "crown")
                                    .font(.system(size: 15))
                                    .foregroundStyle(Theme.amber)
                            }
                            Text(model.isRefreshingUsage ? "正在同步套餐配额…" : "暂未获取到套餐剩余额度")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                        }
                        Text(unavailableHint)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func quotaWindowCard(_ window: UsageChannel.QuotaWindow) -> some View {
        let accent = accentColor(for: window.accentKey)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 4) {
                Text(window.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if window.hasResetOpportunity {
                    Text("重置")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Theme.mint)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Theme.mint.opacity(0.15)))
                        .fixedSize()
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(formatQuotaPercent(window.remainingPercent))
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                if let resetDate = window.nextResetTime {
                    Text(formatResetTime(resetDate, style: window.resetTimeStyle))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.cardFill)
                    Capsule()
                        .fill(accent)
                        .frame(width: max(6, geo.size.width * (animateBars ? window.remainingPercent / 100.0 : 0)))
                }
            }
            .frame(height: 6)
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.6)
        )
    }

    private func legacyBillingQuota(_ report: UsageChannel.UsageReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let planName = report.planName ?? (report.raw["_plan_name"] as? String) {
                HStack(spacing: 6) {
                    Image(systemName: "crown.fill").font(.system(size: 12)).foregroundStyle(Theme.amber)
                    Text(planName).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                }
            }
            if let used = report.used, let limit = report.limit, limit > 0 {
                let ratio = used / limit
                HStack(alignment: .firstTextBaseline) {
                    Text("\(formatCNTokens(Int(used))) / \(formatCNTokens(Int(limit)))")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(String(format: "%.0f%%", ratio * 100))
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(Theme.mint)
                }
                progressBar(animateBars ? ratio : 0, colors: [Theme.azure, Theme.mint])
            } else if let limit = report.limit, limit > 0 {
                Text("额度 \(formatCNTokens(Int(limit)))")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
            }
            if let resetAt = report.resetAt {
                Text("下次重置：\(resetAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var unavailableHint: String {
        switch model.usageReport?.unavailableReason {
        case "no_plan":
            return "当前账号暂无有效编程套餐（Coding Plan）。"
        case "not_configured":
            return "桌面端尚未配置 Z.ai / BigModel 编程套餐凭证。"
        default:
            return "请确认桌面端 ZCode 已连接并登录编程套餐账号，可点击左上角刷新重试。"
        }
    }

    // MARK: - 3. 使用统计(7天 / 30天 / 累计)

    private var usageStatsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("使用统计")
                Spacer()
                HStack(spacing: 4) {
                    ForEach(ranges, id: \.id) { item in
                        let active = model.usageRange == item.id
                        Button {
                            Haptics.selection()
                            withAnimation(Motion.snappy) {
                                model.refreshUsage(range: item.id)
                            }
                        } label: {
                            Text(item.label)
                                .font(.system(size: 11.5, weight: active ? .semibold : .medium))
                                .foregroundStyle(active ? Theme.onAccent : Theme.textSecondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule().fill(active ? Theme.accentFill : Theme.cardFill)
                                )
                        }
                        .buttonStyle(bouncy(scale: 0.95))
                    }
                }
            }

            GlassCard(padding: 16, cornerRadius: 22, strong: true) {
                if let stats = model.usageReport?.appUsage {
                    VStack(alignment: .leading, spacing: 16) {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                            statTile(
                                title: "累计 Token",
                                value: formatCNTokens(stats.totalTokens),
                                icon: "sparkles",
                                tint: Theme.azure
                            )
                            statTile(
                                title: "单日峰值",
                                value: formatCNTokens(stats.peakDailyTokens),
                                subtitle: stats.peakDailyDate,
                                icon: "flame.fill",
                                tint: Theme.amber
                            )
                            statTile(
                                title: "连续活跃",
                                value: "\(stats.currentStreakDays) 天",
                                subtitle: stats.longestStreakDays > 0 ? "最长 \(stats.longestStreakDays) 天" : nil,
                                icon: "calendar.badge.checkmark",
                                tint: Theme.mint
                            )
                            if stats.totalUsageDurationMs > 0 || stats.longestSessionMs > 0 {
                                statTile(
                                    title: stats.totalUsageDurationMs > 0 ? "累计使用时长" : "最长单次会话",
                                    value: formatDuration(ms: stats.totalUsageDurationMs > 0 ? stats.totalUsageDurationMs : stats.longestSessionMs),
                                    icon: "clock.fill",
                                    tint: Theme.indigo
                                )
                            } else if let sessions = stats.sessionCount {
                                statTile(
                                    title: "会话数量",
                                    value: "\(sessions)",
                                    subtitle: stats.messageCount.map { "\($0) 条消息" },
                                    icon: "bubble.left.and.bubble.right.fill",
                                    tint: Theme.indigo
                                )
                            }
                        }

                        if stats.favoriteModelName != nil || stats.cacheHitRate != nil || stats.totalCredits != nil {
                            HStack(spacing: 8) {
                                if let fav = stats.favoriteModelName {
                                    miniPill(icon: "cpu", text: "常用 \(fav)", tint: Theme.azure)
                                }
                                if let hit = stats.cacheHitRate {
                                    miniPill(icon: "bolt.fill", text: "缓存 \(String(format: "%.1f%%", hit * 100))", tint: Theme.mint)
                                }
                                if let credits = stats.totalCredits, credits > 0 {
                                    miniPill(icon: "star.fill", text: "积分 \(Int(credits))", tint: Theme.amber)
                                }
                                Spacer(minLength: 0)
                            }
                        }

                        if !stats.dailySeries.isEmpty {
                            dailyBarChart(Array(stats.dailySeries.suffix(10)))
                        }
                    }
                } else {
                    HStack(spacing: 12) {
                        Image(systemName: "chart.xyaxis.line")
                            .font(.system(size: 18))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(Theme.cardFill))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.isRefreshingUsage ? "正在加载使用统计…" : "暂无周期使用统计")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text("连接桌面端后将自动拉取最近 7 天 / 30 天 / 累计 Token 活动与活跃度。")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
            }
        }
    }

    private func statTile(title: String, value: String, subtitle: String? = nil, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.6))
    }

    private func dailyBarChart(_ points: [UsageChannel.DailyUsagePoint]) -> some View {
        let maxTokens = max(1, points.map(\.tokens).max() ?? 1)
        return VStack(alignment: .leading, spacing: 8) {
            Text("近期每日 Token 趋势")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)

            HStack(alignment: .bottom, spacing: 6) {
                ForEach(points) { pt in
                    let heightRatio = CGFloat(pt.tokens) / CGFloat(maxTokens)
                    let isPeak = pt.tokens == maxTokens && pt.tokens > 0
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: isPeak ? [Theme.amber, Theme.azure] : [Theme.azure, Theme.indigo.opacity(0.75)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(height: max(5, 58 * (animateBars ? heightRatio : 0)))
                        Text(String(pt.date.suffix(2)))
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(isPeak ? Theme.textPrimary : Theme.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 76, alignment: .bottom)
        }
        .padding(.top, 4)
    }

    // MARK: - 4. 原始数据

    private func rawSection(_ report: UsageChannel.UsageReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                Haptics.selection()
                withAnimation(Motion.smooth) { showRaw.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("原始接口数据")
                        .font(.system(size: 12.5, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9.5, weight: .bold))
                        .rotationEffect(.degrees(showRaw ? 180 : 0))
                }
                .foregroundStyle(Theme.textTertiary)
                .padding(.leading, 4)
            }
            .buttonStyle(.plain)

            if showRaw,
               let data = try? JSONSerialization.data(withJSONObject: report.raw, options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(report.provider)
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                        Spacer()
                        Button {
                            UIPasteboard.general.string = text
                            Haptics.success()
                            withAnimation(Motion.bouncy) { copiedRaw = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                                withAnimation(Motion.snappy) { copiedRaw = false }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: copiedRaw ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 10))
                                Text(copiedRaw ? "已复制" : "复制")
                                    .font(.system(size: 10.5, weight: .semibold))
                            }
                            .foregroundStyle(copiedRaw ? Theme.mint : Theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                    Text(text)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frostedSurface(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - 视觉与格式化助手

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Theme.textTertiary)
            .padding(.leading, 4)
    }

    private func progressBar(_ fraction: Double, colors: [Color]) -> some View {
        let clamped = min(1, max(0, fraction))
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.cardFill)
                Capsule()
                    .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(8, geo.size.width * clamped))
            }
        }
        .frame(height: 8)
    }

    private func miniPill(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(tint.opacity(0.11)))
    }

    private func breakdownDotColor(index: Int) -> Color {
        let palette: [Color] = [
            Theme.azure,
            Color(red: 0.29, green: 0.57, blue: 0.96),
            Color(red: 0.44, green: 0.67, blue: 0.96),
            Color(red: 0.58, green: 0.76, blue: 0.96),
            Color(red: 0.68, green: 0.82, blue: 0.96),
            Color(red: 0.76, green: 0.87, blue: 0.96),
        ]
        return palette[min(index, palette.count - 1)]
    }

    private func accentColor(for key: String) -> Color {
        switch key {
        case "green": return Theme.mint
        case "orange": return Theme.amber
        case "purple": return Theme.indigo
        default: return Theme.azure
        }
    }

    private func formatCNTokens(_ n: Int) -> String {
        if n >= 100_000_000 {
            return String(format: "%.1f亿", Double(n) / 100_000_000)
        }
        if n >= 10_000 {
            let wan = Double(n) / 10_000
            return wan >= 100 || abs(wan.rounded() - wan) < 0.05
                ? String(format: "%.0f万", wan)
                : String(format: "%.1f万", wan)
        }
        if n >= 1_000 {
            return String(format: "%.1fK", Double(n) / 1_000)
        }
        return "\(n)"
    }

    private func formatBreakdownPercent(_ ratio: Double) -> String {
        let pct = max(0, ratio * 100)
        if pct < 0.05 { return "0%" }
        return String(format: "%.1f%%", pct)
    }

    private func formatQuotaPercent(_ pct: Double) -> String {
        let clamped = min(100, max(0, pct))
        if clamped >= 10 || abs(clamped.rounded() - clamped) < 0.05 {
            return String(format: "%.0f%%", clamped)
        }
        return String(format: "%.1f%%", clamped)
    }

    private func formatResetTime(_ date: Date, style: String) -> String {
        if style == "dateTime", Calendar.current.isDateInToday(date) {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            return f.string(from: date)
        }
        return formatMonthDay(date)
    }

    private func formatMonthDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        return f.string(from: date)
    }

    private func formatDuration(ms: Int) -> String {
        let totalMin = max(0, ms / 60_000)
        let days = totalMin / 1440
        let hours = (totalMin % 1440) / 60
        let mins = totalMin % 60
        if days > 0 { return "\(days)天\(hours)时" }
        if hours > 0 { return "\(hours)时\(mins)分" }
        return "\(mins)分钟"
    }
}
