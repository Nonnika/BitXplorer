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
                .font(.system(size: 18, weight: .bold))

            Text("版本 \(AppVersion.marketing) (Build \(AppVersion.build))")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            Text("一个基于 SwiftUI 的 macOS 文件管理器，\n支持面包屑导航、树形侧边栏、多选和键盘操作。\n本项目是 cnwutianhao/finder-explorer 的分支。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Text("需 macOS 27.0 或更高版本")
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            HStack(spacing: 4) {
                Link("Syrnaxei",
                     destination: URL(string: "https://github.com/Syrnaxei")!)
                    .font(.system(size: 10))
                    .foregroundColor(.accentColor)
                Text("·")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Link("项目主页",
                     destination: URL(string: "https://github.com/Nonnika/BitXplorer")!)
                    .font(.system(size: 10))
                    .foregroundColor(.accentColor)
            }

            Spacer().frame(height: 8)
        }
        .frame(width: 380, height: 340)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

@main
struct BitXploreApp: App {
    @StateObject private var navigationState = NavigationState()
    @State private var currentURL = URL(fileURLWithPath: "/Users/\(NSUserName())")
    @State private var files: [FileItem] = []
    @State private var selectedURLs: Set<URL> = []
    @State private var clipboardURLs: [URL] = []
    @State private var clipboardIsCut = false
    @State private var showHiddenFiles = false
    /// App 级操作（粘贴/废纸篓）完成后 +1，MainContentView 监听后重载列表
    @State private var refreshTick = 0

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

    @State private var aboutWindow: NSWindow?

    private func showAboutWindow() {
        // isReleasedWhenClosed = false，窗口对象常驻，直接复用避免每次新建泄漏
        if let existing = aboutWindow {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "关于 BitXplore"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AboutView())
        window.setContentSize(NSSize(width: 380, height: 340))
        window.center()
        window.makeKeyAndOrderFront(nil)
        aboutWindow = window
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
        // 标题留空：标题栏被面包屑 + 搜索占据，不再显示文字标题
        Window("", id: "main") {
            NavigationSplitView {
                SidebarTreeView(
                    roots: [
                        TreeNode(url: URL(fileURLWithPath: "/Users/\(NSUserName())"), name: "个人目录"),
                        TreeNode(url: URL(fileURLWithPath: "/Applications"), name: "应用程序"),
                        TreeNode(url: URL(fileURLWithPath: "/Users"), name: "用户"),
                        TreeNode(url: URL(fileURLWithPath: "/"), name: "Macintosh HD"),
                    ],
                    onSelect: { url in
                        // 只改 currentURL，列表加载统一由 MainContentView.onChange 触发
                        navigationState.invalidate()
                        currentURL = url
                    }
                )
                .frame(minWidth: 200)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
                // 边栏开关用系统自带的按钮（位置和 Liquid Glass 风格都是系统的，同 Finder）
            } detail: {
                MainContentView(
                    currentURL: $currentURL,
                    files: $files,
                    selectedURLs: $selectedURLs,
                    clipboardURLs: $clipboardURLs,
                    clipboardIsCut: $clipboardIsCut,
                    showHiddenFiles: $showHiddenFiles,
                    navigationState: navigationState,
                    fsService: fsService,
                    refreshTick: refreshTick
                )
            }
            .navigationSplitViewStyle(.balanced)
            .frame(minWidth: 800, minHeight: 500)
            .onAppear {
                setAppIcon()
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                requestFileAccessAtLaunch()
                // 标题栏透明 + 内容延伸到标题栏下方：滚动行钻进顶栏模糊带（MainContentView
                // 的 ToolbarBlurView）底下被窗内模糊
                if let window = NSApp.windows.first {
                    window.titlebarAppearsTransparent = true
                    window.styleMask.insert(.fullSizeContentView)
                }
                print("[BitXplore] 窗口已显示")
            }
        }
        .defaultSize(width: 1100, height: 700)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于 BitXplore") {
                    showAboutWindow()
                }
            }

            CommandGroup(after: .toolbar) {
                Button(showHiddenFiles ? "隐藏隐藏项目" : "显示隐藏项目") {
                    showHiddenFiles.toggle()
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])
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

                Button("移到废纸篓") {
                    fsService.moveToTrash(Array(selectedURLs))
                    refreshTick += 1
                }
                .keyboardShortcut(.delete, modifiers: [])
            }
        }
    }
}
