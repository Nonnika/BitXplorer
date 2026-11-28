import SwiftUI

/// 右键「神奇重命名」：把所选文件名中的文字替换掉，即命令面板 `%s` 的图形版（变量与规则见 TextReplace）
struct MagicRenameView: View {
    let urls: [URL]
    /// 改名后的新 URL，供列表刷新并选中
    let onDone: ([URL]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var target = ""
    @State private var replacement = ""
    @State private var now = Date.now
    @FocusState private var targetFocused: Bool
    @FocusState private var replacementFocused: Bool

    private var parsed: Result<TextReplace, TextReplace.ParseError> {
        TextReplace.parse(target: target, replacement: replacement)
    }

    var body: some View {
        // 所选文件数量有限，直接在渲染时同步算预览
        let changes = (try? parsed.get())?.rename(urls, now: now, write: false) ?? []
        let ready = changes.count { $0.problem == nil }

        VStack(alignment: .leading, spacing: 12) {
            Text("神奇重命名 \(urls.count) 个文件")
                .font(.headline)

            Grid(alignment: .leading, verticalSpacing: 8) {
                GridRow {
                    Text("查找")
                        .gridColumnAlignment(.trailing)
                    field($target, prompt: "如 IMG_*、$REGX(\\d+) 或 $FILENAME", isTarget: true, focus: $targetFocused) { replacementFocused = true }
                }
                GridRow {
                    Text("替换为")
                    field($replacement, prompt: "如 $DATETIME(yymmdd)-$FILENAME，$SUFFIX 为扩展名", isTarget: false, focus: $replacementFocused) {
                        targetFocused = true
                    }
                }
            }

            if case .failure(.invalid(let message)) = parsed, !target.isEmpty {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.secondary)
            }

            List(changes, id: \.url) { change in
                HStack(spacing: 6) {
                    Text(change.url.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                    Text(change.newName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let problem = change.problem {
                        Text(problem)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .frame(height: 200)
            .overlay {
                if changes.isEmpty {
                    Text(target.isEmpty ? "输入要查找的文字" : "所选文件名中没有要替换的文字")
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                if !changes.isEmpty {
                    let skipped = changes.count - ready
                    Text("将重命名 \(ready) 个文件" + (skipped == 0 ? "" : "，\(skipped) 个跳过"))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("重命名") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(ready == 0)
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear { targetFocused = true }
    }

    /// 带高亮的输入框，套一层圆角描边看起来像普通文本框；回车执行改名，Tab 切到另一个框
    private func field(_ text: Binding<String>, prompt: String, isTarget: Bool, focus: FocusState<Bool>.Binding,
                       onTab: @escaping () -> Void) -> some View {
        HighlightedField(text: text, prompt: prompt, focus: focus, tokens: { CommandSyntax.fieldTokens($0, isTarget: isTarget) },
                         onSubmit: apply, onTab: onTab)
            .padding(.vertical, 3)
            .padding(.horizontal, 2)
            .background(.background, in: .rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focus.wrappedValue ? Color.accentColor : Color.secondary.opacity(0.35)))
    }

    private func apply() {
        guard let op = try? parsed.get(), op.rename(urls, now: now, write: false).contains(where: { $0.problem == nil }) else {
            NSSound.beep()
            return
        }
        let done = op.rename(urls, now: now, write: true)
        // 预览后才出现的重名 / 改名失败：已跳过，提示一声
        if done.contains(where: { $0.problem != nil }) { NSSound.beep() }
        dismiss()
        onDone(done.filter { $0.problem == nil }.map { $0.url.deletingLastPathComponent().appendingPathComponent($0.newName) })
    }
}
