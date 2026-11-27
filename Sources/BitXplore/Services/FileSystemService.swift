import Foundation
import AppKit
import UniformTypeIdentifiers

/// 文件系统服务 - 无状态，负责目录读取与文件操作
final class FileSystemService: Sendable {

    /// 把用户输入/粘贴的路径解析为存在的 URL（或 zip 包内路径）；无法解析返回 nil。
    /// 容忍复制路径时常见的形态：首尾引号、file:// 链接、~、相对 base 的路径、终端里的反斜杠转义
    static func resolve(_ input: String, relativeTo base: URL) -> URL? {
        var raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.count >= 2, let quote = raw.first, quote == raw.last, quote == "\"" || quote == "'" {
            raw = String(raw.dropFirst().dropLast())
        }
        guard !raw.isEmpty else { return nil }

        var candidates: [URL] = []
        if raw.hasPrefix("file://"), let url = URL(string: raw), url.isFileURL {
            candidates.append(url)
        } else {
            // 先按原样，再试去掉反斜杠转义（"My\ File" → "My File"）
            for text in [raw, raw.replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression)] {
                let expanded = (text as NSString).expandingTildeInPath
                candidates.append(expanded.hasPrefix("/")
                    ? URL(fileURLWithPath: expanded)
                    : URL(fileURLWithPath: expanded, relativeTo: base))
            }
        }
        return candidates.map(\.standardizedFileURL).first {
            FileManager.default.fileExists(atPath: $0.path) || ZipArchive.split($0) != nil
        }
    }

    /// 读取指定路径下的文件列表（同步、可重入，调用方负责放后台线程）
    func listDirectory(at url: URL, showHidden: Bool = false) throws -> [FileItem] {
        let items: [FileItem]
        if let (zip, inner) = ZipArchive.split(url) {
            items = try ZipArchive.list(zip: zip, inner: inner, showHidden: showHidden)
        } else {
            items = try listRealDirectory(at: url, showHidden: showHidden)
        }
        return items.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func listRealDirectory(at url: URL, showHidden: Bool) throws -> [FileItem] {
        let keys: [URLResourceKey] = [
            .fileSizeKey,
            .contentModificationDateKey,
            .isDirectoryKey
        ]

        let options: FileManager.DirectoryEnumerationOptions = showHidden
            ? [.skipsSubdirectoryDescendants]
            : [.skipsHiddenFiles, .skipsSubdirectoryDescendants]

        return try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: options
        )
        .filter { showHidden || !$0.lastPathComponent.hasPrefix(".") }
        .map { FileItem(url: $0) }
    }

    /// 将文件移动到废纸篓（先弹窗确认），返回失败的个数
    @MainActor
    @discardableResult
    func moveToTrash(_ urls: [URL]) -> Int {
        guard !urls.isEmpty else { return 0 }

        let alert = NSAlert()
        alert.messageText = "移到废纸篓"
        alert.informativeText = urls.count == 1
            ? "确定要将「\(urls[0].lastPathComponent)」移到废纸篓吗？"
            : "确定要将这 \(urls.count) 个项目移到废纸篓吗？"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "移到废纸篓")
        alert.addButton(withTitle: "取消")
        alert.buttons[1].keyEquivalent = "\u{1b}" // Esc
        guard alert.runModal() == .alertFirstButtonReturn else { return 0 }

        var failures = 0
        for url in urls {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                failures += 1
                print("移到废纸篓失败 \(url.lastPathComponent): \(error)")
            }
        }
        if failures > 0 {
            let failAlert = NSAlert()
            failAlert.messageText = "\(failures) 个项目无法移到废纸篓"
            failAlert.informativeText = "请检查文件权限后重试。"
            failAlert.runModal()
        }
        return failures
    }

    /// 在 Finder 中打开文件夹
    func openInFinder(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// 磁盘上可直接访问的 URL：zip 包内文件先解出到临时目录，其余原样返回
    /// ponytail: 调用方在主线程同步解压，包内单个大文件会短暂卡顿；需要时挪到后台并显示进度
    func materialize(_ url: URL) throws -> URL {
        guard let (zip, inner) = ZipArchive.split(url), !inner.isEmpty else { return url }
        return try ZipArchive.extract(zip: zip, inner: inner)
    }

    /// 用默认应用打开文件；zip 包内文件先解出到临时目录再打开
    @MainActor
    func openFile(_ url: URL) {
        do {
            NSWorkspace.shared.open(try materialize(url))
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法打开「\(url.lastPathComponent)」"
            alert.informativeText = error as? ZipArchive.ZipError == .encrypted
                ? "该文件已加密，请用其他工具解压。"
                : "压缩包已损坏或使用了不支持的压缩方式。"
            alert.runModal()
        }
    }

    /// 复制文本到剪贴板（多个路径/名称按行拼接）
    func copyToPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    // MARK: - 打开方式 / 终端

    /// 能打开该文件的 App，默认 App 排第一；zip 包内条目不在磁盘上，按扩展名类型查询
    func applications(toOpen url: URL) -> [URL] {
        let ws = NSWorkspace.shared
        let onDisk = FileManager.default.fileExists(atPath: url.path)
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        let all = onDisk ? ws.urlsForApplications(toOpen: url) : ws.urlsForApplications(toOpen: type)
        let preferred = onDisk ? ws.urlForApplication(toOpen: url) : ws.urlForApplication(toOpen: type)
        guard let preferred else { return all }
        return [preferred] + all.filter { $0 != preferred }
    }

    @MainActor
    func open(_ urls: [URL], with app: URL) {
        let files = urls.compactMap { try? materialize($0) }
        NSWorkspace.shared.open(files, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// 常见终端。多数终端支持「用它打开文件夹」即在该目录开新窗口；
    /// 少数不支持的，以新实例启动并用命令行参数指定工作目录
    private static let terminals: [(bundleID: String, arguments: (@Sendable (String) -> [String])?)] = [
        ("com.apple.Terminal", nil),
        ("com.googlecode.iterm2", nil),
        ("com.mitchellh.ghostty", nil),
        ("dev.warp.Warp-Stable", nil),
        ("net.kovidgoyal.kitty", { ["--directory", $0] }),
        ("org.alacritty", { ["--working-directory", $0] }),
        ("com.github.wez.wezterm", { ["start", "--cwd", $0] }),
    ]

    /// 本机已安装的终端 App
    func installedTerminals() -> [URL] {
        Self.terminals.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) }
    }

    @MainActor
    func openInTerminal(_ directory: URL, app: URL) {
        let id = Bundle(url: app)?.bundleIdentifier
        let config = NSWorkspace.OpenConfiguration()
        if let arguments = Self.terminals.first(where: { $0.bundleID == id })?.arguments {
            config.arguments = arguments(directory.path)
            config.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: app, configuration: config)
        } else {
            NSWorkspace.shared.open([directory], withApplicationAt: app, configuration: config)
        }
    }

    // MARK: - 副本 / 压缩 / 解压

    /// 创建副本（「xxx 副本」「xxx 副本 2」…），返回新 URL
    @discardableResult
    func duplicate(_ urls: [URL]) -> [URL] {
        urls.compactMap { url in
            let dest = nextAvailableName(for: url, in: url.deletingLastPathComponent())
            return (try? FileManager.default.copyItem(at: url, to: dest)) != nil ? dest : nil
        }
    }

    /// 压缩为 zip（单项「名称.zip」，多项「归档.zip」），放在同一目录；返回生成的文件
    /// ponytail: 主线程同步执行，大目录会卡顿；需要时挪到后台并显示进度
    @discardableResult
    func compress(_ urls: [URL]) -> URL? {
        guard let dir = urls.first?.deletingLastPathComponent() else { return nil }
        let name = urls.count == 1 ? urls[0].lastPathComponent + ".zip" : "归档.zip"
        let dest = uniqueURL(name, in: dir)
        // -y 保留符号链接；-- 之后都是文件名
        return run("/usr/bin/zip", ["-r", "-y", "-q", dest.path, "--"] + urls.map(\.lastPathComponent), in: dir) ? dest : nil
    }

    /// 解压到同目录（同「归档实用工具」）：包内只有一个顶层项目时直接放出该项目，
    /// 否则放进以压缩包命名的新文件夹；返回放出的项目
    @discardableResult
    func extractZip(_ zip: URL) -> URL? {
        let dir = zip.deletingLastPathComponent()
        let temp = dir.appendingPathComponent(".BitXplore-unzip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, temp.path]) else { return nil }

        let items = ((try? FileManager.default.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent != "__MACOSX" }
        let (source, name) = items.count == 1
            ? (items[0], items[0].lastPathComponent)
            : (temp, zip.deletingPathExtension().lastPathComponent)
        let dest = uniqueURL(name, in: dir)
        return (try? FileManager.default.moveItem(at: source, to: dest)) != nil ? dest : nil
    }

    /// Finder 式不重名：「名称」「名称 2」「名称 3」…
    private func uniqueURL(_ name: String, in dir: URL) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = dir.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    private func run(_ tool: String, _ arguments: [String], in dir: URL? = nil) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = dir
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// 新建「未命名文件夹」（重名则「未命名文件夹 2」…）
    func createUntitledFolder(in dir: URL) throws -> URL {
        let newURL = uniqueURL("未命名文件夹", in: dir)
        try FileManager.default.createDirectory(at: newURL, withIntermediateDirectories: false)
        return newURL
    }

    /// 重命名文件或文件夹
    func renameItem(at url: URL, to newName: String) throws -> URL {
        let newURL = url.deletingLastPathComponent().appendingPathComponent(newName)
        try FileManager.default.moveItem(at: url, to: newURL)
        return newURL
    }

    /// 粘贴（移动或复制），目标已存在同名项时弹窗询问。
    /// 返回 true 表示剪切有实际执行（调用方应清空剪贴板）；全部被跳过/取消/失败时返回 false
    @MainActor
    @discardableResult
    func pasteItems(_ urls: [URL], to destination: URL, isCut: Bool) -> Bool {
        let conflictNames = urls.compactMap { url -> String? in
            let dest = destination.appendingPathComponent(url.lastPathComponent)
            return FileManager.default.fileExists(atPath: dest.path) ? url.lastPathComponent : nil
        }

        var replaceNames: Set<String> = []
        var renameConflicts = false
        var skipNames: Set<String> = []

        if !conflictNames.isEmpty {
            let alert = NSAlert()
            alert.messageText = "「\(destination.lastPathComponent)」中已存在同名项目"
            let list = conflictNames.count <= 3
                ? conflictNames.joined(separator: "、")
                : "\(conflictNames.count) 个项目"
            alert.informativeText = "「\(list)」已存在，要如何处理？"
            alert.addButton(withTitle: "替换")
            if isCut {
                alert.addButton(withTitle: "跳过")
                alert.addButton(withTitle: "取消")
            } else {
                alert.addButton(withTitle: "保留两者")
                alert.addButton(withTitle: "跳过")
            }
            alert.buttons[2].keyEquivalent = "\u{1b}" // Esc

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                replaceNames = Set(conflictNames)
            case .alertSecondButtonReturn:
                if isCut {
                    skipNames = Set(conflictNames)
                } else {
                    renameConflicts = true
                }
            default:
                if isCut { return false } // 取消：什么都不做
                skipNames = Set(conflictNames)
            }
        }

        var executedAny = false
        for url in urls {
            let name = url.lastPathComponent
            if skipNames.contains(name) { continue }
            // 剪切到原目录：无意义，跳过
            if isCut && url.deletingLastPathComponent().standardizedFileURL == destination.standardizedFileURL { continue }
            // 目标目录在源目录内部（含相同）：复制/移动目录进自身会无限递归，跳过
            let srcPath = url.standardizedFileURL.path
            let destPath = destination.standardizedFileURL.path
            if destPath == srcPath || destPath.hasPrefix(srcPath + "/") { continue }

            var dest = destination.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: dest.path) {
                if replaceNames.contains(name) {
                    try? FileManager.default.removeItem(at: dest)
                } else if renameConflicts {
                    dest = nextAvailableName(for: url, in: destination)
                } else {
                    continue
                }
            }
            do {
                if isCut {
                    try FileManager.default.moveItem(at: url, to: dest)
                } else {
                    try FileManager.default.copyItem(at: url, to: dest)
                }
                executedAny = true
            } catch {
                print("粘贴失败 \(name): \(error)")
            }
        }
        return isCut && executedAny
    }

    /// 拖放落下。目标在 zip 内（或就是 zip 文件）则加入压缩包；
    /// 否则沿用 Finder 语义：同一卷移动，跨卷或按住 ⌥ 复制
    @MainActor
    func dropItems(_ urls: [URL], to destination: URL) {
        let urls = urls.filter { $0.standardizedFileURL != destination.standardizedFileURL }
        guard !urls.isEmpty else { return }
        if let (zip, inner) = ZipArchive.split(destination) {
            addToZip(urls, zip: zip, inner: inner)
            return
        }
        func volume(_ url: URL) -> AnyHashable? {
            (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? AnyHashable
        }
        // ponytail: 混合来源时只要有一个跨卷就全部复制；需要时按条目分别决定
        let destVolume = volume(destination)
        let copy = NSEvent.modifierFlags.contains(.option) || urls.contains { volume($0) != destVolume }
        pasteItems(urls, to: destination, isCut: !copy)
    }

    /// 加入压缩包：同名条目先确认替换
    @MainActor
    private func addToZip(_ urls: [URL], zip: URL, inner: String) {
        let existing = Set(((try? ZipArchive.list(zip: zip, inner: inner, showHidden: true)) ?? []).map(\.name))
        let conflicts = urls.map(\.lastPathComponent).filter(existing.contains)
        if !conflicts.isEmpty {
            let alert = NSAlert()
            alert.messageText = "「\(zip.lastPathComponent)」中已存在同名项目"
            alert.informativeText = "「\(conflicts.prefix(3).joined(separator: "、"))」\(conflicts.count > 3 ? " 等 \(conflicts.count) 项" : "")将被替换。"
            alert.addButton(withTitle: "替换")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        // ponytail: 主线程同步执行 zip，大文件加入时会短暂卡顿；需要时挪到后台并显示进度
        do {
            try ZipArchive.add(urls, to: zip, inner: inner)
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法加入「\(zip.lastPathComponent)」"
            alert.informativeText = "\(error.localizedDescription)"
            alert.runModal()
        }
    }

    /// 生成不冲突的副本名（"xxx 副本"、"xxx 副本 2"...）
    private func nextAvailableName(for url: URL, in destination: URL) -> URL {
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        func name(_ suffix: String) -> String { ext.isEmpty ? "\(base) \(suffix)" : "\(base) \(suffix).\(ext)" }
        var candidate = destination.appendingPathComponent(name("副本"))
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = destination.appendingPathComponent(name("副本 \(n)"))
            n += 1
        }
        return candidate
    }

    /// 验证文件名是否合法（macOS 文件名仅禁 "/": 和 "." ".."）
    func isValidFileName(_ name: String) -> Bool {
        !name.isEmpty
            && !name.contains("/")
            && !name.contains(":")
            && name != "."
            && name != ".."
    }
}
