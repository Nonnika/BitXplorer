import SwiftUI

/// 命令面板（⌘⌥P）：粘贴/输入路径回车前往。指令暂未实现，输入框已预留
struct CommandPalette: View {
    @Binding var isPresented: Bool
    /// 相对路径的基准目录（活动栏当前目录）
    let currentURL: URL
    let onOpen: (URL) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var resolved: URL? { FileSystemService.resolve(text, relativeTo: currentURL) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "command")
                    .foregroundStyle(.secondary)
                TextField("粘贴路径或输入指令", text: $text)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit(submit)
            }
            .padding(14)

            // 空输入时只显示输入框
            if !trimmed.isEmpty {
                Divider()

                hint
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 560)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 20, y: 8)
        .onAppear { focused = true }
        .onExitCommand { isPresented = false }
    }

    @ViewBuilder
    private var hint: some View {
        if let url = resolved {
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

    private func submit() {
        guard let url = resolved else {
            NSSound.beep()
            return
        }
        isPresented = false
        onOpen(url)
    }
}
