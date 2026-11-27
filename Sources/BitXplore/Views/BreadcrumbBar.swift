import SwiftUI
import AppKit

/// 底部路径栏（原生 AppKit NSPathControl + 行内路径编辑）
struct BreadcrumbBar: View {
    @Binding var currentURL: URL
    @Binding var isEditingPath: Bool
    let onNavigate: (URL) -> Void

    @State private var editPath = ""
    @State private var pathNotFound = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if isEditingPath {
                editBar
            } else {
                pathBar
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .onChange(of: currentURL) {
            if isEditingPath {
                cancelEdit()
            }
        }
    }

    // MARK: - 浏览态（原生 NSPathControl）

    private var pathBar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 0) {
                NativePathControl(
                    url: currentURL,
                    onNavigate: { url in
                        if url.standardizedFileURL.path != currentURL.standardizedFileURL.path {
                            onNavigate(url)
                        }
                    },
                    onStartEdit: {
                        isEditingPath = true
                    }
                )
                .layoutPriority(1)

                Color.clear
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .frame(height: 20)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        isEditingPath = true
                    }
            }

            Button {
                isEditingPath = true
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("前往路径 (⌘⇧G)")
            .layoutPriority(2)
        }
    }

    // MARK: - 编辑态（行内路径输入）

    private var editBar: some View {
        HStack(spacing: 6) {
            TextField("输入路径（支持 ~ 和相对路径）", text: $editPath)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .focused($isFocused)
                .onSubmit { commitEdit() }
                .onExitCommand { cancelEdit() }
                .onChange(of: editPath) {
                    if pathNotFound {
                        pathNotFound = false
                    }
                }
                .task {
                    editPath = currentURL.path
                    pathNotFound = false
                    isFocused = true
                    try? await Task.sleep(for: .milliseconds(50))
                    guard !Task.isCancelled, isFocused else { return }
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                }

            if pathNotFound {
                Text("路径不存在")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button {
                cancelEdit()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("取消 (Esc)")
        }
        .onExitCommand { cancelEdit() }
    }

    private func commitEdit() {
        let raw = editPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            cancelEdit()
            return
        }

        let expanded = (raw as NSString).expandingTildeInPath
        let resolvedURL: URL
        if expanded.hasPrefix("/") {
            resolvedURL = URL(fileURLWithPath: expanded).standardizedFileURL
        } else {
            resolvedURL = URL(fileURLWithPath: expanded, relativeTo: currentURL).standardizedFileURL
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedURL.path, isDirectory: &isDir) else {
            pathNotFound = true
            NSSound.beep()
            return
        }

        let destination = isDir.boolValue ? resolvedURL : resolvedURL.deletingLastPathComponent()
        if destination.standardizedFileURL.path != currentURL.standardizedFileURL.path {
            onNavigate(destination)
        }
        cancelEdit()
    }

    private func cancelEdit() {
        isEditingPath = false
        isFocused = false
        pathNotFound = false
        editPath = ""
    }
}

// MARK: - 原生 AppKit NSPathControl 封装

private struct NativePathControl: NSViewRepresentable {
    let url: URL
    let onNavigate: (URL) -> Void
    let onStartEdit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(currentURL: url, onNavigate: onNavigate, onStartEdit: onStartEdit)
    }

    func makeNSView(context: Context) -> NSPathControl {
        let control = NSPathControl()
        control.pathStyle = .standard
        control.isEditable = false
        control.controlSize = .small
        control.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        control.backgroundColor = .clear
        control.focusRingType = .none
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        control.url = url
        control.target = context.coordinator
        control.action = #selector(Coordinator.pathItemClicked(_:))
        control.doubleAction = #selector(Coordinator.pathDoubleClicked(_:))
        return control
    }

    func updateNSView(_ nsView: NSPathControl, context: Context) {
        context.coordinator.currentURL = url
        context.coordinator.onNavigate = onNavigate
        context.coordinator.onStartEdit = onStartEdit

        if nsView.url?.standardizedFileURL.path != url.standardizedFileURL.path {
            nsView.url = url
            nsView.invalidateIntrinsicContentSize()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPathControl, context: Context) -> CGSize? {
        let intrinsic = nsView.intrinsicContentSize
        let height = intrinsic.height > 0 ? intrinsic.height : 20
        guard let proposedWidth = proposal.width, proposedWidth.isFinite else {
            return intrinsic.width > 0 ? CGSize(width: intrinsic.width, height: height) : nil
        }
        let width = intrinsic.width > 0 ? min(intrinsic.width, proposedWidth) : proposedWidth
        return CGSize(width: max(0, width), height: height)
    }

    @MainActor
    final class Coordinator: NSObject {
        var currentURL: URL
        var onNavigate: (URL) -> Void
        var onStartEdit: () -> Void

        init(
            currentURL: URL,
            onNavigate: @escaping (URL) -> Void,
            onStartEdit: @escaping () -> Void
        ) {
            self.currentURL = currentURL
            self.onNavigate = onNavigate
            self.onStartEdit = onStartEdit
        }

        @objc func pathItemClicked(_ sender: NSPathControl) {
            guard let clickedURL = sender.clickedPathItem?.url else { return }
            if clickedURL.standardizedFileURL.path != currentURL.standardizedFileURL.path {
                onNavigate(clickedURL)
            }
        }

        @objc func pathDoubleClicked(_ sender: NSPathControl) {
            guard let clickedURL = sender.clickedPathItem?.url else {
                onStartEdit()
                return
            }
            if clickedURL.standardizedFileURL.path == currentURL.standardizedFileURL.path {
                onStartEdit()
            }
        }
    }
}
