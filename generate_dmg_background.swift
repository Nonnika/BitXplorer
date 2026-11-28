import Cocoa

/// 生成 dmg 安装窗口背景：`swift generate_dmg_background.swift <输出目录>`，得到 background.png（1x）与 background@2x.png。
/// 尺寸与图标位置须与 package_app.sh 的 Finder 布局一致：窗口 660×400，图标中心 (170, 190) 与 (490, 190)
let size = NSSize(width: 660, height: 400)
let appCenterX: CGFloat = 170, applicationsCenterX: CGFloat = 490, iconCenterY: CGFloat = 190

func render(scale: Int, to url: URL) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size  // 点尺寸不变、像素翻倍 → 写出 144 dpi，tiffutil 据此识别 Retina 版
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    // 翻转成左上为原点，与 Finder 图标坐标一致
    context.cgContext.translateBy(x: 0, y: size.height)
    context.cgContext.scaleBy(x: 1, y: -1)

    // 底色：自上而下的浅灰蓝渐变
    NSGradient(starting: NSColor(srgbRed: 0.97, green: 0.98, blue: 1.0, alpha: 1),
               ending: NSColor(srgbRed: 0.88, green: 0.92, blue: 0.97, alpha: 1))!
        .draw(in: NSRect(origin: .zero, size: size), angle: 90)

    // 两团柔和光晕，呼应图标的蓝色
    for (center, radius, color) in [
        (NSPoint(x: 90, y: 40), 260.0, NSColor(srgbRed: 0.36, green: 0.62, blue: 1.0, alpha: 0.20)),
        (NSPoint(x: 600, y: 380), 300.0, NSColor(srgbRed: 0.55, green: 0.45, blue: 1.0, alpha: 0.14)),
    ] {
        NSGradient(starting: color, ending: color.withAlphaComponent(0))!
            .draw(fromCenter: center, radius: 0, toCenter: center, radius: radius, options: [])
    }

    // 中间的箭头：从应用指向「应用程序」
    let blue = NSColor(srgbRed: 0.23, green: 0.51, blue: 0.96, alpha: 0.9)
    blue.setStroke()
    let startX = appCenterX + 92, endX = applicationsCenterX - 92
    let shaft = NSBezierPath()
    shaft.move(to: NSPoint(x: startX, y: iconCenterY))
    shaft.line(to: NSPoint(x: endX, y: iconCenterY))
    shaft.lineWidth = 5
    shaft.lineCapStyle = .round
    shaft.setLineDash([0.1, 13], count: 2, phase: 0)  // 圆点虚线
    shaft.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: endX - 16, y: iconCenterY - 16))
    head.line(to: NSPoint(x: endX, y: iconCenterY))
    head.line(to: NSPoint(x: endX - 16, y: iconCenterY + 16))
    head.lineWidth = 5
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    // 底部提示
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let hint = NSAttributedString(string: "将 BitXplore 拖到「应用程序」文件夹即可完成安装", attributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        .foregroundColor: NSColor(srgbRed: 0.35, green: 0.40, blue: 0.48, alpha: 1),
        .paragraphStyle: paragraph,
    ])
    // 文字绘制要求坐标系不翻转：临时翻回去画
    context.cgContext.saveGState()
    context.cgContext.translateBy(x: 0, y: size.height)
    context.cgContext.scaleBy(x: 1, y: -1)
    hint.draw(in: NSRect(x: 0, y: 46, width: size.width, height: 20))
    context.cgContext.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
render(scale: 1, to: dir.appendingPathComponent("background.png"))
render(scale: 2, to: dir.appendingPathComponent("background@2x.png"))
