import Foundation

/// 单个文件面板的状态（双栏模式下每栏一份）— 含「上一级/下一级」目录层级导航
struct Pane {
    var currentURL = URL(fileURLWithPath: NSHomeDirectory())
    var files: [FileItem] = []
    var selectedURLs: Set<URL> = []
    var searchText = ""
    var isEditingPath = false
    /// 菜单命令递增，仅作用于当前活动面板
    var newFolderTrigger = 0
    var renameTrigger = 0

    /// 「上一级」离开的目录栈，供「下一级」原路返回
    private var downStack: [URL] = []

    var canGoUp: Bool { currentURL.path != "/" }
    var canGoDown: Bool { !downStack.isEmpty }

    /// 上一级：返回父目录并记住出发目录
    mutating func goUp() {
        guard canGoUp else { return }
        downStack.append(currentURL)
        currentURL = currentURL.deletingLastPathComponent()
    }

    /// 下一级：回到最近一次「上一级」离开的目录
    mutating func goDown() {
        if let url = downStack.popLast() { currentURL = url }
    }

    /// 其它导航（双击/面包屑/边栏）作废下级栈，与浏览器前进栈同语义
    mutating func navigate(to url: URL) {
        downStack.removeAll()
        currentURL = url
    }
}
