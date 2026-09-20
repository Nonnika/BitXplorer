import Foundation
import AppKit

/// 文件系统服务 - 负责读取目录内容
/// 无状态，仅为让后台线程调用通过 Swift 6 严格并发检查
final class FileSystemService: @unchecked Sendable {

    /// 读取指定路径下的文件列表（同步、可重入，调用方负责放后台线程）
    func listDirectory(at url: URL, showHidden: Bool = false) throws -> [FileItem] {
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
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
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

    /// 在 Finder 中显示
    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
    }

    /// 在 Finder 中打开文件夹
    func openInFinder(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// 用默认应用打开文件
    func openFile(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// 复制路径到剪贴板
    func copyPath(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.path, forType: .string)
    }

    /// 新建文件夹
    func createFolder(at url: URL, name: String) throws -> URL {
        let newURL = url.appendingPathComponent(name)
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
