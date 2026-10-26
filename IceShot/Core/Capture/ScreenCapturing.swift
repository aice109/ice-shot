import CoreGraphics

struct DisplayFrame: Sendable {
    let display: DisplayDescriptor
    let image: CGImage
}

struct SelectionResult: Sendable {
    let frame: DisplayFrame
    let rect: CGRect
}

/// 已确定的选区：窗口 / 全屏 / 全部显示器 / 重复上次区域直接用它进入就地编辑。
struct SelectionPreset: Sendable {
    let displayID: CGDirectDisplayID
    /// 显示器局部 points 矩形（左上原点）。
    let rect: CGRect
    /// 与 `rect` 对应的像素图；窗口截图可能与冻结帧不同，因此由调用方提供。
    let image: CGImage
}

/// 就地编辑的收尾：`output` 为 nil 表示用户关闭（历史仍保留原图）。
struct SelectionFinish: Sendable {
    let result: SelectionResult
    let original: CGImage
    let output: CGImage?
    let action: MarkupAction
    /// 本次导出用的壳样式；`nil` 表示不带壳。
    ///
    /// 「全部显示器」批量保存时，其余屏要在协调器里套同一个壳，
    /// 因此样式必须跟着收尾一起传出去，而不是在浮层里就烘进单一 `output`。
    var frameStyle: ScreenshotFrameStyle?
}

@MainActor
protocol ScreenCapturing {
    /// 抓取每屏静态帧；区域 / 窗口模式的背景与放大镜都从这里取像素。
    func captureDisplayFrames() async throws -> [DisplayFrame]

    /// 抓取单个显示器；全屏模式使用，避免多屏时抓取无关显示器。
    func captureDisplay(_ displayID: CGDirectDisplayID) async throws -> CGImage

    /// 通过独立窗口过滤器抓取窗口；不依赖显示器静态帧，可保留跨屏窗口完整内容。
    func captureWindow(_ windowID: CGWindowID, includeShadow: Bool) async throws -> CGImage

    /// 只抓一个显示器上的指定区域（显示器局部 points，左上原点）。
    /// 长截图靠它反复抓同一块区域；必须排除 IceShot 自己的窗口。
    func captureRegion(
        displayID: CGDirectDisplayID,
        rect: CGRect
    ) async throws -> CGImage
}

@MainActor
protocol WindowCatalogProviding {
    /// 返回已过滤并按前到后排序的可截取窗口目录。
    func windowCatalog() async throws -> [WindowDescriptor]
}

@MainActor
protocol SelectionOverlayPresenting {
    /// 冻结画面并进入选区 / 就地编辑。
    /// - Parameters:
    ///   - preset: 已有选区（窗口 / 全屏 / 全部显示器 / 重复上次区域），非空时直接进入编辑。
    ///   - windows: 可悬停 / 点击的窗口目录（按前到后排序）；空数组表示纯框选。
    ///   - onWindowPick: 在浮层里点击了高亮窗口时回调一次；抓窗口与进编辑由调用方完成。
    ///   - onFinish: 用户复制 / 保存 / 关闭时回调一次；原图始终回传用于写历史。
    /// - Parameter autoEditOnSelection: 松手后是否直接进入就地标注。
    ///   长截图传 false：松手即结束选区并开始连续抓取。
    func present(
        frames: [DisplayFrame],
        preset: SelectionPreset?,
        autoEditOnSelection: Bool,
        windows: [WindowDescriptor],
        onWindowPick: @escaping (WindowDescriptor) -> Void,
        onFinish: @escaping (SelectionFinish) -> Void,
        onCancel: @escaping () -> Void
    )
    func dismiss()
}

/// 就地编辑操作条上的收尾动作；由浮层转成 `SelectionFinish`。
enum MarkupAction: Sendable {
    case copy
    case save
    /// 贴图：把渲染结果贴成置顶浮动窗口（同时照常写入历史原图）。
    case pin
    case close
}
