import Cocoa
import Foundation

/// 用代码生成 BitXplore 应用图标 — 极简原生 macOS 蓝色文件夹（Apple Files 风格）

func artworkFraction(for size: CGFloat) -> CGFloat {
    switch size {
    case ..<24: return 1.0
    case ..<48: return 0.94
    case ..<96: return 0.88
    default: return 0.824
    }
}

func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1.0) -> CGColor {
    CGColor(srgbRed: r / 255.0, green: g / 255.0, blue: b / 255.0, alpha: a)
}

func makeGradient(_ colors: [CGColor], locations: [CGFloat]) -> CGGradient {
    CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: colors as CFArray,
        locations: locations
    )!
}

func squirclePath(in rect: CGRect, exponent: CGFloat = 5.0, samples: Int = 180) -> CGPath {
    let path = CGMutablePath()
    let cx = rect.midX, cy = rect.midY
    let rx = rect.width / 2, ry = rect.height / 2
    let p = 2.0 / exponent
    for i in 0..<samples {
        let theta = 2.0 * CGFloat.pi * CGFloat(i) / CGFloat(samples)
        let cosT = cos(theta), sinT = sin(theta)
        let px = cx + rx * (cosT >= 0 ? 1 : -1) * pow(abs(cosT), p)
        let py = cy + ry * (sinT >= 0 ? 1 : -1) * pow(abs(sinT), p)
        if i == 0 { path.move(to: CGPoint(x: px, y: py)) }
        else { path.addLine(to: CGPoint(x: px, y: py)) }
    }
    path.closeSubpath()
    return path
}

func folderBackPath(x0: CGFloat, y0: CGFloat, A: CGFloat) -> CGPath {
    let left = x0 + 0.145 * A, right = x0 + 0.855 * A
    let bottom = y0 + 0.22 * A, shoulderY = y0 + 0.715 * A, tabTop = y0 + 0.79 * A
    let r = 0.052 * A
    let path = CGMutablePath()
    path.move(to: CGPoint(x: left + r, y: bottom))
    path.addLine(to: CGPoint(x: right - r, y: bottom))
    path.addQuadCurve(to: CGPoint(x: right, y: bottom + r), control: CGPoint(x: right, y: bottom))
    path.addLine(to: CGPoint(x: right, y: shoulderY - r))
    path.addQuadCurve(to: CGPoint(x: right - r, y: shoulderY), control: CGPoint(x: right, y: shoulderY))
    path.addLine(to: CGPoint(x: x0 + 0.46 * A, y: shoulderY))
    path.addCurve(to: CGPoint(x: x0 + 0.39 * A, y: tabTop),
                  control1: CGPoint(x: x0 + 0.425 * A, y: shoulderY),
                  control2: CGPoint(x: x0 + 0.42 * A, y: tabTop))
    path.addLine(to: CGPoint(x: left + r, y: tabTop))
    path.addQuadCurve(to: CGPoint(x: left, y: tabTop - r), control: CGPoint(x: left, y: tabTop))
    path.addLine(to: CGPoint(x: left, y: bottom + r))
    path.addQuadCurve(to: CGPoint(x: left + r, y: bottom), control: CGPoint(x: left, y: bottom))
    path.closeSubpath()
    return path
}

func generateAppIcon(size: CGFloat) -> NSBitmapImageRep {
    let pixelSize = Int(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixelSize, pixelsHigh: pixelSize,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: size, height: size)

    guard let nsCtx = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("无法创建位图图形上下文") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsCtx
    let ctx = nsCtx.cgContext
    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))

    let A = size * artworkFraction(for: size)
    let offset = (size - A) / 2
    let x0 = offset, y0 = offset
    let squircle = squirclePath(in: CGRect(x: x0, y: y0, width: A, height: A))

    // 1. 外投影 + 纯白微渐变圆角底板
    if size >= 64 {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.018), blur: size * 0.04, color: CGColor(gray: 0, alpha: 0.24))
        ctx.addPath(squircle)
        ctx.setFillColor(srgb(255, 255, 255))
        ctx.fillPath()
        ctx.restoreGState()
    }

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    let tileGrad = makeGradient([srgb(239, 243, 248), srgb(255, 255, 255)], locations: [0.0, 1.0])
    ctx.drawLinearGradient(tileGrad, start: CGPoint(x: x0, y: y0), end: CGPoint(x: x0, y: y0 + A), options: [])

    // 2. 蓝色文件夹主体（背板 + 前板，无多余装饰）
    let backPath = folderBackPath(x0: x0, y0: y0, A: A)
    if size >= 48 {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -0.016 * A), blur: 0.032 * A, color: srgb(12, 92, 168, 0.22))
        ctx.addPath(backPath)
        ctx.setFillColor(srgb(87, 193, 250))
        ctx.fillPath()
        ctx.restoreGState()
    }

    ctx.saveGState()
    ctx.addPath(backPath)
    ctx.clip()
    let backGrad = makeGradient([srgb(87, 193, 250), srgb(137, 218, 255)], locations: [0.0, 1.0])
    ctx.drawLinearGradient(backGrad, start: CGPoint(x: x0, y: y0 + 0.22 * A), end: CGPoint(x: x0, y: y0 + 0.79 * A), options: [])
    ctx.restoreGState()

    let frontRect = CGRect(x: x0 + 0.145 * A, y: y0 + 0.22 * A, width: 0.71 * A, height: 0.45 * A)
    let frontPath = CGPath(roundedRect: frontRect, cornerWidth: 0.055 * A, cornerHeight: 0.055 * A, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 0.006 * A), blur: 0.018 * A, color: srgb(14, 98, 178, 0.18))
    ctx.addPath(frontPath)
    ctx.setFillColor(srgb(74, 187, 249))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(frontPath)
    ctx.clip()
    let frontGrad = makeGradient([srgb(39, 157, 242), srgb(74, 187, 249), srgb(110, 208, 255)], locations: [0.0, 0.55, 1.0])
    ctx.drawLinearGradient(frontGrad, start: CGPoint(x: x0, y: frontRect.minY), end: CGPoint(x: x0, y: frontRect.maxY), options: [])

    let topSheen = makeGradient([CGColor(gray: 1, alpha: 0.0), CGColor(gray: 1, alpha: 0.35)], locations: [0.0, 1.0])
    ctx.drawLinearGradient(topSheen, start: CGPoint(x: x0, y: frontRect.maxY - frontRect.height * 0.06), end: CGPoint(x: x0, y: frontRect.maxY), options: [])
    ctx.restoreGState()

    // 3. Squircle 极细内描边，保持浅色背景下的边界清晰度
    ctx.addPath(squircle)
    ctx.setStrokeColor(srgb(15, 23, 42, 0.08))
    ctx.setLineWidth(max(1.0, 0.008 * A) * 2)
    ctx.strokePath()

    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let sizes: [(CGFloat, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]

guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: swift generate_icon.swift <output_dir>\n", stderr)
    exit(1)
}

let outputDir = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

for (size, name) in sizes {
    let rep = generateAppIcon(size: size)
    let pngData = rep.representation(using: .png, properties: [:])!
    try pngData.write(to: outputDir.appendingPathComponent("\(name).png"))
    print("Generated \(name).png (\(rep.pixelsWide)x\(rep.pixelsHigh))")
}
print("Done! All icons generated.")
