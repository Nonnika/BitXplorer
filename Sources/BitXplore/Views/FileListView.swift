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
    /// 双栏时提供：在另一栏打开文件夹
    var onOpenInOtherPane: ((URL) -> Void)? = nil

    /// 用户自选的终端 App 路径（「选择其他终端…」），在菜单中排第一
    @AppStorage("customTerminalPath") private var customTerminalPath = ""
    @AppStorage(SidebarFavorite.storageKey) private var favoritesData = Data()

    @State private var sortOrder: [FileSortComparator] = [FileSortComparator(.name)]
    @State private var isRenaming = false
    @State private var renameTarget: URL?
    @State private var renameText = ""
    @FocusState private var renameFieldFocused: Bool

    /// 刚新建、等列表刷新出来后进入重命名的文件夹
    @State private var pendingRename: URL?
    /// 需要滚动到可见的行
    @State private var scrollTarget: URL?

    private var sortedFiles: [FileItem] {
        files.sorted(using: sortOrder)
    }

    var body: some View {
        ScrollViewReader { proxy in
            table.onChange(of: scrollTarget) {
                guard let scrollTarget else { return }
                proxy.scrollTo(scrollTarget)
                self.scrollTarget = nil
            }
        }
    }

    private var table: some View {
        let cutURLs: Set<URL> = clipboardIsCut ? Set(clipboardURLs) : []

        return Table(of: FileItem.self, selection: $selectedURLs, sortOrder: $sortOrder) {
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
        } rows: {
            fileRows
        }
        .tableStyle(.inset)
        // 换目录/改搜索时重建整个 Table，而不是在旧表上 diff：SwiftUI 的 Table 在“已滚到下方 + 数据骤减”时
        // 会拿旧的可见起始行去取新数据（ForEach.IDGenerator Index out of range 崩溃）。顺带让新目录从顶部开始
        .id(TableIdentity(url: currentURL, search: searchText))
        .contextMenu(forSelectionType: URL.self) { urls in
            if urls.isEmpty {
                backgroundMenu
            } else {
                itemMenu(urls)
            }
        } primaryAction: { urls in
            openItems(urls)
        }
        // ↑↓ 由 Table 原生切换选中；→ 进入选中的文件夹，← 返回上一级；Delete / ⌦ 移到废纸篓
        .onKeyPress(keys: [.return, .delete, .deleteForward, .leftArrow, .rightArrow, .space, .escape, KeyEquivalent("\u{F705}")]) { press in
            // 方向键自带 numericPad/function 标志，只看真正的修饰键；带 ⌘ 的交给外层（⌘←/→ 切栏）
            guard !isRenaming,
                  press.modifiers.intersection([.command, .shift, .option, .control]).isEmpty
            else { return .ignored }
            switch press.key {
            case .return:
                guard !selectedURLs.isEmpty else { return .ignored }
                openItems(selectedURLs)
                return .handled
            case .space:
                QuickLook.shared.toggle(previewURLs(selectedURLs))
                return .handled
            case .escape:
                guard QuickLook.shared.isVisible else { return .ignored }
                QuickLook.shared.close()
                return .handled
            case .rightArrow:
                guard selectedURLs.count == 1, let url = selectedURLs.first, canEnter(url) else { return .ignored }
                onNavigate(url)
                return .handled
            case .delete, .deleteForward:
                guard !selectedURLs.isEmpty, !inZip else { return .ignored }
                trashSelection(selectedURLs)
                return .handled
            case .leftArrow:
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
        .onChange(of: selectedURLs) { QuickLook.shared.updateIfVisible(previewURLs(selectedURLs)) }
        .onChange(of: newFolderTrigger) { startCreateFolder() }
        .onChange(of: renameTrigger) { startRename() }
        .onChange(of: currentURL) { cancelRename(); pendingRename = nil }
        // 新建的文件夹出现在列表里后：选中、滚到可见、进入重命名
        .onChange(of: files) {
            guard let target = pendingRename,
                  let item = files.first(where: { $0.url.standardizedFileURL.path == target.standardizedFileURL.path })
            else { return }
            pendingRename = nil
            scrollTarget = item.url
            startRename(target: item.url)
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

    /// 行：拖出（itemProvider）与拖入（行上 / 行间）
    @TableRowBuilder<FileItem>
    private var fileRows: some TableRowContent<FileItem> {
        ForEach(sortedFiles) { item in
            // 拖出：多选时 Table 会为每个选中行取 provider；zip 包内条目在拖动开始时解出到临时目录
            TableRow(item)
                .itemProvider {
                    (try? fsService.materialize(item.url)).map { NSItemProvider(object: $0 as NSURL) }
                }
                // 落在文件夹/zip 行上：放进该文件夹；落在普通文件行上：放进当前目录
                .dropDestination(for: URL.self) { urls in
                    drop(urls, into: canEnter(item.url) ? item.url : currentURL)
                }
        }
        // 落在行与行之间或列表下方空白：放进当前目录。
        // Table 上的视图级 .dropDestination 收不到（底层 NSTableView 接管拖放），行间插入只能走 onInsert
        .onInsert(of: [.fileURL]) { _, providers in
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    let url: URL? = await withCheckedContinuation { done in
                        _ = provider.loadTransferable(type: URL.self) { done.resume(returning: try? $0.get()) }
                    }
                    if let url { urls.append(url) }
                }
                drop(urls, into: currentURL)
            }
        }
    }

    // MARK: - 右键菜单

    /// 当前在 zip 包内：只读，写操作全部禁用
    private var inZip: Bool { ZipArchive.split(currentURL) != nil }

    @ViewBuilder
    private var backgroundMenu: some View {
        Button("新建文件夹") { startCreateFolder() }
            .disabled(inZip)
        Button("粘贴") { pasteFromClipboard() }
            .disabled(clipboardURLs.isEmpty)
        Divider()
        terminalMenu(for: currentURL)
        Button("在 Finder 中打开") { fsService.openInFinder(currentURL) }
            .disabled(inZip)
        Button("复制当前路径") { fsService.copyToPasteboard(currentURL.path) }
        Button("将当前文件夹添加到快速访问") {
            favoritesData = SidebarFavorite.adding([currentURL], to: favoritesData)
        }
        .disabled(inZip)
        Divider()
        Button(showHiddenFiles ? "不显示隐藏项目" : "显示隐藏项目") {
            showHiddenFiles.toggle()
        }
    }

    @ViewBuilder
    private func itemMenu(_ urls: Set<URL>) -> some View {
        // 按列表顺序，保证复制路径等输出稳定
        let ordered = sortedFiles.map(\.url).filter(urls.contains)
        let single = ordered.count == 1 ? ordered.first : nil
        let allZips = ordered.allSatisfy { ZipArchive.isZip($0) && !isDirectory($0) }

        Button("打开") { openItems(urls) }
        if let first = ordered.first, !ordered.contains(where: isDirectory) {
            openWithMenu(for: first, all: ordered)
        }
        if let single, canEnter(single), let onOpenInOtherPane {
            Button("在另一栏中打开") { onOpenInOtherPane(single) }
        }
        if !inZip, ordered.allSatisfy(isDirectory) {
            Button("添加到快速访问") {
                favoritesData = SidebarFavorite.adding(ordered, to: favoritesData)
            }
        }
        Button("快速查看") { QuickLook.shared.toggle(previewURLs(urls)) }
        Divider()

        Button("剪切") { cutSelection(urls) }
            .disabled(inZip)
        Button("复制") { copySelection(urls) }
        Button("创建副本") {
            selectedURLs = Set(fsService.duplicate(ordered))
            onRefresh()
        }
        .disabled(inZip)
        Button("重命名") { startRename(target: single) }
            .disabled(single == nil || inZip)
        Divider()

        Button(single.map { "压缩「\($0.lastPathComponent)」" } ?? "压缩 \(ordered.count) 个项目") {
            if let zip = fsService.compress(ordered) { selectedURLs = [zip] }
            onRefresh()
        }
        .disabled(inZip)
        if allZips {
            Button("解压到当前文件夹") {
                selectedURLs = Set(ordered.compactMap { fsService.extractZip($0) })
                onRefresh()
            }
            .disabled(inZip)
        }
        Divider()

        Button(ordered.count > 1 ? "复制 \(ordered.count) 个路径" : "复制路径") {
            fsService.copyToPasteboard(ordered.map(\.path).joined(separator: "\n"))
        }
        Button(ordered.count > 1 ? "复制 \(ordered.count) 个名称" : "复制名称") {
            fsService.copyToPasteboard(ordered.map(\.lastPathComponent).joined(separator: "\n"))
        }
        Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting(ordered) }
            .disabled(inZip)
        if let single {
            // 文件夹在自身打开终端，文件在其所在目录
            terminalMenu(for: isDirectory(single) ? single : currentURL)
        }
        Divider()

        Button("移到废纸篓") { trashSelection(urls) }
            .disabled(inZip)
    }

    /// 打开方式：默认 App 排第一
    private func openWithMenu(for url: URL, all urls: [URL]) -> some View {
        let apps = fsService.applications(toOpen: url)
        return Menu("打开方式") {
            ForEach(Array(apps.enumerated()), id: \.element) { index, app in
                Button {
                    fsService.open(urls, with: app)
                } label: {
                    Label { Text(appName(app) + (index == 0 ? "（默认）" : "")) } icon: { appIcon(app) }
                }
                if index == 0 && apps.count > 1 { Divider() }
            }
        }
    }

    /// 在终端中打开：自选终端排第一，其后是本机已安装的常见终端；可另选任意 App
    @ViewBuilder
    private func terminalMenu(for directory: URL) -> some View {
        let custom = customTerminalPath.isEmpty || !FileManager.default.fileExists(atPath: customTerminalPath)
            ? nil : URL(fileURLWithPath: customTerminalPath)
        let terminals = ([custom].compactMap { $0 } + fsService.installedTerminals().filter { $0.path != custom?.path })
        Menu("在终端中打开") {
            ForEach(terminals, id: \.self) { app in
                Button {
                    fsService.openInTerminal(directory, app: app)
                } label: {
                    Label { Text(appName(app)) } icon: { appIcon(app) }
                }
            }
            if !terminals.isEmpty { Divider() }
            Button("选择其他终端…") {
                guard let app = chooseTerminal() else { return }
                customTerminalPath = app.path
                fsService.openInTerminal(directory, app: app)
            }
        }
        .disabled(ZipArchive.split(directory) != nil)
    }

    private func chooseTerminal() -> URL? {
        let panel = NSOpenPanel()
        panel.message = "选择用于「在终端中打开」的终端 App"
        panel.prompt = "选择"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func appName(_ app: URL) -> String {
        (FileManager.default.displayName(atPath: app.path) as NSString).deletingPathExtension
    }

    private func appIcon(_ app: URL) -> Image {
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        icon.size = NSSize(width: 16, height: 16)
        return Image(nsImage: icon)
    }

    // MARK: - 辅助

    private func isDirectory(_ url: URL) -> Bool {
        files.first(where: { $0.url == url })?.isDirectory ?? url.hasDirectoryPath
    }

    private func drop(_ urls: [URL], into destination: URL) {
        fsService.dropItems(urls, to: destination)
        onRefresh()
    }

    /// 选中项按列表显示顺序（带行号，供 Quick Look 缩放动画定位），zip 包内文件解出后才能预览
    /// （包内目录跳过：方向键浏览时每次都解出整个目录太重）
    private func previewURLs(_ urls: Set<URL>) -> [QuickLook.Item] {
        sortedFiles.enumerated().compactMap { row, item in
            guard urls.contains(item.url),
                  !(item.isDirectory && ZipArchive.split(item.url) != nil),
                  let url = try? fsService.materialize(item.url) else { return nil }
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

    /// Finder 式新建：直接建「未命名文件夹」，列表刷新出来后进入行内重命名
    private func startCreateFolder() {
        guard !inZip else { return NSSound.beep() }
        do {
            pendingRename = try fsService.createUntitledFolder(in: currentURL)
            onRefresh()
        } catch {
            NSSound.beep()
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
        // zip 包内条目先解出，粘贴时才有真实文件可拷
        clipboardURLs = urls.compactMap { try? fsService.materialize($0) }
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

/// Table 的身份：目录或搜索词变化即视为新表
private struct TableIdentity: Hashable {
    let url: URL
    let search: String
}
