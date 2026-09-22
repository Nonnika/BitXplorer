import SwiftUI
import AppKit

/// 文件列表：原生 NSTableView 承载（列宽拖拽、多选、方向键导航、右键菜单均为系统行为），
/// SwiftUI 只负责新文件夹输入行与状态接线
struct FileListView: View {
    @Binding var files: [FileItem]
    @Binding var selectedURLs: Set<URL>
    @Binding var clipboardURLs: [URL]
    @Binding var clipboardIsCut: Bool
    @Binding var currentURL: URL
    @Binding var showHiddenFiles: Bool
    let onNavigate: (URL) -> Void
    let fsService: FileSystemService
    @Binding var isRenaming: Bool
    @Binding var renameTarget: URL?
    @Binding var renameText: String
    let onRefresh: () -> Void

    @State private var isCreatingFolder = false
    @State private var newFolderText = "新建文件夹"
    @FocusState private var newFolderFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // 新文件夹输入行（全局）
            if isCreatingFolder {
                HStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.badge.plus")
                            .resizable().frame(width: 20, height: 16)
                            .foregroundColor(.accentColor)
                        TextField("新建文件夹名称", text: $newFolderText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .focused($newFolderFieldFocused)
                            .onSubmit { commitCreateFolder() }
                            .onExitCommand { isCreatingFolder = false }
                            .onAppear {
                                newFolderText = "新建文件夹"
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                    newFolderFieldFocused = true
                                }
                            }
                    }
                    .frame(minWidth: 200, alignment: .leading)
                    Spacer()
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .background(Color.accentColor.opacity(0.08))
            }

            ZStack {
                FileTable(
                    files: sortedFiles,
                    selectedURLs: $selectedURLs,
                    clipboardURLs: $clipboardURLs,
                    clipboardIsCut: $clipboardIsCut,
                    currentURL: currentURL,
                    showHiddenFiles: showHiddenFiles,
                    isRenaming: $isRenaming,
                    renameTarget: $renameTarget,
                    renameText: $renameText,
                    onNavigate: onNavigate,
                    onRefresh: onRefresh,
                    fsService: fsService,
                    actions: FileTable.Actions(
                        startRename: startRename,
                        commitRename: commitRename,
                        cancelRename: cancelRename,
                        startCreateFolder: startCreateFolder,
                        paste: pasteFromClipboard,
                        copy: copySelection,
                        cut: cutSelection,
                        trash: trashSelection,
                        toggleHidden: { showHiddenFiles.toggle() }
                    )
                )
                if files.isEmpty && !isCreatingFolder {
                    Text("此文件夹为空")
                        .foregroundColor(.secondary)
                        .allowsHitTesting(false)
                }
            }
            // 表格延伸到标题栏下：行滚动时钻进工具栏材质底下被模糊（表头由
            // NSScrollView 自动 contentInsets 压回工具栏下方）
            .ignoresSafeArea(edges: .top)
        }
    }

    // MARK: - 排序（固定：文件夹在前，按名称排序）

    private var sortedFiles: [FileItem] {
        let dirs = files.filter(\.isDirectory)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let nonDirs = files.filter { !$0.isDirectory }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return dirs + nonDirs
    }

    // MARK: - 操作（表格菜单/键盘经由 Actions 调回）

    func startRename() {
        guard let url = selectedURLs.first, selectedURLs.count == 1 else { return }
        renameTarget = url
        renameText = url.lastPathComponent
        isRenaming = true
    }

    func commitRename(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
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

    func cancelRename() {
        isRenaming = false
        renameTarget = nil
        renameText = ""
    }

    func startCreateFolder() {
        isCreatingFolder = true
        newFolderText = "新建文件夹"
    }

    private func commitCreateFolder() {
        guard !newFolderText.trimmingCharacters(in: .whitespaces).isEmpty,
              fsService.isValidFileName(newFolderText) else {
            isCreatingFolder = false
            return
        }
        do {
            _ = try fsService.createFolder(at: currentURL, name: newFolderText.trimmingCharacters(in: .whitespaces))
            onRefresh()
        } catch {
            print("创建文件夹失败: \(error)")
        }
        isCreatingFolder = false
    }

    func pasteFromClipboard() {
        guard !clipboardURLs.isEmpty else { return }
        let executed = fsService.pasteItems(clipboardURLs, to: currentURL, isCut: clipboardIsCut)
        if clipboardIsCut && executed {
            clipboardURLs = []
            clipboardIsCut = false
        }
        onRefresh()
    }

    func copySelection(_ urls: Set<URL>) {
        guard !urls.isEmpty else { return }
        clipboardURLs = Array(urls)
        clipboardIsCut = false
    }

    func cutSelection(_ urls: Set<URL>) {
        guard !urls.isEmpty else { return }
        clipboardURLs = Array(urls)
        clipboardIsCut = true
    }

    func trashSelection(_ urls: Set<URL>) {
        guard !urls.isEmpty else { return }
        fsService.moveToTrash(Array(urls))
        onRefresh()
    }
}

// MARK: - NSViewRepresentable（NSScrollView + NSTableView）

private struct FileTable: NSViewRepresentable {
    let files: [FileItem]
    @Binding var selectedURLs: Set<URL>
    @Binding var clipboardURLs: [URL]
    @Binding var clipboardIsCut: Bool
    let currentURL: URL
    let showHiddenFiles: Bool
    @Binding var isRenaming: Bool
    @Binding var renameTarget: URL?
    @Binding var renameText: String
    let onNavigate: (URL) -> Void
    let onRefresh: () -> Void
    let fsService: FileSystemService
    let actions: Actions

    struct Actions {
        let startRename: () -> Void
        let commitRename: (String) -> Void
        let cancelRename: () -> Void
        let startCreateFolder: () -> Void
        let paste: () -> Void
        let copy: (Set<URL>) -> Void
        let cut: (Set<URL>) -> Void
        let trash: (Set<URL>) -> Void
        let toggleHidden: () -> Void
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = FileTableView()
        table.rowHeight = 28
        table.intercellSpacing = .zero
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .clear
        table.style = .fullWidth
        table.headerView = NSTableHeaderView()
        table.focusRingType = .none

        let name = NSTableColumn(identifier: .init("name"))
        name.title = "名称"
        name.width = 200
        name.minWidth = 120
        // 名称列随窗口伸缩，其余列用户可拖
        name.resizingMask = [.autoresizingMask, .userResizingMask]
        let date = NSTableColumn(identifier: .init("date"))
        date.title = "修改日期"
        date.width = 155
        date.minWidth = 110
        let kind = NSTableColumn(identifier: .init("kind"))
        kind.title = "类型"
        kind.width = 130
        kind.minWidth = 50
        let size = NSTableColumn(identifier: .init("size"))
        size.title = "大小"
        size.width = 100
        size.minWidth = 50
        table.addTableColumn(name)
        table.addTableColumn(date)
        table.addTableColumn(kind)
        table.addTableColumn(size)

        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked)

        let menu = NSMenu()
        menu.delegate = context.coordinator
        menu.autoenablesItems = false
        table.menu = menu

        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        context.coordinator.tableView = table

        // 闭包强持有 coordinator 无环：coordinator 对 table 只持弱引用
        let coordinator = context.coordinator
        table.onBackspace = {
            let url = coordinator.parent.currentURL
            guard url.path != "/" else { return }
            coordinator.parent.onNavigate(url.deletingLastPathComponent())
        }
        table.onRenameShortcut = {
            coordinator.parent.actions.startRename()
        }
        table.onEnter = {
            guard let row = coordinator.tableView?.selectedRowIndexes.first,
                  let file = coordinator.parent.files[safe: row] else { return }
            coordinator.open(file)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let table = context.coordinator.tableView else { return }

        let urls = files.map(\.url)
        if urls != context.coordinator.fileURLs {
            context.coordinator.fileURLs = urls
            table.reloadData()
        }

        // 同步外部选择变更（重命名换 URL、导航清空等）
        let tableSelection = Set(table.selectedRowIndexes.compactMap { files[safe: $0]?.url })
        if tableSelection != selectedURLs {
            let indexes = IndexSet(files.enumerated().filter { selectedURLs.contains($0.element.url) }.map(\.offset))
            table.selectRowIndexes(indexes, byExtendingSelection: false)
        }

        // 剪切态（行透明度）与重命名行变化时刷新可见行
        let clipKey = "\(clipboardIsCut)|\(clipboardURLs.map(\.path).sorted().joined(separator: "\n"))"
        if clipKey != context.coordinator.clipboardKey
            || isRenaming != context.coordinator.wasRenaming
            || renameTarget != context.coordinator.wasRenameTarget {
            context.coordinator.clipboardKey = clipKey
            context.coordinator.wasRenaming = isRenaming
            context.coordinator.wasRenameTarget = renameTarget
            table.reloadData()
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource, NSTextFieldDelegate, NSMenuDelegate, NSControlTextEditingDelegate {
        var parent: FileTable
        weak var tableView: FileTableView?
        weak var renameField: NSTextField?
        var fileURLs: [URL] = []
        var clipboardKey = ""
        var wasRenaming = false
        var wasRenameTarget: URL?

        init(_ parent: FileTable) {
            self.parent = parent
        }

        // MARK: 数据源与单元格

        func numberOfRows(in _: NSTableView) -> Int { parent.files.count }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let rowView = FileListRowView()
            rowView.rowIndex = row
            // 剪切中的行半透明
            if parent.clipboardIsCut, let file = parent.files[safe: row], parent.clipboardURLs.contains(file.url) {
                rowView.alphaValue = 0.45
            }
            return rowView
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let file = parent.files[safe: row] else { return nil }
            switch tableColumn.identifier.rawValue {
            case "name":
                let cell = NSTableCellView()
                let icon = NSImageView(image: IconCache.icon(for: file.url))
                icon.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(icon)

                if parent.isRenaming, parent.renameTarget == file.url {
                    let field = NSTextField(string: parent.renameText.isEmpty ? file.name : parent.renameText)
                    field.isEditable = true
                    field.isBordered = false
                    field.drawsBackground = false
                    field.focusRingType = .none
                    field.font = .systemFont(ofSize: 13)
                    field.lineBreakMode = .byTruncatingTail
                    field.delegate = self
                    field.translatesAutoresizingMaskIntoConstraints = false
                    cell.addSubview(field)
                    renameField = field
                    NSLayoutConstraint.activate([
                        field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                        field.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
                        field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    ])
                    DispatchQueue.main.async {
                        field.window?.makeFirstResponder(field)
                        field.selectText(nil)
                    }
                } else {
                    let label = NSTextField(labelWithString: file.name)
                    label.font = .systemFont(ofSize: 13)
                    label.lineBreakMode = .byTruncatingTail
                    label.translatesAutoresizingMaskIntoConstraints = false
                    cell.addSubview(label)
                    NSLayoutConstraint.activate([
                        label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                        label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
                        label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    ])
                }

                NSLayoutConstraint.activate([
                    icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    icon.widthAnchor.constraint(equalToConstant: 20),
                    icon.heightAnchor.constraint(equalToConstant: 20),
                ])
                return cell
            default:
                let text: String
                let alignment: NSTextAlignment
                switch tableColumn.identifier.rawValue {
                case "date":
                    text = file.formattedDate
                    alignment = .left
                case "kind":
                    text = file.fileTypeDisplay
                    alignment = .left
                default:
                    text = file.isDirectory ? "--" : file.formattedSize
                    alignment = .right
                }
                let label = NSTextField(labelWithString: text)
                label.font = .systemFont(ofSize: 12)
                label.textColor = .secondaryLabelColor
                label.alignment = alignment
                label.lineBreakMode = .byTruncatingTail
                label.translatesAutoresizingMaskIntoConstraints = false
                let cell = NSTableCellView()
                cell.addSubview(label)
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(greaterThanOrEqualTo: cell.leadingAnchor, constant: 4),
                    label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
                return cell
            }
        }

        // MARK: 选择与双击

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table = tableView else { return }
            // 选中块的角形取决于相邻行，NSTableView 只重绘选中变化的行，需整体标脏
            table.setNeedsDisplay(table.bounds)
            let urls = Set(table.selectedRowIndexes.compactMap { parent.files[safe: $0]?.url })
            if urls != parent.selectedURLs {
                parent.selectedURLs = urls
            }
        }

        @objc func doubleClicked() {
            guard let table = tableView else { return }
            let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
            guard let file = parent.files[safe: row] else { return }
            open(file)
        }

        func open(_ file: FileItem) {
            if file.isDirectory {
                parent.onNavigate(file.url)
            } else {
                parent.fsService.openFile(file.url)
            }
        }

        /// 右键目标：命中已选行时作用于整个选区，否则作用于右键所在行
        private func selectionURLs(clickedRow: Int) -> Set<URL> {
            guard let table = tableView, clickedRow >= 0 else { return [] }
            if table.selectedRowIndexes.contains(clickedRow) {
                return Set(table.selectedRowIndexes.compactMap { parent.files[safe: $0]?.url })
            }
            return parent.files[safe: clickedRow].map { [$0.url] } ?? []
        }

        // MARK: 右键菜单

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table = tableView else { return }
            let row = table.clickedRow

            if row >= 0, let file = parent.files[safe: row] {
                let selection = selectionURLs(clickedRow: row)
                menu.addItem(item("打开") { [weak self] in self?.open(file) })
                menu.addItem(.separator())
                menu.addItem(item("复制") { [weak self] in self?.parent.actions.copy(selection) })
                menu.addItem(item("剪切") { [weak self] in self?.parent.actions.cut(selection) })
                menu.addItem(.separator())
                let rename = item("重命名") { [weak self] in self?.parent.actions.startRename() }
                rename.isEnabled = selection.count == 1
                menu.addItem(rename)
                menu.addItem(.separator())
                menu.addItem(item("在 Finder 中显示") { [weak self] in self?.parent.fsService.revealInFinder(file.url) })
                if file.isDirectory {
                    menu.addItem(item("在 Finder 中打开") { [weak self] in self?.parent.fsService.openInFinder(file.url) })
                }
                menu.addItem(.separator())
                menu.addItem(item("复制路径") { [weak self] in self?.parent.fsService.copyPath(file.url) })
                menu.addItem(.separator())
                menu.addItem(item("移到废纸篓") { [weak self] in self?.parent.actions.trash(selection) })
            } else {
                menu.addItem(item("新建文件夹") { [weak self] in self?.parent.actions.startCreateFolder() })
                let paste = item("粘贴") { [weak self] in self?.parent.actions.paste() }
                paste.isEnabled = !parent.clipboardURLs.isEmpty
                menu.addItem(paste)
                menu.addItem(.separator())
                menu.addItem(item(parent.showHiddenFiles ? "不显示隐藏项目" : "显示隐藏项目") { [weak self] in
                    self?.parent.actions.toggleHidden()
                })
            }
        }

        private func item(_ title: String, _ handler: @escaping () -> Void) -> NSMenuItem {
            let menuItem = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = handler
            menuItem.isEnabled = true
            return menuItem
        }

        @objc private func menuAction(_ sender: NSMenuItem) {
            (sender.representedObject as? () -> Void)?()
        }

        // MARK: 行内重命名

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField, field == renameField else { return }
            parent.renameText = field.stringValue
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard parent.isRenaming, let field = renameField else { return }
            renameField = nil
            parent.actions.commitRename(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // Esc 取消重命名；回车走默认流程结束编辑 → controlTextDidEndEditing 提交
            guard selector == #selector(NSTextView.cancelOperation(_:)) else { return false }
            parent.actions.cancelRename()
            return true
        }
    }
}

// MARK: - 选中高亮（左右内缩的圆角块；连续多选合并为一个大圆角矩形）

final class FileListRowView: NSTableRowView {
    var rowIndex = -1

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle == .regular, isSelected,
              let table = superview as? NSTableView else { return }
        let sel = table.selectedRowIndexes
        let isFirst = !sel.contains(rowIndex - 1) // 块首行（视觉最上）
        let isLast = !sel.contains(rowIndex + 1)  // 块尾行（视觉最下）
        // row view 坐标是 flipped：minY 是视觉顶、maxY 是视觉底；拼接边必须齐平
        var rect = bounds.insetBy(dx: 4, dy: 0)
        if isFirst { rect.origin.y += 2; rect.size.height -= 2 }
        if isLast { rect.size.height -= 2 }

        let r: CGFloat = 6
        // 中间行的视觉角用矩形补成直角（非零绕组填充 = 两形状并集）
        let path = NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r)
        if !isFirst { path.append(NSBezierPath(rect: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: r))) }
        if !isLast { path.append(NSBezierPath(rect: NSRect(x: rect.minX, y: rect.maxY - r, width: rect.width, height: r))) }
        (isEmphasized ? NSColor.selectedContentBackgroundColor
                      : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
        path.fill()
    }
}

// MARK: - 键盘导航（退格返回上级 / F2 重命名 / 回车打开，方向键等交回系统）

final class FileTableView: NSTableView {
    var onBackspace: (() -> Void)?
    var onRenameShortcut: (() -> Void)?
    var onEnter: (() -> Void)?

    // 右键菜单的"作用范围"高亮：系统原版单选画蓝环、多选画白环（无视
    // focusRingType）。覆盖成给右键目标行画一圈蓝色圆角描边（右键不改变
    // 选区，行可能并不在 selectedRowIndexes 里），多选时不画
    @objc func drawContextMenuHighlightForRow(_ row: Int) {
        guard selectedRowIndexes.count <= 1 else { return }
        let path = NSBezierPath(roundedRect: rect(ofRow: row).insetBy(dx: 2.5, dy: 0.5),
                                xRadius: 7, yRadius: 7)
        path.lineWidth = 2
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51: onBackspace?()
        case 120: onRenameShortcut?()
        case 36: onEnter?()
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let selectionBefore = selectedRowIndexes
        // 空白处的拖拽框选整个手势（含松开）都在 super 内完成
        super.mouseDown(with: event)
        // 点击行外空白区域清除选择；框选会改变选区，不能当作点击清空
        if clickedRow == -1, selectedRowIndexes == selectionBefore {
            deselectAll(nil)
        }
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

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
