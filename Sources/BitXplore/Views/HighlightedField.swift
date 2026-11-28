import SwiftUI

/// 带语法高亮的单行输入框（命令面板与「神奇重命名」共用）。
/// TextField 不能给文字着色，故用 TextEditor：回车交给 `onSubmit`，Tab 交给 `onTab`，粘贴进来的换行与制表符去掉
struct HighlightedField: View {
    @Binding var text: String
    let prompt: String
    var font: Font = .body
    var focus: FocusState<Bool>.Binding
    /// 把纯文本切成着色片段
    let tokens: (String) -> [CommandSyntax.Token]
    let onSubmit: () -> Void
    /// 有值时 Tab 不插入制表符，而是调用它（通常是把焦点移到另一个输入框）
    var onTab: (() -> Void)?

    @State private var rich = AttributedString()
    @State private var selection = AttributedTextSelection()
    /// 上次着色时的纯文本：只改属性不改文字时不再重算，避免 onChange 循环
    @State private var styled: String?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TextEditor(text: $rich, selection: $selection)
            .textEditorStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            .font(font)
            .focused(focus)
            .overlay(alignment: .leading) {
                if text.isEmpty {
                    Text(prompt)
                        .font(font)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .onKeyPress(.return) {
                onSubmit()
                return .handled
            }
            .onKeyPress(.tab) {
                guard let onTab else { return .ignored }
                onTab()
                return .handled
            }
            .onAppear {
                rich = AttributedString(text)
                selection = AttributedTextSelection(insertionPoint: rich.endIndex)
                restyle()
            }
            .onChange(of: rich) { restyle() }
            // 外部改了 text（如面板预填）时同步进来
            .onChange(of: text) {
                guard text != String(rich.characters) else { return }
                rich = AttributedString(text)
                selection = AttributedTextSelection(insertionPoint: rich.endIndex)
            }
            // 颜色写在文字属性里，不会随外观自动变：切换亮 / 暗色时重新着色
            .onChange(of: colorScheme) { restyle(force: true) }
    }

    private func restyle(force: Bool = false) {
        var plain = String(rich.characters)
        let pasted = plain.contains { $0.isNewline || $0 == "\t" }
        if pasted {
            plain.removeAll { $0.isNewline || $0 == "\t" }
            rich = AttributedString(plain)
            selection = AttributedTextSelection(insertionPoint: rich.endIndex)
        }
        guard force || pasted || plain != styled else { return }
        styled = plain
        if text != plain { text = plain }
        let tokens = tokens(plain)
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

    /// 两套配色：亮色用深而饱和的色，在浅色底上够对比；暗色用提亮的浅色，避免系统色在深底上发闷
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
}
