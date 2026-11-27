import SwiftUI
import AppKit

/// 文件列表：纯原生 SwiftUI Table，支持列排序、多选、右键菜单、键盘导航与行内重命名
struct FileListView: View {
    let files: [FileItem]
    let searchText: String
    @Binding var selectedURLs: Set<URL>
    @Binding var clipboardURLs: [URL]
    @Binding var clipboardIsCut: Bool
    @Binding var currentURL: URL
    @Binding var showHiddenFiles: Bool
    let onNavigate: (URL) -> Void
    let fsService: FileSystemService
    let onRefresh: () -> Void
    let newFolderTrigger: Int
    let renameTrigger: Int

    @State private var sortOrder: [FileSortComparator] = [FileSortComparator(.name)]
    @State private var isRenaming = false
    @State private var renameTarget: URL?
    @State private var renameText = ""
    @FocusState private var renameFieldFocused: Bool

    @State private var isCreatingFolder = false
    @State private var newFolderText = "新建文件夹"

    private var sortedFiles: [FileItem] {
        files.sorted(using: sortOrder)
    }

    var body: some View {
        let cutURLs: Set<URL> = clipboardIsCut ? Set(clipboardURLs) : []

        Table(sortedFiles, selection: $selectedURLs, sortOrder: $sortOrder) {
            TableColumn("名称", sortUsing: FileSortComparator(.name)) { item in
                HStack(spacing: 6) {
                    Image(nsImage: IconCache.icon(for: item.url))
                        .resizable()
                        .frame(width: 20, height: 20)

                    if isRenaming && renameTarget == item.url {
                        TextField("", text: $renameText)
                            .textFieldStyle(.plain)
                            .focused($renameFieldFocused)
                            .onSubmit { commitRename() }
                            .onExitCommand { cancelRename() }
                            .onAppear { renameFieldFocused = true }
                            .onChange(of: renameFieldFocused) { wasFocused, isFocused in
                                if wasFocused && !isFocused && isRenaming {
                                    commitRename()
                                }
                            }
                    } else {
                        Text(item.name)
                            .lineLimit(1)
                    }
                }
                .opacity(cutURLs.contains(item.url) ? 0.45 : 1.0)
            }
            .width(min: 140, ideal: 260)

            TableColumn("修改日期", sortUsing: FileSortComparator(.date)) { item in
                Text(item.formattedDate)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .opacity(cutURLs.contains(item.url) ? 0.45 : 1.0)
            }
            .width(min: 110, ideal: 150)

            TableColumn("类型", sortUsing: FileSortComparator(.kind)) { item in
                Text(item.fileTypeDisplay)
                    .foregroundStyle(.secondary)
                    .opacity(cutURLs.contains(item.url) ? 0.45 : 1.0)
            }
            .width(min: 60, ideal: 120)

            TableColumn("大小", sortUsing: FileSortComparator(.size)) { item in
                Text(item.formattedSize)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .opacity(cutURLs.contains(item.url) ? 0.45 : 1.0)
            }
            .width(min: 60, ideal: 100)
            .alignment(.trailing)
        }
        .tableStyle(.inset)
        .contextMenu(forSelectionType: URL.self) { urls in
            if urls.isEmpty {
                Button("新建文件夹") { startCreateFolder() }
                Button("粘贴") { pasteFromClipboard() }
                    .disabled(clipboardURLs.isEmpty)
                Divider()
                Button(showHiddenFiles ? "不显示隐藏项目" : "显示隐藏项目") {
                    showHiddenFiles.toggle()
                }
            } else {
                Button("打开") { openItems(urls) }
                Divider()
                Button("复制") { copySelection(urls) }
                Button("剪切") { cutSelection(urls) }
                Divider()
                Button("重命名") { startRename(target: urls.first) }
                    .disabled(urls.count != 1)
                Divider()
                Button("在 Finder 中显示") {
                    if let url = urls.first {
                        fsService.revealInFinder(url)
                    }
                }
                if urls.count == 1, let singleURL = urls.first, isDirectory(singleURL) {
                    Button("在 Finder 中打开") {
                        fsService.openInFinder(singleURL)
                    }
                }
                Divider()
                Button("复制路径") {
                    if let url = urls.first {
                        fsService.copyPath(url)
                    }
                }
                Divider()
                Button("移到废纸篓") { trashSelection(urls) }
            }
        } primaryAction: { urls in
            openItems(urls)
        }
        .onKeyPress(keys: [.return, .delete, KeyEquivalent("\u{F705}")]) { press in
            guard !isRenaming, !isCreatingFolder, press.modifiers.isEmpty else { return .ignored }
            switch press.key {
            case .return:
                guard !selectedURLs.isEmpty else { return .ignored }
                openItems(selectedURLs)
                return .handled
            case .delete:
                guard currentURL.path != "/" else { return .ignored }
                onNavigate(currentURL.deletingLastPathComponent())
                return .handled
            case KeyEquivalent("\u{F705}"):
                guard selectedURLs.count == 1 else { return .ignored }
                startRename()
                return .handled
            default:
                return .ignored
            }
        }
        .renameAction { startRename() }
        .onChange(of: newFolderTrigger) { startCreateFolder() }
        .onChange(of: renameTrigger) { startRename() }
        .onChange(of: currentURL) { cancelRename() }
        .alert("新建文件夹", isPresented: $isCreatingFolder) {
            TextField("文件夹名称", text: $newFolderText)
            Button("创建") { commitCreateFolder() }
            Button("取消", role: .cancel) {}
        }
        .overlay {
            if files.isEmpty {
                Group {
                    if !searchText.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                    } else {
                        ContentUnavailableView("此文件夹为空", systemImage: "folder")
                    }
                }
                .allowsHitTesting(false)
            }
        }
    }

    // MARK: - 辅助

    private func isDirectory(_ url: URL) -> Bool {
        files.first(where: { $0.url == url })?.isDirectory ?? url.hasDirectoryPath
    }

    private func openItems(_ urls: Set<URL>) {
        guard !urls.isEmpty else { return }
        if urls.count == 1, let url = urls.first, isDirectory(url) {
            onNavigate(url)
        } else {
            for url in urls {
                fsService.openFile(url)
            }
        }
    }

    // MARK: - 操作

    private func startRename(target: URL? = nil) {
        let url: URL?
        if let target {
            url = target
        } else if selectedURLs.count == 1 {
            url = selectedURLs.first
        } else {
            url = nil
        }
        guard let url else { return }
        selectedURLs = [url]
        renameTarget = url
        renameText = url.lastPathComponent
        isRenaming = true
    }

    private func commitRename() {
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        guard let target = renameTarget,
              !trimmed.isEmpty,
              fsService.isValidFileName(trimmed),
              trimmed != target.lastPathComponent else {
            cancelRename()
            return
        }
        do {
            let newURL = try fsService.renameItem(at: target, to: trimmed)
            selectedURLs.remove(target)
            selectedURLs.insert(newURL)
            onRefresh()
        } catch {
            print("重命名失败: \(error)")
        }
        cancelRename()
    }

    private func cancelRename() {
        isRenaming = false
        renameTarget = nil
        renameText = ""
        renameFieldFocused = false
    }

    private func startCreateFolder() {
        newFolderText = "新建文件夹"
        isCreatingFolder = true
    }

    private func commitCreateFolder() {
        let trimmed = newFolderText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, fsService.isValidFileName(trimmed) else { return }
        do {
            let newURL = try fsService.createFolder(at: currentURL, name: trimmed)
            selectedURLs = [newURL]
            onRefresh()
        } catch {
            print("创建文件夹失败: \(error)")
        }
    }

    private func pasteFromClipboard() {
        guard !clipboardURLs.isEmpty else { return }
        let executed = fsService.pasteItems(clipboardURLs, to: currentURL, isCut: clipboardIsCut)
        if clipboardIsCut && executed {
            clipboardURLs = []
            clipboardIsCut = false
        }
        onRefresh()
    }

    private func copySelection(_ urls: Set<URL>) {
        guard !urls.isEmpty else { return }
        clipboardURLs = Array(urls)
        clipboardIsCut = false
    }

    private func cutSelection(_ urls: Set<URL>) {
        guard !urls.isEmpty else { return }
        clipboardURLs = Array(urls)
        clipboardIsCut = true
        selectedURLs = []
    }

    private func trashSelection(_ urls: Set<URL>) {
        guard !urls.isEmpty else { return }
        fsService.moveToTrash(Array(urls))
        onRefresh()
    }
}

// MARK: - 图标缓存（NSWorkspace.icon(forFile:) 涉及磁盘查找，不能每行每次渲染都调）

@MainActor
enum IconCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for url: URL) -> NSImage {
        let key = url.path as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 20, height: 20)
        cache.setObject(image, forKey: key)
        return image
    }
}
