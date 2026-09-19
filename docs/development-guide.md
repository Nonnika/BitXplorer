# FinderExplorer 开发流程指南

面向本仓库的日常开发文档：环境准备 → 构建运行 → 代码结构 → 规范 → 提交 → 发布。

> 与 `AGENTS.md` 的关系：`AGENTS.md` 是 AI 协作约束 + 关键事实速查；本文是可执行的操作手册。两者冲突时以本文的实测结论为准。

---

## 1. 环境要求

| 项 | 要求 | 说明 |
|---|---|---|
| 操作系统 | macOS 14.0+ | 实测 macOS 15.7 可用；`LSMinimumSystemVersion` 为 14.0 |
| 语言 | Swift 6.0 工具链 | `swift-tools-version: 6.0`，实际 6.1.2 编译通过 |
| 依赖 | 无第三方包 | 仅 Foundation / AppKit / SwiftUI |
| 构建（单架构） | Command Line Tools 即可 | `xcode-select -p` 指向 `/Library/Developer/CommandLineTools` |
| 构建（多架构 / 打包 dmg） | 需要完整 Xcode | 见下方常见问题 |

```bash
git clone https://github.com/Syrnaxei/DuoXplorer.git
cd DuoXplorer
swift build --disable-sandbox      # 首次全量编译约 60s
```

---

## 2. 日常开发循环

```
改代码 → swift build --disable-sandbox → 运行二进制手工验证 → git commit
```

### 2.1 快速构建 + 运行（推荐）

```bash
# 单架构（当前机器）Debug 构建，产物在 .build/<arch>-apple-macosx/debug/
swift build --disable-sandbox
open .build/arm64-apple-macosx/debug/FinderExplorer      # Intel 机器改为 x86_64-...
```

Debug 产物是裸可执行文件，没有 `.app` 外壳：图标、Dock 名称不完整，但全部功能可用（代码里显式调用了 `NSApp.setActivationPolicy(.regular)`）。

### 2.2 打包为 `.app` 后运行

需要真实图标 / 正确显示名 / 可拖拽安装时：

```bash
./package_app.sh          # 三架构 + 三个 dmg，并在仓库根目录留下可直接运行的 FinderExplorer.app
open ./FinderExplorer.app
```

`./build_and_run.sh` 走的是多架构 Debug 构建，但脚本内 `open` 的路径是 `.build/apple/Products/Release/`，与 Debug 产物路径不一致，且多架构构建依赖完整 Xcode。**日常开发用 2.1 的命令；发版用 `./package_app.sh`。**

### 2.3 产物路径速查

| 构建命令 | 产物路径 |
|---|---|
| `swift build --disable-sandbox` | `.build/arm64-apple-macosx/debug/FinderExplorer` |
| `swift build -c release --disable-sandbox --arch arm64` | `.build/arm64-apple-macosx/release/FinderExplorer` |
| `swift build -c release --disable-sandbox --arch x86_64` | `.build/x86_64-apple-macosx/release/FinderExplorer` |
| `swift build -c release --disable-sandbox --arch arm64 --arch x86_64` | `.build/apple/Products/Release/FinderExplorer`（Universal） |

打包输出（仓库根目录）：`FinderExplorer_<版本>-amd64.dmg` / `-arm64.dmg` / `-universal.dmg`。

### 2.4 手工回归清单

项目没有自动化测试，改动后按此清单点一遍（每条对应一个易碎路径）：

- [ ] 侧边栏树展开/折叠，选中节点后主区内容跟随
- [ ] 地址栏点击变输入框 → 输入 `~/Downloads` → Enter 导航；Esc 取消
- [ ] 前进 / 后退 / 上一层 三个工具栏按钮，含边界（根目录 `/` 时「上一层」应置灰）
- [ ] 列头点击切换排序字段与方向
- [ ] 单选 / ⌘ 多选 / ⇧ 范围多选，状态栏计数与总大小
- [ ] ⌘C → 连续粘贴到两个目录；⌘X → 粘贴后剪贴板清空、半透明样式消失
- [ ] 同名冲突弹窗的三个分支：替换 / 保留两者（生成「xxx 副本」）/ 跳过
- [ ] ⌘⇧. 切换隐藏文件
- [ ] F2 内联重命名 + 非法文件名（含 `/ : * ? " < > |`）被拒绝
- [ ] 新建文件夹后自动选中
- [ ] 删除确认弹窗 → 移到废纸篓；取消时不删
- [ ] 在外部（Finder/终端）增删文件，列表自动刷新
- [ ] 「关于」窗口版本号与 `AppVersion.swift` 一致

---

## 3. 代码结构

```
Package.swift                    # SPM 可执行目标；资源只声明了 AppIcon.icns
build_and_run.sh                 # 多架构 Debug 构建 + 启动（路径有坑，见 2.2）
package_app.sh                   # 生成 Info.plist、组装 .app、打三个 dmg
generate_icon.swift              # 用代码生成 AppIcon.icns
Sources/FinderExplorer/
├── AppVersion.swift             # 版本号唯一真源（marketing + build）
├── FinderExplorerApp.swift      # @main 入口：全局状态、菜单命令、关于窗口、图标注入
├── Models/
│   ├── FileItem.swift           # 文件模型（URL 派生属性、格式化展示）
│   ├── SortOptions.swift        # SortOption / SortDirection
│   └── TreeNode.swift           # 侧边栏节点，@Published children 异步懒加载
├── Services/
│   ├── FileSystemService.swift  # 全部文件操作：列目录/新建/重命名/粘贴/废纸篓/reveal/剪贴板路径
│   └── NavigationState.swift    # 前进/后退双栈
└── Views/
    ├── MainContentView.swift    # 组合面包屑 + 搜索 + 列表 + 状态栏；持有目录 watcher
    ├── BreadcrumbBar.swift      # 可编辑地址栏
    ├── FileListView.swift       # 表格 + 右键菜单 + 内联重命名 + NSEvent 键盘监听（最大文件）
    └── SidebarTreeView.swift    # 目录树
```

### 3.1 状态流向（改 UI 前必读）

单一 `Window` 场景，**没有全局 store**。所有应用级状态是 `FinderExplorerApp` 的 `@State`，通过 `@Binding` 逐层下传；`MainContentView` 再传给 `FileListView`：

```
FinderExplorerApp (@State currentURL/files/selectedURLs/clipboard…/showHiddenFiles)
   ├─ SidebarTreeView      —— 回调 onSelect：push 历史 + 改 currentURL + 重新列目录
   └─ MainContentView      —— 持有 watcher / 搜索词 / 重命名与新建的局部 @State
        ├─ BreadcrumbBar   —— onNavigate 回调
        └─ FileListView    —— 排序、点击、键盘、右键菜单
```

新增一个跨视图状态：在 `FinderExplorerApp` 加 `@State` → 加 `@Binding` → 菜单里用 `.commands` 注册快捷键。新增纯视图内状态：用 `@State`，不要污染顶层。

### 3.2 关键实现约定

- `@MainActor` 标注所有 `ObservableObject`（`TreeNode`、`NavigationState`），UI 更新不跨线程。
- 文件操作一律走 `FileSystemService`，不要在 View 里重复实现 CRUD / 废纸篓 / reveal / 复制路径。
- 目录监听复用 `MainContentView.startWatcher()` 的 `DispatchSource.makeFileSystemObjectSource` + `open(path, O_EVTONLY)` 模式；取消时 `close(fd)`。
- 图标：通用 UI 用 SF Symbols，真实文件图标用 `NSWorkspace.shared.icon(forFile:)`。
- `FileItem` 的 `Equatable` 只比 `url`，`id` 是每次构造的 `UUID` —— 依赖 URL 语义，不要用 `id` 做跨刷新匹配。
- 有意为之的简化（性能天花板、naive 启发式）用 `// ponytail: <ceiling> / <upgrade path>` 注释标出。

---

## 4. 版本号管理

`Sources/FinderExplorer/AppVersion.swift` 是唯一真源：

```swift
enum AppVersion {
    static let marketing = "1.2.0"   // → CFBundleShortVersionString
    static let build = "5"           // → CFBundleVersion
}
```

发版时**只改这两行**：窗口标题、关于窗口、`Info.plist`（`package_app.sh` 用 grep 读取）、dmg 文件名都会同步。任何其他位置都不许硬编码版本号。

---

## 5. 提交规范

```
<type>: <short description>

<optional body>
```

- `type` ∈ `feat` / `fix` / `refactor` / `docs` / `test` / `chore`（历史里也用过 `build:`，构建/打包类改动可用）。
- 不加 emoji，正文简洁专业。
- **提交信息用英文；README、Release Notes 等用户可见文案用中文。**
- 一次提交只做一件事；`docs:` 与功能改动分开。

推荐分支模型（当前仓库只有 `main`，无 CI、无 tag 保护）：

```bash
git checkout -b feat/<short-topic>     # 从 main 切出
# ...开发 + 2.4 手工回归...
git commit
git push -u origin feat/<short-topic>  # 提 PR，由维护者合并回 main
```

`.gitignore` 已忽略 `.build/`、`*.app/`、`.DS_Store`。注意 **`.dmg` 未被忽略**，`git add .` 前先看 `git status`，别把打包产物提交进去。

---

## 6. 发布流程

1. 在 `AppVersion.swift` 递增 `marketing`（功能/破坏性变更）或 `build`（修复重打包）。
2. 全量手工回归（2.4），至少跑过一次 `./package_app.sh`。
3. 提交版本号变更，合并到 `main`：`git commit -m "chore: bump version to 1.2.1"`。
4. 打 tag 并推送：

   ```bash
   git tag 1.2.1
   git push origin main 1.2.1
   ```

5. 创建 Release，上传三个 dmg（`-amd64` / `-arm64` / `-universal`），Release Notes 用中文，并提示「不确定芯片选 universal」。
6. 同步更新 `README.md` 的下载表格与版本号链接。

---

## 7. 常见问题

**`error: xcbuild executable at '.../xcbuild' does not exist or is not executable`**
出现于 `--arch arm64 --arch x86_64` 或 `./package_app.sh`。原因：多架构构建走 xcbuild，只装 Command Line Tools 时不存在。解决（需要管理员权限）：

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

发完版如需回到 CLT 工具链：`sudo xcode-select -s /Library/Developer/CommandLineTools`。

**构建报 sandbox 相关错误 / 无法访问 `~/Documents`**
所有 `swift build` 都带 `--disable-sandbox`；本项目会读写用户真实文件系统，SPM 沙箱会拦。

**在 Xcode 里打开**
`open Package.swift` 即以 SwiftPM 工程方式打开，可直接 ⌘R 运行 `FinderExplorer` scheme。不要用它生成 `.xcodeproj` 提交回仓库（已被 `.gitignore` 忽略）。

**双击 dmg 里的 App 提示无法打开 / 未验证**
`package_app.sh` 不做签名与公证。本地自用：右键 → 打开，或 `xattr -dr com.apple.quarantine /Applications/FinderExplorer.app`。对外分发需要补 codesign + notarytool。

**运行 Debug 二进制看不到窗口**
确认真实产物架构目录（`uname -m` → `arm64` 或 `x86_64`），用 `open` 而非直接执行路径更稳；也可先 `./package_app.sh` 再用 `.app`。

**图标没生效**
Debug 裸二进制没有 bundle。图标来自 `package_app.sh` 组装的 `Contents/Resources/AppIcon.icns`，运行时再由 `setAppIcon()` 从 `FinderExplorer_FinderExplorer.bundle` 读取。

重新生成 `AppIcon.icns`（`generate_icon.swift` 只产出 iconset 里的 PNG，需 `iconutil` 转换；目录必须以 `.iconset` 结尾）：

```bash
rm -rf AppIcon.iconset
swift generate_icon.swift AppIcon.iconset
iconutil -c icns AppIcon.iconset -o AppIcon.icns
rm -rf AppIcon.iconset
```

---

## 8. 测试现状与补测建议

当前 `Package.swift` 只有 `executableTarget`，**没有测试 target**，非平凡逻辑靠手工回归。

若要补测，最小改动：把可测逻辑保持在 `FileSystemService` / `Models`（这两个目录不依赖 `NSWindow`，`moveToTrash`、`pasteItems` 例外——它们弹 `NSAlert`），然后新增 `.testTarget` 与 `Tests/FinderExplorerTests/`。优先覆盖：`isValidFileName`、`nextAvailableName` 的副本命名序列、`NavigationState` 的双栈行为（push 清空 forward、goBack/goForward 对称）、排序比较器。
