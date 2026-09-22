import Foundation

/// 导航状态管理 — 「上一级/下一级」目录层级导航
@MainActor
final class NavigationState: ObservableObject {

    /// 「上一级」离开的目录栈，供「下一级」原路返回
    private var downStack: [URL] = []

    /// 上一级：返回父目录并记住出发目录；已在根目录时返回 nil
    func goUp(from current: URL) -> URL? {
        guard current.path != "/" else { return nil }
        downStack.append(current)
        return current.deletingLastPathComponent()
    }

    /// 下一级：回到最近一次「上一级」离开的目录
    func goDown() -> URL? {
        downStack.popLast()
    }

    func canGoUp(current: URL) -> Bool { current.path != "/" }
    func canGoDown() -> Bool { !downStack.isEmpty }

    /// 其它导航（双击/面包屑/边栏）作废下级栈，与浏览器前进栈同语义
    func invalidate() {
        downStack.removeAll()
    }
}
