// generate-app-icon.swift
//
// IceShot 的 macOS 应用图标生成器。
//
// 用法（在仓库根目录执行）：
//   swift Scripts/generate-app-icon.swift                       # 生成全部图标资源
//   swift Scripts/generate-app-icon.swift --preview <目录>       # 额外输出各档尺寸预览，便于肉眼核对
//
// 设计：
// - 底板：蓝 → 靛 → 紫渐变、左上玻璃高光、底部体积、内描边、柔和投影。**底板不随图形改动**。
// - 图形：**截图卡 + 冰块**。卡片是「截图」语义（IceShot 是截图工具），冰块是品牌里的「冰」。
//   构图：卡片斜置在后，冰块压右下角，一半落在卡外才有前后层次。
// - 小尺寸（16 / 32）退化成剪影：只留「卡片 + 冰块」的轮廓，小图标反而更干净。
// - 按 macOS 图标网格绘制：1024 画布，824×824 连续圆角（squircle）底板，四周透明边距。
//
// 产物（全部由本脚本产出，彼此同源；**不要手放 PNG、不要只改其中一份**）：
//   AppIcon.appiconset        Release 图标
//   AppIconDev.appiconset     Debug 图标（叠加「测试版」胶囊）
//   BrandMark.imageset        应用内装饰标记
//   MenuBarIcon.imageset      菜单栏模板图
//
// Debug / Release 的 `ASSETCATALOG_COMPILER_APPICON_NAME` 是工程里的一次性设置，不在本脚本里改。

import AppKit
import SwiftUI

// MARK: - 配置

var arguments = Array(CommandLine.arguments.dropFirst())
var previewDir: URL?
if let previewIndex = arguments.firstIndex(of: "--preview"), previewIndex + 1 < arguments.count {
    previewDir = URL(fileURLWithPath: arguments[previewIndex + 1])
    arguments.removeSubrange(previewIndex...(previewIndex + 1))
}

let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assetsRoot = repoRoot.appendingPathComponent("IceShot/Assets.xcassets")

/// Release 图标
let iconSetDir = assetsRoot.appendingPathComponent("AppIcon.appiconset")

/// 应用内品牌标记（关于页 / 空态等）：单倍率图片集，尺寸固定
let brandMarkSetDir = assetsRoot.appendingPathComponent("BrandMark.imageset")
let brandMarkPixelSize = 512

/// 菜单栏模板图：无底板、单色，由系统按菜单栏外观着色
let menuBarIconSetDir = assetsRoot.appendingPathComponent("MenuBarIcon.imageset")
/// 菜单栏图标点数。16pt 与系统 SF Symbols 在菜单栏里的视觉大小一致
let menuBarIconPointSize = 16

/// 开发版（Debug）图标：与 App Icon 同图，叠一条「测试版」标签。
/// 作为 Debug 的 `ASSETCATALOG_COMPILER_APPICON_NAME`，Finder / Dock / 启动台
/// 在应用未运行时也能与正式版区分。
let devIconSetDir = assetsRoot.appendingPathComponent("AppIconDev.appiconset")

/// Asset Catalog 需要的全部尺寸（size, scale）
let variants: [(size: Int, scale: Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]

// MARK: - 品牌色

enum Brand {
    static let blue = Color(red: 0.231, green: 0.510, blue: 0.965)    // #3B82F6
    static let indigo = Color(red: 0.388, green: 0.400, blue: 0.945)  // #6366F1
    static let purple = Color(red: 0.659, green: 0.333, blue: 0.969)  // #A855F7
}

// MARK: - 尺寸度量（全部按画布比例推导，保证任何尺寸下比例一致）

struct IconMetrics {
    let canvas: CGFloat

    /// 16 / 32 / 64 等小尺寸：收紧边距、加粗笔画，去掉细节与阴影
    var isCompact: Bool { canvas <= 64 }

    /// 再小一档：16 / 32 只保留剪影，卡面与冰块面过渡全部省略
    var isTiny: Bool { canvas <= 32 }

    var inset: CGFloat { canvas * (isCompact ? 0.058 : 0.0977) }
    var body: CGFloat { canvas - inset * 2 }
    var cornerRadius: CGFloat { body * 0.2257 }

    var bodyShadow: (radius: CGFloat, y: CGFloat, opacity: Double) {
        isCompact
            ? (canvas * 0.010, canvas * 0.008, 0.24)
            : (canvas * 0.018, canvas * 0.016, 0.30)
    }

    var edgeLineWidth: CGFloat { max(1, canvas * (isCompact ? 0.0018 : 0.0029)) }

    // MARK: 图形（截图卡 + 冰块）

    /// 截图卡宽度占底板比例
    var cardWidthRatio: CGFloat { isCompact ? 0.62 : 0.66 }
    /// 卡片宽高比
    var cardAspect: CGFloat { 1.30 }
    /// 卡片倾斜角：略微歪一点，读起来是「拍到的一张图」而不是一个框
    var cardRotation: Double { -6 }

    /// 冰块尺寸占底板比例
    var iceSizeRatio: CGFloat { isCompact ? 0.32 : 0.28 }
    /// 冰块位置：压在卡片右下角，一半落在卡外，才有前后层次
    var iceOffset: (x: CGFloat, y: CGFloat) { (0.185, 0.165) }

    /// 冰块面的模糊半径（0 = 纯剪影）
    var iceFacetBlur: CGFloat { isCompact ? 0 : 0.07 }
}

// MARK: - 形状

/// 圆角等距六边形：等距立方体的剪影，转角吃进 `corner` 比例，得到圆润的冰块外形
struct IceBlockShape: Shape {
    var corner: CGFloat = 0.19

    func path(in rect: CGRect) -> Path {
        let centerX = rect.midX
        let centerY = rect.midY
        let radiusX = rect.width / 2
        let radiusY = rect.height / 2
        let points: [CGPoint] = [
            CGPoint(x: centerX, y: centerY - radiusY),
            CGPoint(x: centerX + radiusX, y: centerY - radiusY * 0.5),
            CGPoint(x: centerX + radiusX, y: centerY + radiusY * 0.5),
            CGPoint(x: centerX, y: centerY + radiusY),
            CGPoint(x: centerX - radiusX, y: centerY + radiusY * 0.5),
            CGPoint(x: centerX - radiusX, y: centerY - radiusY * 0.5),
        ]

        var path = Path()
        for index in points.indices {
            let current = points[index]
            let previous = points[(index + points.count - 1) % points.count]
            let next = points[(index + 1) % points.count]
            func lerp(_ from: CGPoint, _ to: CGPoint) -> CGPoint {
                CGPoint(x: from.x + (to.x - from.x) * corner,
                        y: from.y + (to.y - from.y) * corner)
            }
            let inPoint = lerp(current, previous)
            let outPoint = lerp(current, next)
            if index == 0 {
                path.move(to: inPoint)
            } else {
                path.addLine(to: inPoint)
            }
            path.addQuadCurve(to: outPoint, control: current)
        }
        path.closeSubpath()
        return path
    }
}

/// 立方体的三个面：顶 / 左 / 右。坐标按外接矩形比例推导，绘制后会被剪回圆角剪影
struct IceBlockFacet: Shape {
    enum Face {
        case top
        case left
        case right
    }

    let face: Face

    func path(in rect: CGRect) -> Path {
        let centerX = rect.midX
        let centerY = rect.midY
        let height = rect.height

        let apexTop = CGPoint(x: centerX, y: centerY - height * 0.5)
        let apexRight = CGPoint(x: rect.maxX, y: centerY - height * 0.24)
        let apexLeft = CGPoint(x: rect.minX, y: centerY - height * 0.24)
        let center = CGPoint(x: centerX, y: centerY - height * 0.02)
        let bottom = CGPoint(x: centerX, y: centerY + height * 0.5)
        let lowerRight = CGPoint(x: rect.maxX, y: centerY + height * 0.24)
        let lowerLeft = CGPoint(x: rect.minX, y: centerY + height * 0.24)

        var path = Path()
        switch face {
        case .top:
            path.addLines([apexTop, apexRight, center, apexLeft])
        case .left:
            path.addLines([apexLeft, center, bottom, lowerLeft])
        case .right:
            path.addLines([center, apexRight, lowerRight, bottom])
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - 图形

enum Mark: String {
    case shot  // 截图卡 + 冰块
}

/// 截图卡：斜置的圆角卡片 + 一道细描边。
/// 语义是「截下来的那一张图」，所以只在卡片上做加法，不加取景框（满屏角标在 16pt 会糊成虚线）。
struct ScreenshotCardGlyph: View {
    let canvas: CGFloat
    let metrics: IconMetrics
    var monochrome: Bool = false

    private var width: CGFloat { canvas * metrics.cardWidthRatio }
    private var height: CGFloat { width / metrics.cardAspect }
    private var ink: Color { monochrome ? .black : .white }

    /// 卡片填充：小尺寸下背景更透，要靠更实的卡片才看得出一层「图」
    private var fillTop: Double { metrics.isCompact ? 0.62 : 0.48 }
    private var fillBottom: Double { metrics.isCompact ? 0.36 : 0.18 }
    private var strokeOpacity: Double { metrics.isCompact ? 0.86 : 0.62 }
    private var strokeWidth: CGFloat { width * (metrics.isCompact ? 0.050 : 0.028) }

    var body: some View {
        RoundedRectangle(cornerRadius: width * 0.16, style: .continuous)
            .fill(LinearGradient(colors: [ink.opacity(fillTop), ink.opacity(fillBottom)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay {
                RoundedRectangle(cornerRadius: width * 0.16, style: .continuous)
                    .stroke(ink.opacity(strokeOpacity),
                            style: StrokeStyle(lineWidth: strokeWidth, lineJoin: .round))
            }
            .frame(width: width, height: height)
            .rotationEffect(.degrees(metrics.cardRotation))
            .shadow(color: .black.opacity(monochrome ? 0 : 0.10),
                    radius: canvas * 0.035,
                    y: canvas * 0.02)
    }
}

/// 柔面冰块：没有描边棱线，三个面之间靠轻微色差 + 模糊过渡表达体积。
/// `monochrome` 用于菜单栏模板图，只留 alpha。
struct IceBlockGlyph: View {
    let size: CGFloat
    let metrics: IconMetrics
    var monochrome: Bool = false

    private var silhouette: IceBlockShape { IceBlockShape(corner: 0.20) }

    private func tone(_ value: Double) -> Color {
        (monochrome ? Color.black : Color.white).opacity(value)
    }

    var body: some View {
        Group {
            if metrics.isCompact {
                // 16 / 32 / 64：三个面 + 过渡在这个尺寸下必糊，退化成剪影
                silhouette.fill(tone(0.92))
            } else {
                let blur = size * metrics.iceFacetBlur
                ZStack {
                    silhouette.fill(tone(0.72))
                    IceBlockFacet(face: .right).fill(tone(0.30)).blur(radius: blur)
                    IceBlockFacet(face: .top).fill(tone(0.99)).blur(radius: blur * 0.8)
                    silhouette.stroke(tone(0.88),
                                      style: StrokeStyle(lineWidth: size * 0.022, lineJoin: .round))
                }
                .compositingGroup()
                .mask(silhouette)
            }
        }
        .frame(width: size, height: size * 0.98)
        .shadow(color: .black.opacity(monochrome || metrics.isCompact ? 0 : 0.16),
                radius: size * 0.09,
                y: size * 0.045)
    }
}

// MARK: - 应用图标图形

/// 主图形：截图卡（斜置）+ 冰块（压右下角）。
///
/// 为什么是这个组合：卡片是「截图」语义，冰块是「冰」。
/// 冰块一半落在卡外，才有前后层次。
struct MarkArt: View {
    let metrics: IconMetrics
    let mark: Mark
    var monochrome: Bool = false

    var body: some View {
        let body = metrics.body
        return ZStack {
            ScreenshotCardGlyph(canvas: body, metrics: metrics, monochrome: monochrome)

            IceBlockGlyph(size: body * metrics.iceSizeRatio,
                          metrics: metrics,
                          monochrome: monochrome)
                .offset(x: body * metrics.iceOffset.x, y: body * metrics.iceOffset.y)
        }
    }
}

// MARK: - 绘制

struct AppIconArt: View {
    let metrics: IconMetrics
    let mark: Mark
    /// 整体图形上移量（画布比例）：开发版图标要让开底部的「测试版」胶囊
    var glyphLift: CGFloat = 0

    private var bodyShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
    }

    var body: some View {
        ZStack {
            background
            MarkArt(metrics: metrics, mark: mark)
                .frame(width: metrics.body, height: metrics.body)
                .compositingGroup()
                .offset(y: glyphLift)
        }
        .frame(width: metrics.canvas, height: metrics.canvas)
    }

    // 底板：渐变 + 左上玻璃高光 + 底部体积 + 内描边 + 投影
    private var background: some View {
        ZStack {
            bodyShape.fill(
                LinearGradient(
                    colors: [Brand.blue, Brand.indigo, Brand.purple],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            bodyShape.fill(
                RadialGradient(
                    colors: [.white.opacity(0.44), .white.opacity(0.07), .clear],
                    center: UnitPoint(x: 0.16, y: 0.04),
                    startRadius: 0,
                    endRadius: metrics.body * 1.0
                )
            )
            bodyShape.fill(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.16)],
                    startPoint: UnitPoint(x: 0.5, y: 0.55),
                    endPoint: .bottom
                )
            )
            bodyShape.strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(0.55), .white.opacity(0.05)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: metrics.edgeLineWidth
            )
        }
        .frame(width: metrics.body, height: metrics.body)
        .compositingGroup()
        .shadow(
            color: .black.opacity(metrics.bodyShadow.opacity),
            radius: metrics.bodyShadow.radius,
            x: 0,
            y: metrics.bodyShadow.y
        )
    }
}

// MARK: - 菜单栏图标（模板图）

/// 菜单栏图标：**独立设计**，不与 App 图标一致。
///
/// 作为**模板图（template）**使用：系统只取 alpha 通道并按菜单栏外观着色，
/// 因此这里统一用 `.black`（颜色本身无意义）；深浅色菜单栏下自动适配。
///
/// 取「实心截图卡 + 卡内镂空一块冰」：
/// - 16pt 下只有约 14×14 有效像素，**实心块**比描边扎实得多，空心描边会碎成虚线；
/// - 卡片是主体（截图工具语义），冰块挖成负形（品牌），两个形状互相咬合，不留空白；
/// - 为什么不是 App 图标的等比缩小：那张图靠渐变和前后层次，缩到 16pt 全糊。
struct MenuBarIconArt: View {
    let canvas: CGFloat

    var body: some View {
        let cardWidth = canvas * 0.94
        let cardHeight = cardWidth * 0.82
        let iceSize = cardWidth * 0.46
        return ZStack {
            RoundedRectangle(cornerRadius: cardWidth * 0.16, style: .continuous)
                .fill(.black)
                .frame(width: cardWidth, height: cardHeight)

            // 冰块挖空：模板图靠 alpha 负形表达形状
            IceBlockShape(corner: 0.26)
                .fill(.black)
                .frame(width: iceSize, height: iceSize * 0.98)
                .blendMode(.destinationOut)
        }
        .compositingGroup()
        .frame(width: canvas, height: canvas)
    }
}

// MARK: - 开发版图标

/// 开发版（Debug）图标：同一个 App Icon，底部叠一个「测试版」胶囊标签。
///
/// 目的不是好看，是**一眼能分出来**：开发机和正式版同时装在一台机器上时，
/// Dock 里两个图标必须不同，否则很容易点错。
struct DevIconArt: View {
    let canvas: CGFloat
    let mark: Mark

    private var metrics: IconMetrics { IconMetrics(canvas: canvas) }

    var body: some View {
        ZStack {
            AppIconArt(metrics: metrics, mark: mark, glyphLift: -canvas * 0.03)
            badge
        }
        .frame(width: canvas, height: canvas)
    }

    /// 胶囊标签：贴在底板底部，宽度不铺满，避免遮住图形主体。
    /// 小尺寸（16 / 32 / 64）下文字会糊成一团，只保留深色胶囊。
    private var badge: some View {
        let height = canvas * 0.125
        let width = metrics.body * 0.66
        let badgeColor = Color(red: 0.13, green: 0.11, blue: 0.26)

        // 用不透明的深靛色（而不是黑色半透明）：透出背后的图形会让白字在小尺寸下发脏
        return ZStack {
            Capsule().fill(badgeColor)
            if !metrics.isCompact {
                Text("测试版")
                    .font(.system(size: height * 0.62, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: width, height: height)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .offset(y: -metrics.inset - canvas * 0.045)
    }
}

// MARK: - 渲染

@MainActor
func renderPNG<Content: View>(_ content: Content, pixelSize: Int, to url: URL) throws {
    let renderer = ImageRenderer(content: content)
    // 先以 4 倍超采样渲染再降采样，得到干净的小尺寸边缘
    renderer.scale = 4
    renderer.isOpaque = false
    guard let master = renderer.cgImage,
          let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: nil,
            width: pixelSize,
            height: pixelSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else {
        throw NSError(domain: "AppIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "渲染失败"])
    }
    context.interpolationQuality = .high
    context.draw(master, in: CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
    guard let scaled = context.makeImage(),
          let data = NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:]) else {
        throw NSError(domain: "AppIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "编码失败"])
    }
    try data.write(to: url)
}

@MainActor
func renderAppIconPNG(mark: Mark, pixelSize: Int, to url: URL) throws {
    try renderPNG(
        AppIconArt(metrics: IconMetrics(canvas: CGFloat(pixelSize)), mark: mark),
        pixelSize: pixelSize,
        to: url
    )
}

@MainActor
func writeAppIconContents(in directory: URL) throws {
    let entries = variants.map { variant -> String in
        let name = "icon_\(variant.size)x\(variant.size)\(variant.scale == 2 ? "@2x" : "").png"
        return """
            {
              "filename" : "\(name)",
              "idiom" : "mac",
              "scale" : "\(variant.scale)x",
              "size" : "\(variant.size)x\(variant.size)"
            }
        """
    }
    let json = """
    {
      "images" : [
    \(entries.joined(separator: ",\n"))
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }
    """
    try json.write(to: directory.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
}

/// 写一整套 App Icon（10 档尺寸 + Contents.json）
@MainActor
func writeIconSet(to directory: URL, mark: Mark, label: String) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for variant in variants {
        let name = "icon_\(variant.size)x\(variant.size)\(variant.scale == 2 ? "@2x" : "").png"
        try renderAppIconPNG(
            mark: mark,
            pixelSize: variant.size * variant.scale,
            to: directory.appendingPathComponent(name)
        )
    }
    try writeAppIconContents(in: directory)
    print("✓ \(label).appiconset（\(mark.rawValue)）")
}

/// 应用内品牌标记：与默认 App Icon 同一份图形，供 SwiftUI `Image(.brandMark)` 使用
@MainActor
func writeBrandMark() throws {
    try FileManager.default.createDirectory(at: brandMarkSetDir, withIntermediateDirectories: true)
    try renderAppIconPNG(
        mark: .shot,
        pixelSize: brandMarkPixelSize,
        to: brandMarkSetDir.appendingPathComponent("BrandMark.png")
    )
    let json = """
    {
      "images" : [
        {
          "filename" : "BrandMark.png",
          "idiom" : "universal"
        }
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }
    """
    try json.write(to: brandMarkSetDir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
    print("✓ BrandMark.imageset")
}

/// 菜单栏模板图：`template-rendering-intent` 让系统自动着色
@MainActor
func writeMenuBarIcon() throws {
    try FileManager.default.createDirectory(at: menuBarIconSetDir, withIntermediateDirectories: true)

    let size = menuBarIconPointSize
    let menuBarVariants: [(scale: Int, name: String)] = [
        (1, "MenuBarIcon.png"),
        (2, "MenuBarIcon@2x.png"),
    ]
    for variant in menuBarVariants {
        try renderPNG(
            MenuBarIconArt(canvas: CGFloat(size)),
            pixelSize: size * variant.scale,
            to: menuBarIconSetDir.appendingPathComponent(variant.name)
        )
    }

    let entries = menuBarVariants.map { variant in
        """
            {
              "filename" : "\(variant.name)",
              "idiom" : "mac",
              "scale" : "\(variant.scale)x",
              "size" : "\(size)x\(size)"
            }
        """
    }
    .joined(separator: ",\n")

    let json = """
    {
      "images" : [
    \(entries)
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      },
      "properties" : {
        "template-rendering-intent" : "template"
      }
    }
    """
    try json.write(to: menuBarIconSetDir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
    print("✓ MenuBarIcon.imageset（模板图）")
}

/// 开发版图标：Debug 的 App Icon（`ASSETCATALOG_COMPILER_APPICON_NAME = AppIconDev`）。
/// 与正式版同图、叠「测试版」标签，尺寸齐全，Finder / Dock / 启动台都能区分。
@MainActor
func writeDevIcon() throws {
    try FileManager.default.createDirectory(at: devIconSetDir, withIntermediateDirectories: true)

    for variant in variants {
        let name = "icon_\(variant.size)x\(variant.size)\(variant.scale == 2 ? "@2x" : "").png"
        let pixelSize = variant.size * variant.scale
        try renderPNG(
            DevIconArt(canvas: CGFloat(pixelSize), mark: .shot),
            pixelSize: pixelSize,
            to: devIconSetDir.appendingPathComponent(name)
        )
    }

    try writeAppIconContents(in: devIconSetDir)
    print("✓ AppIconDev.appiconset（测试版）")
}

// MARK: - 入口

MainActor.assumeIsolated {
    do {
        try writeIconSet(to: iconSetDir, mark: .shot, label: "AppIcon")
        try writeBrandMark()
        try writeMenuBarIcon()
        try writeDevIcon()

        if let previewDir {
            try FileManager.default.createDirectory(at: previewDir, withIntermediateDirectories: true)
            // 预览按真实尺寸出图，方便肉眼核对小尺寸退化是否符合预期
            for size in [512, 128, 64, 32, 16] {
                try renderAppIconPNG(
                    mark: .shot,
                    pixelSize: size,
                    to: previewDir.appendingPathComponent("shot-\(size).png")
                )
            }
            try renderPNG(MenuBarIconArt(canvas: 18), pixelSize: 72,
                          to: previewDir.appendingPathComponent("menubar-18.png"))
            print("✓ 预览已写入 \(previewDir.path)")
        }
    } catch {
        print("生成失败：\(error.localizedDescription)")
        exit(1)
    }
}
