import SwiftUI
import AppKit

/// 关于窗口
struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 8)

            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 80, height: 80)

            Text("BitXplore")
                .font(.title2.bold())

            Text("版本 \(AppVersion.marketing) (Build \(AppVersion.build))")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("一个基于 SwiftUI 的 macOS 文件管理器，\n支持面包屑导航、树形侧边栏、多选和键盘操作。\n本项目是 cnwutianhao/finder-explorer 的分支。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Text("需 macOS 27.0 或更高版本")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                Link("Syrnaxei",
                     destination: URL(string: "https://github.com/Syrnaxei")!)
                    .font(.caption2)
                Text("·")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Link("项目主页",
                     destination: URL(string: "https://github.com/Nonnika/BitXplorer")!)
                    .font(.caption2)
            }

            Spacer().frame(height: 8)
        }
        .frame(width: 380, height: 340)
    }
}

@main
struct BitXploreApp: App {
    @Environment(\.openWindow) private var openWindow

    @StateObject private var navigationState = NavigationState()
    @State private var sidebarRoots: [TreeNode] = TreeNode.defaultRoots()
    @State private var currentURL = URL(fileURLWithPath: NSHomeDirectory())
    @State private var files: [FileItem] = []
    @State private var selectedURLs: Set<URL> = []
    @State private var clipboardURLs: [URL] = []
    @State private var clipboardIsCut = false
    @State private var showHiddenFiles = false
    /// App 级操作（粘贴/废纸篓）完成后 +1，MainContentView 监听后重载列表
    @State private var refreshTick = 0
    @State private var newFolderTrigger = 0
    @State private var renameTrigger = 0
    @State private var isEditingPath = false

    private let fsService = FileSystemService()

    /// 粘贴：剪切则移动（执行后清空），复制则保留（可多次粘贴）；取消时保留剪贴板
    private func paste() {
        guard !clipboardURLs.isEmpty else { return }
        let executed = fsService.pasteItems(clipboardURLs, to: currentURL, isCut: clipboardIsCut)
        if clipboardIsCut && executed {
            clipboardURLs = []
            clipboardIsCut = false
        }
        refreshTick += 1
    }

    /// 启动时主动触发系统对常用目录的文件访问授权（TCC），
    /// 避免首次进入「文档/桌面/下载」时才弹授权框打断操作
    private func requestFileAccessAtLaunch() {
        for name in ["Documents", "Desktop", "Downloads"] {
            _ = try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/\(name)")
        }
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
                    currentURL: $currentURL,
                    onSelect: { url in
                        // 只改 currentURL，列表加载统一由 MainContentView.onChange 触发
                        navigationState.invalidate()
                        currentURL = url
                    }
                )
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
            } detail: {
                MainContentView(
                    currentURL: $currentURL,
                    files: $files,
                    selectedURLs: $selectedURLs,
                    clipboardURLs: $clipboardURLs,
                    clipboardIsCut: $clipboardIsCut,
                    showHiddenFiles: $showHiddenFiles,
                    isEditingPath: $isEditingPath,
                    navigationState: navigationState,
                    fsService: fsService,
                    refreshTick: refreshTick,
                    newFolderTrigger: newFolderTrigger,
                    renameTrigger: renameTrigger,
                    onNewFolder: { newFolderTrigger += 1 }
                )
            }
            .navigationSplitViewStyle(.balanced)
            .frame(minWidth: 800, minHeight: 500)
            .onAppear {
                setAppIcon()
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                requestFileAccessAtLaunch()
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

            CommandGroup(after: .newItem) {
                Button("新建文件夹") {
                    newFolderTrigger += 1
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }

            CommandGroup(after: .toolbar) {
                Button(showHiddenFiles ? "隐藏隐藏项目" : "显示隐藏项目") {
                    showHiddenFiles.toggle()
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])
            }

            CommandMenu("前往") {
                Button("上一级目录") {
                    if let url = navigationState.goUp(from: currentURL) {
                        currentURL = url
                    }
                }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!navigationState.canGoUp(current: currentURL))

                Button("下一级目录") {
                    if let url = navigationState.goDown() {
                        currentURL = url
                    }
                }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(!navigationState.canGoDown())

                Divider()

                Button("前往文件夹…") {
                    isEditingPath = true
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            }

            CommandGroup(after: .pasteboard) {
                Button("复制") {
                    clipboardURLs = Array(selectedURLs)
                    clipboardIsCut = false
                }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(selectedURLs.isEmpty)

                Button("剪切") {
                    clipboardURLs = Array(selectedURLs)
                    clipboardIsCut = true
                    selectedURLs = []
                }
                .keyboardShortcut("x", modifiers: .command)
                .disabled(selectedURLs.isEmpty)

                Button("粘贴") {
                    paste()
                }
                .keyboardShortcut("v", modifiers: .command)
                .disabled(clipboardURLs.isEmpty)

                Divider()

                Button("重命名") {
                    renameTrigger += 1
                }
                .disabled(selectedURLs.count != 1)

                Button("移到废纸篓") {
                    fsService.moveToTrash(Array(selectedURLs))
                    refreshTick += 1
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(selectedURLs.isEmpty)
            }
        }

        Window("关于 BitXplore", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
