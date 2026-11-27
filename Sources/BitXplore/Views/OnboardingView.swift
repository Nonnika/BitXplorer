import SwiftUI
import AppKit

/// 首次启动引导：用抽象动画说明并引导授予「完全磁盘访问权限」，覆盖整个个人目录
/// （文稿/桌面/下载、iCloud、其他 App 数据等受 TCC 保护的位置）
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var granted = OnboardingView.hasFullDiskAccess()

    /// 完全磁盘访问没有系统弹窗、也无查询 API；惯用探测：只有获授权的进程才能打开 TCC 数据库，
    /// 打开失败不会触发任何提示
    static func hasFullDiskAccess() -> Bool {
        let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    var body: some View {
        VStack(spacing: 20) {
            AccessAnimation(granted: granted)
                .frame(height: 220)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(granted ? "已可访问整个个人目录" : "让 BitXplore 访问你的个人目录")
                    .font(.title2.bold())
                Text(granted
                     ? "BitXplore 现在可以浏览个人目录下的所有文件夹。"
                     : "macOS 会保护个人目录中的「文稿」「桌面」「下载」等位置。请在系统设置的「完全磁盘访问权限」中打开 BitXplore（列表里没有时点 + 添加，或把 Finder 中选中的 BitXplore 拖进去）。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Label("个人目录  ~/", systemImage: "house")
                Spacer()
                if granted {
                    Label("已允许", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Text("未允许").foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))

            if !granted {
                Text("打开后若仍显示未允许，按系统提示「退出并重新打开」BitXplore 即可。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                if !granted {
                    Button("稍后") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                Spacer()
                if granted {
                    Button("开始使用") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("打开系统设置", action: openSettings)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(28)
        .frame(width: 460)
        // 用户在系统设置里勾选后自动变绿；未授权时每秒探测一次，开销只是一次 open()
        .task {
            while !granted, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let now = Self.hasFullDiskAccess()
                if now { withAnimation(.snappy) { granted = true } }
            }
        }
    }

    private func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
        // 在 Finder 中选中自身，方便直接拖进授权列表
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }
}

/// 抽象动画：中心方块代表 App，外环代表个人目录，环上节点代表其中的文件夹。
/// 未授权：节点灰色、连线静止、外环虚线缓慢旋转并有脉冲在“试探”；
/// 已授权：外环闭合变绿，连线上虚线流动（数据流）。减少动态效果时静止
private struct AccessAnimation: View {
    let granted: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Canvas { g, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let tint: Color = granted ? .green : .accentColor
                let nodeColor: Color = granted ? .green : .gray
                let ring: CGFloat = 92
                func circle(_ p: CGPoint, _ r: CGFloat) -> Path {
                    Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
                }

                // 脉冲：从 App 向外扩散到个人目录外环
                for i in 0..<3 {
                    let p = (t / 3 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                    g.stroke(circle(c, 34 + p * (ring - 34)), with: .color(tint.opacity((1 - p) * 0.3)), lineWidth: 1.5)
                }

                // 外环 = 个人目录：未授权为旋转虚线，授权后闭合
                g.stroke(circle(c, ring), with: .color(tint.opacity(granted ? 0.55 : 0.35)),
                         style: StrokeStyle(lineWidth: 2, dash: granted ? [] : [6, 8], dashPhase: t * 10))

                // 节点 = 个人目录中的文件夹
                let count = 6
                for i in 0..<count {
                    let angle = Double(i) / Double(count) * 2 * .pi - .pi / 2 + t * 0.15
                    let p = CGPoint(x: c.x + cos(angle) * ring, y: c.y + sin(angle) * ring)

                    var line = Path()
                    line.move(to: c)
                    line.addLine(to: p)
                    g.stroke(line, with: .color(nodeColor.opacity(granted ? 0.6 : 0.3)),
                             style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [3, 7],
                                                dashPhase: granted ? -t * 24 : 0))

                    let breathe = granted ? 0 : (sin(t * 2 + Double(i)) + 1) * 2
                    g.fill(circle(p, 12 + breathe), with: .color(nodeColor.opacity(0.18)))
                    g.fill(circle(p, 8), with: .color(nodeColor))
                }

                // 中心：App
                let box = CGRect(x: c.x - 26, y: c.y - 26, width: 52, height: 52)
                g.fill(Path(roundedRect: box, cornerRadius: 14),
                       with: .linearGradient(Gradient(colors: [.accentColor.opacity(0.75), .accentColor]),
                                             startPoint: CGPoint(x: box.minX, y: box.minY),
                                             endPoint: CGPoint(x: box.maxX, y: box.maxY)))
            }
        }
    }
}
