import SwiftUI
import AppKit

/// 关于窗口
struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 80, height: 80)

            Text("BitXplore")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 6) {
                Text("版本 \(AppVersion.marketing) (Build \(AppVersion.build))")
                Text("需 macOS 27.0 或更高版本")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                Link("Nonnika.Y", destination: URL(string: "https://github.com/Nonnika?tab=overview")!)
                Text("·").foregroundStyle(.secondary)
                Link("项目主页", destination: URL(string: "https://github.com/Nonnika/BitXplorer")!)
            }
            .font(.callout)
        }
        .padding(28)
        .frame(width: 340)
    }
}

extension FocusedValues {
    /// 主窗口为 key 时提供其是否处于双栏，用于区分 ⌘W 关栏还是关窗口
    @Entry var mainWindowIsDualPane: Bool?
}

@main
struct BitXploreApp: App {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.mainWindowIsDualPane) private var mainWindowIsDualPane

    @State private var sidebarRoots: [TreeNode] = TreeNode.defaultRoots()
    /// 双栏模式（⌘D）：panes[1] 仅在开启时显示；菜单命令作用于 activePane
    @State private var panes = [Pane(), Pane()]
    @State private var activePane = 0
    @State private var isDualPane = false
    @State private var splitFraction: CGFloat = 0.5
    @State private var searchFocusTrigger = 0
    @State private var paletteTrigger = 0
    @State private var clipboardURLs: [URL] = []
    @State private var clipboardIsCut = false
    @State private var showHiddenFiles = false
    /// App 级操作（粘贴/废纸篓）完成后 +1，MainContentView 监听后重载列表
    @State private var refreshTick = 0
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    private let fsService = FileSystemService()

    private var active: Pane {
        get { panes[activePane] }
        nonmutating set { panes[activePane] = newValue }
    }

    private func toggleDualPane() {
        if isDualPane {
            isDualPane = false
            activePane = 0
        } else {
            // 新开的右栏从当前目录出发
            panes[1].navigate(to: panes[0].currentURL)
            isDualPane = true
            activePane = 1
        }
    }

    /// ⌘W：关闭活动栏，剩下的一栏归位到 panes[0]
    private func closeActivePane() {
        if activePane == 0 { panes[0] = panes[1] }
        isDualPane = false
        activePane = 0
    }

    /// 粘贴：剪切则移动（执行后清空），复制则保留（可多次粘贴）；取消时保留剪贴板
    private func paste() {
        guard !clipboardURLs.isEmpty else { return }
        let executed = fsService.pasteItems(clipboardURLs, to: active.currentURL, isCut: clipboardIsCut)
        if clipboardIsCut && executed {
            clipboardURLs = []
            clipboardIsCut = false
        }
        refreshTick += 1
    }

    private func setAppIcon() {
        guard let bundleURL = Bundle.main.url(forResource: "BitXplore_BitXplore", withExtension: "bundle"),
              let bundle = Bundle(url: bundleURL) else {
            print("[BitXplore] 未找到资源 bundle")
            return
        }
        guard let icnsURL = bundle.url(forResource: "AppIcon", withExtension: "icns") else {
            print("[BitXplore] 未找到 AppIcon.icns")
            return
        }
        let icon = NSImage(contentsOf: icnsURL)
        NSApp.applicationIconImage = icon
        print("[BitXplore] 图标已设置")
    }

    var body: some Scene {
        Window("BitXplore", id: "main") {
            NavigationSplitView {
                SidebarTreeView(
                    roots: sidebarRoots,
                    currentURL: $panes[activePane].currentURL,
                    onSelect: { url in
                        // 只改 currentURL，列表加载统一由 PaneView.onChange 触发
                        active.navigate(to: url)
                    }
                )
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
            } detail: {
                MainContentView(
                    panes: $panes,
                    activePane: $activePane,
                    isDualPane: isDualPane,
                    splitFraction: $splitFraction,
                    searchFocusTrigger: searchFocusTrigger,
                    paletteTrigger: paletteTrigger,
                    clipboardURLs: $clipboardURLs,
                    clipboardIsCut: $clipboardIsCut,
                    showHiddenFiles: $showHiddenFiles,
                    fsService: fsService,
                    refreshTick: refreshTick,
                    onNewFolder: { active.newFolderTrigger += 1 }
                )
            }
            .navigationSplitViewStyle(.balanced)
            .focusedSceneValue(\.mainWindowIsDualPane, isDualPane)
            .frame(minWidth: 800, minHeight: 500)
            .onAppear {
                setAppIcon()
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                // 首次启动弹出授权引导（唯一持久化的用户状态）
                if !hasSeenOnboarding {
                    hasSeenOnboarding = true
                    openWindow(id: "onboarding")
                }
            }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1100, height: 700)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于 BitXplore") {
                    openWindow(id: "about")
                }
            }

            CommandGroup(replacing: .help) {
                Button("个人目录访问权限引导…") {
                    openWindow(id: "onboarding")
                }
            }

            // 替换系统「关闭」：双栏时 ⌘W 关当前栏，否则照常关窗口
            CommandGroup(replacing: .saveItem) {
                Button(mainWindowIsDualPane == true ? "关闭当前栏" : "关闭窗口") {
                    if mainWindowIsDualPane == true { closeActivePane() } else { NSApp.keyWindow?.performClose(nil) }
                }
                .keyboardShortcut("w", modifiers: .command)
            }

            CommandGroup(after: .newItem) {
                Button("新建文件夹") {
                    active.newFolderTrigger += 1
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            CommandGroup(after: .toolbar) {
                Button(showHiddenFiles ? "隐藏隐藏项目" : "显示隐藏项目") {
                    showHiddenFiles.toggle()
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])

                Button(isDualPane ? "关闭双栏视图" : "双栏视图") {
                    toggleDualPane()
                }
                .keyboardShortcut("d", modifiers: .command)

                Button("分隔条左移") {
                    withAnimation(.snappy) { splitFraction = MainContentView.clampSplit(splitFraction - 0.1) }
                }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!isDualPane)

                Button("分隔条右移") {
                    withAnimation(.snappy) { splitFraction = MainContentView.clampSplit(splitFraction + 0.1) }
                }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!isDualPane)

                Divider()

                Button("搜索") { searchFocusTrigger += 1 }
                    .keyboardShortcut("f", modifiers: .command)

                Button("命令面板…") { paletteTrigger += 1 }
                    .keyboardShortcut("p", modifiers: [.command, .option])
            }

            CommandMenu("前往") {
                Button("上一级目录") {
                    active.goUp()
                }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!active.canGoUp)

                Button("下一级目录") {
                    active.goDown()
                }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(!active.canGoDown)

                Divider()

                Button("前往文件夹…") {
                    active.isEditingPath = true
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            }

            CommandGroup(after: .pasteboard) {
                Button("复制") {
                    // zip 包内条目先解出，粘贴时才有真实文件可拷
                    clipboardURLs = active.selectedURLs.compactMap { try? fsService.materialize($0) }
                    clipboardIsCut = false
                }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(active.selectedURLs.isEmpty)

                Button("剪切") {
                    clipboardURLs = Array(active.selectedURLs)
                    clipboardIsCut = true
                    active.selectedURLs = []
                }
                .keyboardShortcut("x", modifiers: .command)
                .disabled(active.selectedURLs.isEmpty || ZipArchive.split(active.currentURL) != nil)

                Button("粘贴") {
                    paste()
                }
                .keyboardShortcut("v", modifiers: .command)
                .disabled(clipboardURLs.isEmpty)

                Divider()

                Button("重命名") {
                    active.renameTrigger += 1
                }
                .disabled(active.selectedURLs.count != 1)

                Button("移到废纸篓") {
                    fsService.moveToTrash(Array(active.selectedURLs))
                    refreshTick += 1
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(active.selectedURLs.isEmpty || ZipArchive.split(active.currentURL) != nil)
            }
        }

        Window("欢迎使用 BitXplore", id: "onboarding") {
            OnboardingView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("关于 BitXplore", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
