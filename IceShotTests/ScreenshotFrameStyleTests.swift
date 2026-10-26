import CoreGraphics
import Foundation
import Testing
@testable import IceShot

/// M3「样式选项」的行为锁定。
///
/// 这一层管两件事：
///
/// 1. **控件改的值真的落到 `frameStyle` 上** —— popover 里每个 Picker / Toggle / TextField
///    最终都走 `EditorModel.setFrameStyle`，这里验证往返不丢项。
/// 2. **窗口来源默认「仅阴影」** —— 窗口截图自带红黄绿，再套一层窗口壳就是双层交通灯。
@MainActor
struct ScreenshotFrameStyleTests {
    // MARK: - 默认样式

    @Test("新建模型默认不带壳")
    func defaultIsDisabled() throws {
        let model = makeModel(try makeImage(), title: "测试")
        #expect(model.frameStyle == nil)
        #expect(!model.isFrameEnabled)
    }

    @Test("区域截图首次开启用完整窗口壳")
    func regionDefaultsToWindowChrome() throws {
        let model = makeModel(try makeImage(), title: "测试")
        model.applyDefaultFrameStyle(for: .region)
        model.setFrameEnabled(true)

        let style = try #require(model.frameStyle)
        #expect(style.chrome == .window)
    }

    @Test("窗口截图首次开启用「仅阴影」")
    func windowDefaultsToShadowOnly() throws {
        let model = makeModel(try makeImage(), title: "测试")
        model.applyDefaultFrameStyle(for: .window)
        model.setFrameEnabled(true)

        let style = try #require(model.frameStyle)
        #expect(style.chrome == .shadowOnly)
    }

    @Test("其它来源保持默认窗口壳")
    func otherSourcesKeepWindowChrome() throws {
        for source in [ScreenshotSource.region, .display, .allDisplays, .scroll] {
            let model = makeModel(try makeImage(), title: "测试")
            model.applyDefaultFrameStyle(for: source)
            model.setFrameEnabled(true)

            let style = try #require(model.frameStyle)
            #expect(style.chrome == .window, "\(source) 不该被改成仅阴影")
        }
    }

    @Test("窗口截图不能把壳形态改回「窗口」")
    func windowSourceRejectsWindowChrome() throws {
        let model = makeModel(try makeImage(), title: "测试")
        model.applyDefaultFrameStyle(for: .window)
        model.setFrameEnabled(true)

        // 尝试绕过约束：直接写一个带窗口壳的样式（例如从偏好恢复出来的旧值）。
        var custom = try #require(model.frameStyle)
        custom.chrome = .window
        custom.background = .ocean
        model.setFrameStyle(custom)

        // 壳形态被拉回仅阴影；其它字段（用户调过的背景）不受影响。
        #expect(model.frameStyle?.chrome == .shadowOnly)
        #expect(model.frameStyle?.background == .ocean)
    }

    @Test("窗口截图只提供一档壳形态")
    func windowSourceHasSingleChromeOption() throws {
        let model = makeModel(try makeImage(), title: "测试")
        model.applyDefaultFrameStyle(for: .window)
        #expect(model.allowedChrome == [.shadowOnly])

        let regionModel = makeModel(try makeImage(), title: "测试")
        regionModel.applyDefaultFrameStyle(for: .region)
        #expect(regionModel.allowedChrome.count == 2)
    }

    @Test("区域截图仍可以自由选壳形态")
    func regionSourceKeepsBothChromes() throws {
        let model = makeModel(try makeImage(), title: "测试")
        model.applyDefaultFrameStyle(for: .region)
        model.setFrameEnabled(true)

        var custom = try #require(model.frameStyle)
        custom.chrome = .shadowOnly
        model.setFrameStyle(custom)
        #expect(model.frameStyle?.chrome == .shadowOnly)

        custom.chrome = .window
        model.setFrameStyle(custom)
        #expect(model.frameStyle?.chrome == .window)
    }

    @Test("来源声明只改默认样式，不改当前状态")
    func sourceDeclarationDoesNotEnableFrame() throws {
        let model = makeModel(try makeImage(), title: "测试")
        model.applyDefaultFrameStyle(for: .window)

        // 声明来源≠开启带壳：每次截图仍然默认关闭。
        #expect(model.frameStyle == nil)
        #expect(!model.isFrameEnabled)
        // 但默认样式已经就位。
        #expect(model.defaultFrameStyle.chrome == .shadowOnly)
    }

    // MARK: - 样式往返

    @Test("逐项改样式都能读回原值")
    func styleRoundTripsEveryField() throws {
        let model = makeModel(try makeImage(), title: "测试")
        model.setFrameEnabled(true)

        var style = try #require(model.frameStyle)
        style.chrome = .shadowOnly
        style.appearance = .dark
        style.background = .aurora
        style.padding = .large
        style.showsShadow = false
        style.title = "示例窗口"
        model.setFrameStyle(style)

        let readBack = try #require(model.frameStyle)
        #expect(readBack == style)
        #expect(readBack.title == "示例窗口")
    }

    @Test("关掉再开启回到刚改过的样式，不是会话开始时的旧值")
    func togglingKeepsLastEditedStyle() throws {
        let model = makeModel(try makeImage(), title: "测试")
        model.setFrameEnabled(true)

        var style = try #require(model.frameStyle)
        style.background = .sunrise
        style.padding = .small
        model.setFrameStyle(style)

        model.setFrameEnabled(false)
        #expect(model.frameStyle == nil)

        model.setFrameEnabled(true)
        // 用户刚调好的背景不该因为一次开关就丢掉。
        #expect(model.frameStyle?.background == .sunrise)
        #expect(model.frameStyle?.padding == .small)
    }

    @Test("样式档位全部可枚举，不会漏掉新增项")
    func allStyleCasesEnumerate() {
        #expect(ScreenshotFrameStyle.Chrome.allCases.count == 2)
        #expect(ScreenshotFrameStyle.Appearance.allCases.count == 3)
        #expect(ScreenshotFrameStyle.Background.allCases.count == 5)
        #expect(ScreenshotFrameStyle.Padding.allCases.count == 3)
        // 每一项都要有可显示的名字。
        for chrome in ScreenshotFrameStyle.Chrome.allCases {
            #expect(!chrome.title.isEmpty)
        }
        for background in ScreenshotFrameStyle.Background.allCases {
            #expect(!background.title.isEmpty)
        }
        for padding in ScreenshotFrameStyle.Padding.allCases {
            #expect(!padding.title.isEmpty)
        }
    }

    @Test("每一项样式都能渲染出与规格一致的尺寸")
    func everyCombinationRenders() throws {
        let content = try makeImage(width: 1000, height: 600)

        for chrome in ScreenshotFrameStyle.Chrome.allCases {
            for background in ScreenshotFrameStyle.Background.allCases {
                for padding in ScreenshotFrameStyle.Padding.allCases {
                    var style = ScreenshotFrameStyle.default
                    style.chrome = chrome
                    style.background = background
                    style.padding = padding

                    let output = try ScreenshotFrameComposer.render(content, style: style)
                    #expect(output.width > 1000, "\(chrome)/\(background)/\(padding) 应该有留白")
                    #expect(
                        output.height == 600 + (chrome == .window ? 28 : 0) + Int(padding.baseValue * 2)
                    )
                }
            }
        }
    }

    @Test("窗口来源的默认样式导出的高度比窗口壳少一个标题栏")
    func windowDefaultExportsShorter() throws {
        let content = try makeImage(width: 1000, height: 600)

        let regionModel = makeModel(content, title: "区域")
        regionModel.applyDefaultFrameStyle(for: .region)
        regionModel.setFrameEnabled(true)

        let windowModel = makeModel(content, title: "窗口")
        windowModel.applyDefaultFrameStyle(for: .window)
        windowModel.setFrameEnabled(true)

        let regionExport = try #require(regionModel.exportImage())
        let windowExport = try #require(windowModel.exportImage())

        // 差的就是 28u = 28 px 的标题栏，宽度一致。
        #expect(regionExport.width == windowExport.width)
        #expect(regionExport.height == windowExport.height + 28)
    }

    // MARK: - 辅助

    /// 建模型时把带壳偏好指向一个**随机空域**。
    ///
    /// 不隔离的后果很实在：一个用例存了 `shadowOnly`，下一个用例的
    /// 「区域截图默认窗口壳」就会默默挂掉——而且顺序一变就时红时绿。
    /// 这里显式传 `UserDefaults(suiteName:)`，不碰 `.standard`。
    private func makeModel(
        _ image: CGImage,
        title: String,
        defaults: UserDefaults? = nil
    ) -> EditorModel {
        EditorModel(
            image: image,
            title: title,
            framePreferenceDefaults: defaults ?? Self.isolatedDefaults()
        )
    }

    private static func isolatedDefaults() -> UserDefaults {
        let suiteName = "IceShotTests.FrameStyle.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            // 退回 `.standard` 会让测试静默写坏用户真实偏好，宁可当场炸掉。
            fatalError("无法创建隔离的 UserDefaults 域：\(suiteName)")
        }
        return defaults
    }

    private func makeImage(width: Int = 400, height: Int = 300) throws -> CGImage {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }
}
