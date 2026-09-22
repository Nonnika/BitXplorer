# BitXplore

一个用 SwiftUI 构建的 macOS 文件管理器，风格类似 Finder，支持树形侧边栏、面包屑导航、多选、内联重命名等功能。

开发流程（环境准备、日常构建、代码规范、发布与升级）见 [docs/development-guide.md](docs/development-guide.md)。

## 截图

![主界面](assets/screenshot-main.png)

## 相比访达（Finder）的优势

| | Finder | BitXplore |
|---|---|---|
| **地址栏** | 右键 Option 才能看到路径，复制不方便 | 点击空白即切换为可编辑路径，自动全选，一键复制 |
| **目录树** | 侧边栏仅收藏夹，无完整目录树 | 完整目录树，根节点直达 /、/Users、/Applications |
| **排序** | 分组 + 排序混合，不可按列头切换 | 四列表格，点击列头一键切换排序方向和字段 |
| **键盘操作** | 仅 Enter 打开、Space 预览 | 全键盘：↑↓ 导航、Enter 打开、Backspace 返回上级、F2 重命名 |
| **多列信息** | 需切换为列表视图，且不显示类型 | 名称、日期、类型、大小四列同时可见 |
| **右键菜单** | 服务菜单分散、无废纸篓 | 集中管理：打开、重命名、Finder 中显示、复制路径、废纸篓 |
| **目录刷新** | 有时不自动刷新 | 文件系统事件驱动，自动刷新 |
| **跨平台潜力** | macOS 专属 | SwiftUI 跨平台架构，未来可移植 |

## 功能

- **侧边栏目录树** — 异步加载，支持展开/折叠子文件夹
- **可编辑地址栏** — 点击空白区域切换为文本输入，自动全选，支持复制/粘贴路径，Enter 导航、Esc 取消
- **文件列表** — 名称/修改日期/类型/大小四列，支持点击列头排序
- **搜索过滤** — 实时搜索当前目录下的文件
- **右键菜单** — 打开、重命名、在 Finder 中显示、复制路径、移到废纸篓
- **键盘导航** — 上下箭头选择、回车打开、Backspace 返回上级、F2 重命名
- **多选** — ⌘ Command 追加 / ⇧ Shift 范围选择
- **内联重命名** — 在列表中直接编辑文件名
- **新建文件夹** — 快捷创建并自动选中
- **复制/剪切/粘贴** — ⌘C 复制 / ⌘X 剪切 / ⌘V 粘贴，行为与 Windows 一致：复制可连续粘贴到多个目录，剪切粘贴后清空；同名自动加「副本」后缀；被剪切的文件半透明显示
- **隐藏文件切换** — ⌘⇧. 快捷键（与系统通用快捷键一致）或右键菜单切换
- **删除确认** — 移到废纸篓前弹窗确认，防止误删
- **地址栏支持~** — 输入 `~/Downloads` 等路径自动展开为用户主目录
- **前进/后退** — 导航历史栈，工具栏按钮操作
- **废纸篓** — 菜单命令 + ⌫ Delete 快捷键
- **目录自动刷新** — 外部文件新增/删除时列表自动更新
- **关于窗口** — 显示版本号、作者和项目主页链接
- **版本管理** — AppVersion.swift 统一版本号（发版时手动递增），窗口标题和打包产物自动同步

## 系统

- macOS 14.0 (Sonoma) 或更高版本

## 构建 & 运行

### 方式一：构建并启动（推荐）

```bash
./build_and_run.sh
```

增量编译本机架构的 Debug 产物并重启应用，改完代码敲一次即可看到效果。

### 方式二：手动构建

```bash
swift build --disable-sandbox
open "$(swift build --disable-sandbox --show-bin-path)/BitXplore"
```

产物在 `.build/<arch>-apple-macosx/debug/BitXplore`（Apple Silicon 为 `arm64-…`，Intel 为 `x86_64-…`），用 `--show-bin-path` 取路径可免手写架构名。

### 方式三：Xcode（需要断点调试时）

```bash
open Package.swift        # 以 SwiftPM 工程打开，scheme 选 BitXplore 后 ⌘R
```

> 必须带 `--disable-sandbox`：应用读写真实文件系统，SPM 沙箱会拦截。Debug 裸二进制没有 `.app` 外壳，Dock 图标与应用名称不完整，功能不受影响。

## 打包为 dmg

```bash
./package_app.sh
```

脚本构建 x86_64 / arm64 / Universal 三个架构，并打包成 dmg 安装镜像（内含 Applications 快捷方式，拖拽即装），**产物统一输出到 `build/`**（已被 `.gitignore` 忽略）：

```
build/BitXplore_<版本>-amd64.dmg
build/BitXplore_<版本>-arm64.dmg
build/BitXplore_<版本>-universal.dmg
```

同时在 `build/BitXplore.app` 保留一份 Universal 版本可直接运行。版本号从 `Sources/BitXplore/AppVersion.swift` 读取 —— 该文件是版本号的唯一真源，**发版前需手动递增**（`marketing` + `build`），仓库无 CI、不会自动加号。

> 多架构构建需要完整的 Xcode（不止 Command Line Tools）。若报 `xcbuild executable ... does not exist`，先执行 `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`。

升级已安装的旧版本：退出应用 → 双击新 dmg → 把 app 拖入 Applications → 选「替换」。bundle id 固定为 `top.struct.bitxplore`，且应用不保存任何用户数据，覆盖即完成升级。


## 项目结构

```
BitXplore/
├── Package.swift                 # Swift Package Manager 配置
├── build_and_run.sh              # Debug 增量构建 + 重启应用
├── package_app.sh                # Release 打包 dmg（三架构，输出至 build/）
├── generate_icon.swift           # 用代码生成 App 图标
├── build/                        # 打包产物（dmg / .app，不入库）
├── docs/
│   └── development-guide.md      # 开发流程：环境、构建、规范、发布、升级
└── Sources/BitXplore/
    ├── AppVersion.swift          # 版本号定义
    ├── BitXploreApp.swift   # 入口 + 主窗口
    ├── Models/
    │   ├── FileItem.swift        # 文件/文件夹数据模型
    │   ├── SortOptions.swift     # 排序选项与方向
    │   └── TreeNode.swift        # 侧边栏树节点（异步）
    ├── Services/
    │   ├── FileSystemService.swift # 文件操作服务层
    │   └── NavigationState.swift   # 前进/后退导航栈
    └── Views/
        ├── MainContentView.swift  # 主区域整合
        ├── BreadcrumbBar.swift    # 面包屑地址栏
        ├── FileListView.swift     # 文件列表 + 右键菜单
        └── SidebarTreeView.swift  # 侧边栏目录树
```
## 许可

MIT
