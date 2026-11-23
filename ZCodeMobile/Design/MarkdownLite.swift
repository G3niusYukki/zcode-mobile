import SwiftUI

/// 轻量 Markdown 渲染:分级标题/引用块/分割线/编号列表/要点/可复制代码块/行内代码/粗斜体。
/// 不引入第三方依赖,支持全局字体缩放与流畅流式呼吸点。
struct MarkdownLiteText: View {
    let markdown: String
    var streaming: Bool = false
    @AppStorage("zcode-mobile.fontScale") private var fontScale: Double = 1.0

    private var baseSize: CGFloat { 15 * CGFloat(fontScale) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .codeBlock(let code, let lang):
                    CodeBlockView(code: code, lang: lang, fontScale: fontScale)
                case .heading(let level, let text):
                    Text(inline(text))
                        .font(.system(size: headingSize(level), weight: level <= 2 ? .bold : .semibold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.top, level == 1 ? 4 : 2)
                case .blockquote(let text):
                    HStack(alignment: .top, spacing: 10) {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [Theme.azure, Theme.indigo],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: 3)
                        Text(inline(text))
                            .font(.system(size: baseSize * 0.94))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frostedSurface(in: RoundedRectangle(cornerRadius: 12, style: .continuous), shadowRadius: 4)
                case .divider:
                    Rectangle()
                        .fill(Theme.hairline)
                        .frame(height: 0.8)
                        .padding(.vertical, 4)
                case .numbered(let n, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(n).")
                            .font(.system(size: baseSize, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.azure)
                            .monospacedDigit()
                            .frame(minWidth: 22, alignment: .trailing)
                        Text(inline(text))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Circle()
                            .fill(Theme.azure.opacity(0.75))
                            .frame(width: 5, height: 5)
                            .offset(y: -2)
                        Text(inline(text))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .paragraph(let text):
                    Text(inline(text))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if streaming {
                StreamingDotsView()
                    .padding(.top, 2)
            }
        }
        .font(.system(size: baseSize))
        .lineSpacing(3.5)
        .textSelection(.enabled)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 19.5 * CGFloat(fontScale)
        case 2: return 17.5 * CGFloat(fontScale)
        default: return 16 * CGFloat(fontScale)
        }
    }

    // MARK: - 行内解析: `code`、**bold**、*italic*

    private func inline(_ text: String) -> AttributedString {
        var out = AttributedString()
        var i = text.startIndex
        var buffer = ""

        func flushBuffer() {
            if !buffer.isEmpty {
                out += AttributedString(buffer)
                buffer = ""
            }
        }

        while i < text.endIndex {
            let rest = text[i...]
            if rest.hasPrefix("`") {
                if let end = text[text.index(after: i)...].firstIndex(of: "`") {
                    flushBuffer()
                    let code = String(text[text.index(after: i)..<end])
                    var run = AttributedString(code)
                    run.font = .system(size: baseSize * 0.88, weight: .medium, design: .monospaced)
                    run.foregroundColor = Theme.azure
                    run.backgroundColor = Theme.azure.opacity(0.14)
                    out += run
                    i = text.index(after: end)
                    continue
                }
            }
            if rest.hasPrefix("**") {
                let start = text.index(i, offsetBy: 2)
                if start < text.endIndex, let range = text[start...].range(of: "**") {
                    flushBuffer()
                    let bold = String(text[start..<range.lowerBound])
                    var run = AttributedString(bold)
                    run.font = .system(size: baseSize, weight: .semibold)
                    out += run
                    i = range.upperBound
                    continue
                }
            }
            if rest.hasPrefix("*"), !rest.hasPrefix("**") {
                let start = text.index(after: i)
                if start < text.endIndex, let end = text[start...].firstIndex(of: "*"), end > start {
                    flushBuffer()
                    let italic = String(text[start..<end])
                    var run = AttributedString(italic)
                    run.font = .system(size: baseSize).italic()
                    out += run
                    i = text.index(after: end)
                    continue
                }
            }
            buffer.append(text[i])
            i = text.index(after: i)
        }
        flushBuffer()
        return out
    }

    // MARK: - 块级解析

    private enum Block {
        case paragraph(String)
        case numbered(Int, String)
        case bullet(String)
        case heading(Int, String)
        case blockquote(String)
        case divider
        case codeBlock(String, String?)
    }

    private final class BlocksBox: NSObject {
        let blocks: [Block]
        init(_ blocks: [Block]) { self.blocks = blocks }
    }

    private static let parseCache: NSCache<NSString, BlocksBox> = {
        let cache = NSCache<NSString, BlocksBox>()
        cache.countLimit = 220
        return cache
    }()

    private var blocks: [Block] {
        let key = "\(markdown.count)-\(markdown.hashValue)" as NSString
        if let cached = Self.parseCache.object(forKey: key) {
            return cached.blocks
        }
        let parsed = parseBlocks()
        Self.parseCache.setObject(BlocksBox(parsed), forKey: key)
        return parsed
    }

    private func parseBlocks() -> [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        let lines = markdown.components(separatedBy: "\n")
        var idx = 0

        func flushParagraph() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { result.append(.paragraph(text)) }
            paragraph = []
        }

        while idx < lines.count {
            let line = lines[idx]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushParagraph()
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                idx += 1
                while idx < lines.count, !lines[idx].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[idx])
                    idx += 1
                }
                result.append(.codeBlock(code.joined(separator: "\n"), lang.isEmpty ? nil : lang))
                idx += 1
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                idx += 1
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                result.append(.divider)
                idx += 1
                continue
            }

            if trimmed.hasPrefix("> ") {
                flushParagraph()
                var quotes: [String] = []
                while idx < lines.count {
                    let qLine = lines[idx].trimmingCharacters(in: .whitespaces)
                    if qLine.hasPrefix("> ") {
                        quotes.append(String(qLine.dropFirst(2)))
                        idx += 1
                    } else if qLine == ">" {
                        quotes.append("")
                        idx += 1
                    } else {
                        break
                    }
                }
                result.append(.blockquote(quotes.joined(separator: "\n")))
                continue
            }

            if trimmed.hasPrefix("### ") {
                flushParagraph()
                result.append(.heading(3, String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces)))
                idx += 1
                continue
            }
            if trimmed.hasPrefix("## ") {
                flushParagraph()
                result.append(.heading(2, String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)))
                idx += 1
                continue
            }
            if trimmed.hasPrefix("# ") {
                flushParagraph()
                result.append(.heading(1, String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
                idx += 1
                continue
            }

            // 数字列表 "12. xxx"
            if let dotRange = trimmed.range(of: ". "),
               trimmed[..<dotRange.lowerBound].allSatisfy(\.isNumber),
               trimmed.distance(from: trimmed.startIndex, to: dotRange.lowerBound) <= 2,
               let n = Int(trimmed[..<dotRange.lowerBound]) {
                flushParagraph()
                result.append(.numbered(n, String(trimmed[dotRange.upperBound...])))
                idx += 1
                continue
            }

            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushParagraph()
                result.append(.bullet(String(trimmed.dropFirst(2))))
                idx += 1
                continue
            }

            paragraph.append(trimmed)
            idx += 1
        }
        flushParagraph()
        return result
    }
}

/// 流畅流式输出三点波浪指示器
struct StreamingDotsView: View {
    @State private var active = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Theme.azure.opacity(0.85))
                    .frame(width: 5.5, height: 5.5)
                    .scaleEffect(active ? 1.15 : 0.55)
                    .opacity(active ? 1.0 : 0.35)
                    .animation(
                        .easeInOut(duration: 0.55)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.16),
                        value: active
                    )
            }
        }
        .onAppear { active = true }
    }
}

/// 毛玻璃代码块(带语言标签 + 一键复制按钮与触感反馈)
struct CodeBlockView: View {
    let code: String
    let lang: String?
    var fontScale: Double = 1.0
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.azure)
                    Text((lang ?? "CODE").uppercased())
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    Haptics.success()
                    withAnimation(Motion.bouncy) { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation(Motion.snappy) { copied = false }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .semibold))
                            .contentTransition(.symbolEffect(.replace))
                        Text(copied ? "已复制" : "复制")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .foregroundStyle(copied ? Theme.mint : Theme.textSecondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(copied ? Theme.mint.opacity(0.14) : Theme.cardFill))
                }
                .buttonStyle(bouncy(scale: 0.94))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.cardFill.opacity(0.6))

            Rectangle().fill(Theme.hairline).frame(height: 0.6)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 13 * CGFloat(fontScale), design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frostedSurface(in: RoundedRectangle(cornerRadius: 16, style: .continuous), strong: true, shadowRadius: 8)
    }
}
