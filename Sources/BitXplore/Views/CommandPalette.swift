import SwiftUI

/// 命令面板（⌘⌥P / Vim `:`）：粘贴/输入路径回车前往；`/名称[/范围][/类型]` 在当前目录下搜索（语法见 FileSearch）；
/// `%s/路径/目标/替换` 批量替换文件中的文字（语法见 TextReplace），先预览，回车执行
struct CommandPalette: View {
    @Binding var isPresented: Bool
    /// 相对路径与文件搜索的基准目录（活动栏当前目录）
    let currentURL: URL
    /// 打开时预填的内容（`/` 直接进入文件搜索）
    var initialText = ""
    let onOpen: (URL) -> Void

    /// 输入框内容带语法高亮（TextField 不能给文字着色，故用 TextEditor）；`text` 是其纯文本，每次改字后同步并重新着色
    @State private var rich = AttributedString()
    @State private var selection = AttributedTextSelection()
    @State private var text = ""
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @State private var matches: [URL] = []
    @State private var highlighted = 0
    @State private var searching = false
    /// 批量替换：预览（或执行后）的结果、执行出错信息、是否已执行
    @State private var changes: [TextReplace.Change] = []
    @State private var replaceIssue: String?
    @State private var replaced = false

    private nonisolated static let maxMatches = 50

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var resolved: URL? { FileSystemService.resolve(text, relativeTo: currentURL) }
    /// `/` 开头为文件搜索，返回解析结果；否则 nil。
    /// 含第二个 `/` 且确有其路径时按路径前往（粘贴的绝对路径照常可用），`/Users` 这种单段仍是搜索
    private var query: Result<FileSearch, FileSearch.ParseError>? { Self.searchQuery(text, base: currentURL) }
    nonisolated static func searchQuery(_ text: String, base: URL) -> Result<FileSearch, FileSearch.ParseError>? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let rest = trimmed.dropFirst()
        if rest.contains("/"), FileSystemService.resolve(trimmed, relativeTo: base) != nil { return nil }
        return FileSearch.parse(rest)
    }

    /// `$(…)` 内嵌命令的结果：文件搜索取全部匹配，路径取其本身
    nonisolated static func files(for command: String, base: URL) throws(TextReplace.ParseError) -> [URL] {
        switch searchQuery(command, base: base) {
        case .success(let search)?:
            return search.find(in: base, limit: .max)
        case .failure(let error)?:
            throw .invalid(error.message)
        case nil:
            guard let url = FileSystemService.resolve(command, relativeTo: base) else { throw .invalid("找不到「\(command)」") }
            return [url]
        }
    }

    /// `%s/` 开头为批量替换；只去掉开头空白，替换文本末尾的空格要保留
    private var replace: Result<TextReplace, TextReplace.ParseError>? {
        let input = text.drop { $0.isWhitespace }
        guard input.hasPrefix("%s/") else { return nil }
        return TextReplace.parse(input.dropFirst(3))
    }
    private var replaceOp: TextReplace? { try? replace?.get() }

    /// 可执行的搜索（解析成功且有名称或选项）
    private var search: FileSearch? {
        guard case .success(let search)? = query, search != FileSearch(parts: [""]) else { return nil }
        return search
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: replace != nil ? "arrow.left.arrow.right" : query == nil ? "command" : "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextEditor(text: $rich, selection: $selection)
                    .textEditorStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .scrollDisabled(true)
                    .fixedSize(horizontal: false, vertical: true)
                    .font(.title3)
                    .focused($focused)
                    .overlay(alignment: .leading) {
                        if text.isEmpty {
                            Text("粘贴路径，输入 / 搜索文件，%s/ 批量替换")
                                .font(.title3)
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                    .onKeyPress(.return) {
                        submit()
                        return .handled
                    }
                    .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                        guard search != nil, !matches.isEmpty else { return .ignored }
                        let delta = press.key == .downArrow ? 1 : -1
                        highlighted = min(max(highlighted + delta, 0), matches.count - 1)
                        return .handled
                    }
            }
            .padding(14)

            // 空输入时只显示输入框
            if !trimmed.isEmpty {
                Divider()

                if search != nil, !matches.isEmpty {
                    results
                } else if replaceOp != nil, !changes.isEmpty {
                    changeList
                } else {
                    hint
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(width: 560)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 20, y: 8)
        .onAppear {
            rich = AttributedString(initialText)
            selection = AttributedTextSelection(insertionPoint: rich.endIndex)
            focused = true
        }
        .onChange(of: rich) { restyle() }
        // 颜色写在文字属性里，不会随外观自动变：切换亮 / 暗色时重新着色
        .onChange(of: colorScheme) { restyle(force: true) }
        .onExitCommand { isPresented = false }
        .task(id: search) { await runSearch() }
        .task(id: replaceOp) { await runPreview() }
    }

    /// 只保留单行（粘贴的换行去掉），并按 CommandSyntax 重新着色；只改属性不改文字时直接返回，避免循环
    private func restyle(force: Bool = false) {
        var plain = String(rich.characters)
        let pasted = plain.contains(where: \.isNewline)
        if pasted {
            plain.removeAll(where: \.isNewline)
            rich = AttributedString(plain)
            selection = AttributedTextSelection(insertionPoint: rich.endIndex)
        }
        guard force || pasted || plain != text else { return }
        text = plain
        let base = currentURL
        let tokens = CommandSyntax.tokens(plain) { FileSystemService.resolve($0, relativeTo: base) != nil }
        let dark = colorScheme == .dark
        rich.transform(updating: &selection) { rich in
            // 未着色的文字也显式给色：TextEditor 在玻璃底上不会按外观解析默认色，暗色下会发黑
            rich.foregroundColor = dark ? Color(white: 0.94) : Color(white: 0.1)
            for token in tokens {
                let start = rich.characters.index(rich.startIndex, offsetBy: token.range.lowerBound)
                let end = rich.characters.index(start, offsetBy: token.range.count)
                rich[start..<end].foregroundColor = Self.color(token.kind, dark: dark)
            }
        }
    }

    /// 两套配色：亮色用深而饱和的色，在浅色玻璃上够对比；暗色用提亮的浅色，避免系统色在深底上发闷
    private static func color(_ kind: CommandSyntax.Kind, dark: Bool) -> Color {
        let (light, night): ((Double, Double, Double), (Double, Double, Double)) = switch kind {
        case .keyword: ((0.55, 0.16, 0.72), (0.84, 0.62, 1.00))
        case .separator: ((0.45, 0.45, 0.48), (0.62, 0.62, 0.66))
        case .variable: ((0.76, 0.36, 0.00), (1.00, 0.70, 0.36))
        case .escape: ((0.00, 0.50, 0.56), (0.40, 0.86, 0.86))
        case .wildcard: ((0.08, 0.36, 0.86), (0.46, 0.70, 1.00))
        case .argument: ((0.13, 0.50, 0.16), (0.58, 0.88, 0.50))
        case .error: ((0.82, 0.10, 0.12), (1.00, 0.45, 0.45))
        }
        let (r, g, b) = dark ? night : light
        return Color(red: r, green: g, blue: b)
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(matches.enumerated()), id: \.element) { index, url in
                        resultRow(url, isHighlighted: index == highlighted)
                            .id(url)
                            .onTapGesture {
                                highlighted = index
                                submit()
                            }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 320)
            .onChange(of: highlighted) {
                if matches.indices.contains(highlighted) { proxy.scrollTo(matches[highlighted]) }
            }
        }
    }

    private var changeList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(changes, id: \.url) { change in
                        resultRow(change.url, isHighlighted: false, detail: change.failed ? "写入失败" : "\(change.count) 处")
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 280)
            Divider()
            Text(replaceSummary)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
    }

    private var replaceSummary: String {
        let total = changes.reduce(0) { $0 + $1.count }
        let failed = changes.count { $0.failed }
        if !replaced { return searching ? "正在替换…" : "回车在 \(changes.count) 个文件中替换 \(total) 处" }
        return failed == 0
            ? "已在 \(changes.count) 个文件中替换 \(total) 处，回车关闭"
            : "\(failed) 个文件写入失败，其余已替换，回车关闭"
    }

    private func resultRow(_ url: URL, isHighlighted: Bool, detail: String? = nil) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent)
                    .lineLimit(1)
                Text(relativePath(url))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHighlighted ? Color.accentColor.opacity(0.25) : .clear, in: .rect(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    /// 结果所在目录，相对当前目录显示
    private func relativePath(_ url: URL) -> String {
        let parent = url.deletingLastPathComponent().path
        let base = currentURL.standardizedFileURL.path
        guard parent.hasPrefix(base) else { return parent }
        let rest = parent.dropFirst(base.count).drop { $0 == "/" }
        return rest.isEmpty ? "当前目录" : String(rest)
    }

    @ViewBuilder
    private var hint: some View {
        if let replace {
            switch replace {
            case .failure(.incomplete):
                VStack(alignment: .leading, spacing: 4) {
                    Text("%s/路径/目标/替换，目标按字面、区分大小写匹配")
                    Text("路径：文件路径，或 $(命令) 取另一条命令的结果，如 $(/*.md/f) · 变量：$FILENAME 当前文件名，$DATETIME(yy/mm/dd) 日期（单个 y/m/d 为 05/9/1）· \\/ \\$ 表示字面字符")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            case .failure(let error):
                Label(error.message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.secondary)
            case .success:
                if let replaceIssue {
                    Label(replaceIssue, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.secondary)
                } else {
                    Text(searching ? "正在查找…" : "没有可替换的内容")
                        .foregroundStyle(.secondary)
                }
            }
        } else if let query {
            switch query {
            case .failure(let error):
                Label(error.message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.secondary)
            case .success where search == nil:
                VStack(alignment: .leading, spacing: 4) {
                    Text("/名称/范围/类型，范围与类型可省略")
                    Text("名称：* 为通配（如 *.md），\\* 表示星号 · 范围：g 全部层级（默认），d:2 最多 2 层 · 类型：f 文件，d 文件夹")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            case .success:
                Text(searching ? "正在搜索…" : "没有找到匹配的项目")
                    .foregroundStyle(.secondary)
            }
        } else if let url = resolved {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("前往「\(url.path == "/" ? "Macintosh HD" : url.lastPathComponent)」")
                    Text(url.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } icon: {
                Image(systemName: "arrow.right.circle.fill")
                    .foregroundStyle(.tint)
            }
        } else {
            Text("没有匹配的路径或指令")
                .foregroundStyle(.secondary)
        }
    }

    /// 输入变化即取消上一轮；停顿 150ms 后在后台遍历
    private func runSearch() async {
        highlighted = 0
        guard let search else {
            matches = []
            return
        }
        searching = true
        defer { searching = false }
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        let base = currentURL
        let worker = Task.detached(priority: .userInitiated) {
            search.find(in: base, limit: Self.maxMatches)
        }
        let found = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled else { return }
        matches = found
    }

    /// 预览：输入停顿 250ms 后在后台找出要改的文件，不写入
    private func runPreview() async {
        changes = []
        replaceIssue = nil
        replaced = false
        guard let op = replaceOp else { return }
        searching = true
        defer { searching = false }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        let worker = performReplace(op, write: false)
        let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled else { return }
        show(result)
    }

    private func performReplace(_ op: TextReplace, write: Bool) -> Task<Result<[TextReplace.Change], TextReplace.ParseError>, Never> {
        let base = currentURL
        return Task.detached(priority: .userInitiated) {
            Result { () throws(TextReplace.ParseError) in
                try op.run(write: write, command: { cmd throws(TextReplace.ParseError) in try Self.files(for: cmd, base: base) },
                           resolve: { FileSystemService.resolve($0, relativeTo: base) })
            }
        }
    }

    private func show(_ result: Result<[TextReplace.Change], TextReplace.ParseError>) {
        switch result {
        case .success(let found): changes = found
        case .failure(let error): replaceIssue = error.message
        }
    }

    private func submit() {
        if replace != nil {
            if replaced {
                isPresented = false
                return
            }
            guard let op = replaceOp, !changes.isEmpty, !searching else {
                NSSound.beep()
                return
            }
            searching = true
            Task {
                let result = await performReplace(op, write: true).value
                searching = false
                replaced = true
                show(result)
            }
            return
        }
        if query != nil {
            guard search != nil, matches.indices.contains(highlighted) else {
                NSSound.beep()
                return
            }
            isPresented = false
            onOpen(matches[highlighted])
            return
        }
        guard let url = resolved else {
            NSSound.beep()
            return
        }
        isPresented = false
        onOpen(url)
    }
}
