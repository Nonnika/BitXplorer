import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Quartz

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
                    Image(nsImage: IconCache.icon(for: item))
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
        // ↑↓ 由 Table 原生切换选中；→ 进入选中的文件夹，← / Delete 返回上一级
        .onKeyPress(keys: [.return, .delete, .leftArrow, .rightArrow, .space, .escape, KeyEquivalent("\u{F705}")]) { press in
            // 方向键自带 numericPad/function 标志，只看真正的修饰键；带 ⌘ 的交给外层（⌘←/→ 切栏）
            guard !isRenaming, !isCreatingFolder,
                  press.modifiers.intersection([.command, .shift, .option, .control]).isEmpty
            else { return .ignored }
            switch press.key {
            case .return:
                guard !selectedURLs.isEmpty else { return .ignored }
                openItems(selectedURLs)
                return .handled
            case .space:
                QuickLook.shared.toggle(previewURLs())
                return .handled
            case .escape:
                guard QuickLook.shared.isVisible else { return .ignored }
                QuickLook.shared.close()
                return .handled
            case .rightArrow:
                guard selectedURLs.count == 1, let url = selectedURLs.first, canEnter(url) else { return .ignored }
                onNavigate(url)
                return .handled
            case .delete, .leftArrow:
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
        // Quick Look 打开时跟随选中项（↑↓ 浏览）
        .onChange(of: selectedURLs) { QuickLook.shared.updateIfVisible(previewURLs()) }
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

    /// 选中项按列表显示顺序（带行号，供 Quick Look 缩放动画定位），zip 包内文件解出后才能预览（包内目录跳过）
    private func previewURLs() -> [QuickLook.Item] {
        sortedFiles.enumerated().compactMap { row, item in
            guard selectedURLs.contains(item.url), let url = try? fsService.materialize(item.url) else { return nil }
            return QuickLook.Item(row: row, url: url, icon: IconCache.icon(for: item))
        }
    }

    /// 可以像目录一样进入：文件夹，或磁盘上的 zip（包内嵌套 zip 不支持，按文件打开）
    private func canEnter(_ url: URL) -> Bool {
        isDirectory(url) || (ZipArchive.isZip(url) && ZipArchive.split(url.deletingLastPathComponent()) == nil)
    }

    private func openItems(_ urls: Set<URL>) {
        guard !urls.isEmpty else { return }
        if urls.count == 1, let url = urls.first, canEnter(url) {
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

    static func icon(for item: FileItem) -> NSImage {
        let url = item.url
        let key = url.path as NSString
        if let hit = cache.object(forKey: key) { return hit }
        // zip 包内条目不在磁盘上，按类型取图标
        let image = FileManager.default.fileExists(atPath: url.path)
            ? NSWorkspace.shared.icon(forFile: url.path)
            : NSWorkspace.shared.icon(for: item.isDirectory ? .folder : UTType(filenameExtension: item.fileExtension) ?? .data)
        image.size = NSSize(width: 20, height: 20)
        cache.setObject(image, forKey: key)
        return image
    }
}

// MARK: - Quick Look（系统 QLPreviewPanel）

/// 空格预览。面板只 orderFront、不抢 key，列表仍接收方向键，选中变化时刷新内容；
/// delegate 提供行图标的屏幕位置，面板据此从图标缩放弹出/收回
@MainActor
final class QuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    struct Item {
        let row: Int
        let url: URL
        let icon: NSImage
    }

    static let shared = QuickLook()
    private var items: [Item] = []
    /// 按空格时有焦点的列表（SwiftUI Table 底层的 NSTableView），用于换算行图标坐标
    private weak var tableView: NSTableView?

    var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    func toggle(_ urls: [Item]) {
        isVisible ? close() : show(urls)
    }

    func close() {
        QLPreviewPanel.shared().orderOut(nil)
    }

    func updateIfVisible(_ urls: [Item]) {
        guard isVisible else { return }
        urls.isEmpty ? close() : show(urls)
    }

    private func show(_ urls: [Item]) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.items = urls
        let responder = NSApp.keyWindow?.firstResponder as? NSView
        if let table = responder as? NSTableView ?? responder?.enclosingScrollView?.documentView as? NSTableView {
            tableView = table
        }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        panel.orderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { items.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { items[index].url as NSURL }
    }

    /// 当前预览项图标在屏幕上的位置；行不可见时返回 .zero，面板退化为淡入淡出
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        let url = (item as? NSURL) as URL?
        return MainActor.assumeIsolated {
            guard let table = tableView, let window = table.window,
                  let row = items.first(where: { $0.url == url })?.row,
                  row < table.numberOfRows else { return .zero }
            let cell = table.frameOfCell(atColumn: 0, row: row)
            guard table.visibleRect.intersects(cell) else { return .zero }
            // 名称列的图标在单元格最左侧，20×20 垂直居中
            let icon = NSRect(x: cell.minX + 2, y: cell.midY - 10, width: 20, height: 20)
            return window.convertToScreen(table.convert(icon, to: nil))
        }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: (any QLPreviewItem)!,
                                  contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
        let url = (item as? NSURL) as URL?
        let icon: NSImage? = MainActor.assumeIsolated { items.first(where: { $0.url == url })?.icon }
        return icon
    }
}
