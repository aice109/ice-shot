import AppKit
import CoreGraphics
import Observation
import SwiftUI

@MainActor
@Observable
final class EditorModel {
    private(set) var image: CGImage
    let title: String

    /// 裁剪模式下的当前裁剪框（原图像素、左上原点）；`nil` 表示不在裁剪模式。
    private(set) var cropRect: CGRect?

    /// 取字模式：图上文字可直接拖选复制（系统 Live Text）。绘制手势在此期间暂停。
    private(set) var isTextPicking = false
    /// Live Text 分析结果缓存，跟随模型存活。
    @ObservationIgnored let liveTextStore = LiveTextStore()

    var imageSize: CGSize {
        CGSize(width: image.width, height: image.height)
    }

    var isCropping: Bool { tool == .crop }

    private(set) var annotations: [EditorAnnotation] = []
    /// 当前选中的标注。改动一律走 `updateSelection`，好让 AppKit 工具栏同步按钮可用性。
    private(set) var selectedID: UUID?

    /// 二级选项浮窗的目标：新建标注用的工具参数，或选中的那条打码标注。
    enum OptionsTarget: Equatable {
        case tool(EditorTool)
        case selectedAnnotation
        /// 「变换」浮窗（旋转 / 翻转）：只给编辑器窗口，与工具二级选项同一种交互语言。
        case transform
    }

    /// 当前打开的二级选项浮窗（`nil` = 没打开）。放在模型里，是为了让 `Esc` 先关浮窗。
    private(set) var optionsTarget: OptionsTarget?

    /// 注意：形状与画笔这两个组按钮**不受**这条规则约束——它们再点一次是把二级选项浮窗重新弹出来，
    /// 不熄灯（见 `MarkupToolbar`）。想回无工具态一律按 `V`。
    private(set) var tool: EditorTool = .select
    /// 新标注用的颜色：默认取色板第一格（色板见 `ColorPalettePreferences`）。
    var color: EditorColor = ColorPalettePreferences.defaultColor
    /// 各工具共用的粗细；每个工具按自己的规则换算（见 `EditorToolOptions.WidthRole`）。
    var lineWidth: CGFloat = 8

    /// 粗细滑块范围：上下限都从原 1…24 往外放开一档，默认值翻倍后仍能调粗 / 调细。
    static let lineWidthRange: ClosedRange<CGFloat> = 2...30
    /// 马赛克块大小 / 模糊半径（原图像素）；由马赛克工具的二级选项浮窗控制。
    private(set) var filterAmount: CGFloat = 16
    /// 打码质感（马赛克 / 模糊 / 噪点 / 纯色）：就一个「马赛克」工具，模糊是它的样式之一。
    private(set) var redactionStyle: RedactionStyle = .mosaic
    /// 新文字标注的背景样式；由文字工具的二级选项控制。
    private(set) var textBackground: TextBackgroundStyle = .none
    /// 聚光灯的形状（椭圆 / 矩形）。
    private(set) var spotlightShape: AreaShape = .ellipse
    /// 聚光灯的压暗力度（0.3–0.9）；与共用的 `lineWidth` 无关。
    private(set) var spotlightDim: Double = SpotlightStyle.defaultDim
    /// 放大镜的形状与倍数（1.5× / 2× / 3×）。
    private(set) var magnifierShape: AreaShape = .ellipse
    private(set) var magnifierZoom: Double = MagnifierStyle.defaultZoom
    var statusMessage: String?
    /// 导出带壳样式；`nil` 表示不带壳。
    ///
    /// 只影响复制 / 保存 / 贴图，不烘进 `image`，也不进撤销栈。这样历史原图始终是干净的，
    /// 用户重新打开历史后还能换一种壳或彻底关掉。
    private(set) var frameStyle: ScreenshotFrameStyle?

    var isFrameEnabled: Bool { frameStyle != nil }

    /// 开关带壳。开启时保留上次的详细样式；第一次开启用默认窗口壳。
    func setFrameEnabled(_ enabled: Bool) {
        if enabled {
            frameStyle = frameStyle ?? .default
        } else {
            frameStyle = nil
        }
    }

    /// 替换整套带壳样式；传 `nil` 等价于关闭。
    func setFrameStyle(_ style: ScreenshotFrameStyle?) {
        frameStyle = style
    }

    @ObservationIgnored var onToolChange: ((EditorTool) -> Void)?
    /// 选中态变化（画布点选 / 新增 / 删除 / 撤销）。AppKit 工具栏靠它刷新按钮状态。
    @ObservationIgnored var onSelectionChange: (() -> Void)?
    /// 图像尺寸变化（裁剪 / 旋转 / 翻转 / 还原）后同步外部显示（如窗口副标题）。
    @ObservationIgnored var onImageChange: (() -> Void)?
    /// 撤销 / 重做按钮的可用状态；`UndoManager` 本身不可观察，这里手动同步。
    private(set) var canUndo = false
    private(set) var canRedo = false
    /// 滑块拖动过程中的样式快照（打码强度 / 聚光灯暗度），松手时合并成一次撤销。
    @ObservationIgnored private var liveStyleSnapshot: [EditorAnnotation]?

    private var attachedUndoManager: UndoManager?
    private let fallbackUndoManager = UndoManager()

    init(image: CGImage, title: String) {
        self.image = image
        self.title = title
        // 每个用户动作自己成组（见 `registerUndo`），不按事件循环自动合并，
        // 否则「改文字 + 紧接着画一笔」会变成同一个撤销步骤。
        fallbackUndoManager.groupsByEvent = false
    }

    var selectedAnnotation: EditorAnnotation? {
        guard let selectedID else { return nil }
        return annotations.first { $0.id == selectedID }
    }

    var activeStyle: AnnotationStyle {
        switch tool {
        case .highlighter:
            return AnnotationStyle(
                color: color,
                lineWidth: EditorToolOptions.WidthRole.highlighter.resolved(lineWidth),
                opacity: 0.35
            )
        case .text:
            return textStyle
        case .pixelate:
            // 涂抹式笔刷：线宽换算成笔刷直径（与高亮同理），块大小单独由选项浮窗控制。
            return AnnotationStyle(
                color: color,
                lineWidth: EditorToolOptions.WidthRole.brush.resolved(lineWidth),
                opacity: 1,
                filterAmount: filterAmount,
                redactionStyle: redactionStyle
            )
        case .spotlight:
            // 不用颜色、不用线宽：只要形状与暗度。
            return AnnotationStyle(
                color: color,
                lineWidth: 1,
                opacity: 1,
                spotlight: SpotlightStyle(shape: spotlightShape, dim: spotlightDim)
            )
        case .magnifier:
            // 颜色只用来描边；线宽也不参与。
            return AnnotationStyle(
                color: color,
                lineWidth: 1,
                opacity: 1,
                magnifier: MagnifierStyle(shape: magnifierShape, zoom: magnifierZoom)
            )
        default:
            return AnnotationStyle(color: color, lineWidth: lineWidth, opacity: 1)
        }
    }

    /// 文字标注的当前默认样式：颜色 / 字号 / 背景。与当前工具无关，
    /// 输入态预览与提交后的新标注都用它——输入框里现就能看到样子。
    var textStyle: AnnotationStyle {
        // 文字用字号（原图像素），跟着同一个线宽滑块走。
        AnnotationStyle(
            color: color,
            lineWidth: 1,
            opacity: 1,
            fontSize: EditorToolOptions.WidthRole.fontSize.resolved(lineWidth),
            textBackground: textBackground
        )
    }

    private var currentUndoManager: UndoManager {
        attachedUndoManager ?? fallbackUndoManager
    }

    func attachUndoManager(_ manager: UndoManager?) {
        if let manager {
            manager.groupsByEvent = false
            attachedUndoManager = manager
        }
    }

    /// 进入 / 退出取字模式。
    ///
    /// 取字时不能同时裁剪（裁剪框坐标依附图像尺寸）或保留标注选中态，进入前先清掉；
    /// 退出后回到「选择」工具，状态栏提示清空。
    func setTextPicking(_ enabled: Bool) {
        guard enabled != isTextPicking else { return }
        if enabled {
            if isCropping {
                cropRect = nil
                tool = .select
                onToolChange?(tool)
            }
            updateSelection(nil)
        }
        isTextPicking = enabled
        statusMessage = enabled ? String(localized: "拖动选择图中文字，⌘C 复制；Esc 退出") : nil
        // 取字模式下工具胶囊整条换成提示条，展开态留着没有意义。
        if enabled {
            setMoreExpanded(false)
        }
    }

    func setTool(_ newTool: EditorTool) {
        // 选任何工具都意味着退出取字，避免「看着像在画，其实手势被文字层吃掉了」。
        isTextPicking = false
        if newTool == .crop {
            // 进入裁剪模式：初始裁剪框 = 整幅图像；已在裁剪中则保留当前框。
            if cropRect == nil {
                cropRect = CGRect(origin: .zero, size: imageSize)
            }
            updateSelection(nil)
        } else {
            cropRect = nil
        }
        tool = newTool
        statusMessage = nil
        rememberLastTool(newTool)
        onToolChange?(newTool)
    }

    /// 形状 / 画笔按钮图标要交代「点下去会画什么」，所以得记住熄灯前用的是组内哪一个。
    /// 只存内存：这是单次编辑的手感，跨截图记住反而会让用户奇怪「为什么这次默认是椭圆」。
    private(set) var lastShapeTool: EditorTool = .rectangle
    private(set) var lastBrushTool: EditorTool = .freehand

    /// 多子型组的「上次子型」；参数不合法时回该组的第一个成员。
    func lastTool(in group: EditorTool.ToolGroup) -> EditorTool {
        switch group {
        case .shape: return lastShapeTool
        case .brush: return lastBrushTool
        case .more: return group.members.first ?? .number
        }
    }

    /// 「更多」就地横向展开的开关。与「当前画什么」无关，仅是一次布局偏好：
    /// `V` 熄灯不收起它，进裁剪 / 取字模式才自动收起（那些模式下工具胶囊整条换掉）。
    private(set) var isMoreExpanded = false

    func setMoreExpanded(_ expanded: Bool) {
        isMoreExpanded = expanded
        if !expanded, let group = optionsTargetGroup, group == .more {
            // 浮窗挂在已收起的格子上会成为孤儿，一并关掉。
            optionsTarget = nil
        }
    }

    private var optionsTargetGroup: EditorTool.ToolGroup? {
        guard case .tool(let tool) = optionsTarget else { return nil }
        return tool.toolGroup
    }

    private func rememberLastTool(_ tool: EditorTool) {
        switch tool.toolGroup {
        case .shape: lastShapeTool = tool
        case .brush: lastBrushTool = tool
        case .more, .none: break
        }
    }

    func setColor(_ newColor: EditorColor) {
        color = newColor
    }

    func setLineWidth(_ width: CGFloat) {
        lineWidth = min(max(width, Self.lineWidthRange.lowerBound), Self.lineWidthRange.upperBound)
    }

    /// 二级选项浮窗的取值来源：目标是选中标注时读**那条标注**的实际值，
    /// 否则读「以后新标注用什么」的默认值。写路径不用分叉——各 setter 两边都改。
    private var optionsAnnotation: EditorAnnotation? {
        optionsTarget == .selectedAnnotation ? selectedAnnotation : nil
    }

    var optionsFilterAmount: CGFloat {
        optionsAnnotation?.filterAmount ?? filterAmount
    }

    var optionsRedactionStyle: RedactionStyle {
        optionsAnnotation?.redactionStyle ?? redactionStyle
    }

    var optionsTextBackground: TextBackgroundStyle {
        optionsAnnotation?.textBackground ?? textBackground
    }

    var optionsSpotlightShape: AreaShape {
        optionsAnnotation?.spotlightStyle.shape ?? spotlightShape
    }

    var optionsSpotlightDim: Double {
        optionsAnnotation?.spotlightStyle.dim ?? spotlightDim
    }

    var optionsMagnifierShape: AreaShape {
        optionsAnnotation?.magnifierStyle.shape ?? magnifierShape
    }

    var optionsMagnifierZoom: Double {
        optionsAnnotation?.magnifierStyle.zoom ?? magnifierZoom
    }

    /// 开关二级选项浮窗；传 `nil` 关闭。
    func setOptionsTarget(_ target: OptionsTarget?) {
        optionsTarget = target
    }

    /// 改文字背景：新文字标注的默认值跟着变；选中的是文字标注时同步改那一条
    /// （点一下就是一次独立操作，直接进撤销栈，不需要滑块那套实时快照）。
    func setTextBackground(_ style: TextBackgroundStyle) {
        textBackground = style
        guard let selectedID,
              let index = annotations.firstIndex(where: { $0.id == selectedID }),
              annotations[index].kind == .text else {
            return
        }
        var updated = annotations[index]
        updated.style.textBackground = style
        update(updated)
    }

    /// 选中的马赛克 / 模糊标注跟着滑块实时变化；松手（`commitFilterChange`）才进撤销栈。
    func setFilterAmount(_ amount: CGFloat) {
        let clamped = min(max(amount, 4), 40)
        guard clamped != filterAmount else { return }
        filterAmount = clamped

        guard let selectedID,
              let index = annotations.firstIndex(where: { $0.id == selectedID }),
              annotations[index].kind.needsSourceImage else {
            return
        }
        if liveStyleSnapshot == nil {
            liveStyleSnapshot = annotations
        }
        var updated = annotations[index]
        updated.style.filterAmount = clamped
        annotations[index] = updated
    }

    /// 打码样式与块大小走同一套实时 / 撤销流程。
    func setRedactionStyle(_ style: RedactionStyle) {
        guard style != redactionStyle else { return }
        redactionStyle = style

        guard let selectedID,
              let index = annotations.firstIndex(where: { $0.id == selectedID }),
              annotations[index].kind.needsSourceImage else {
            return
        }
        if liveStyleSnapshot == nil {
            liveStyleSnapshot = annotations
        }
        var updated = annotations[index]
        updated.style.redactionStyle = style
        annotations[index] = updated
    }

    /// 粗细滑块：拖动中实时生效，松手（`commitWidthChange`）才进撤销栈。
    ///
    /// 选中一条形状 / 画笔族标注时，改的是**那条标注**的线宽；否则只改「以后新标注用什么」。
    /// 只给粗细不给颜色——颜色与粗细是一对「新标注默认值」的语义，
    /// 混进选中态会和「改这一条的实际样式」打架（见 `EditorToolOptions.selectedStroke`）。
    func setWidth(_ width: CGFloat) {
        setLineWidth(width)

        guard let selectedID,
              let index = annotations.firstIndex(where: { $0.id == selectedID }),
              EditorToolOptions.isStrokeAdjustable(annotations[index].kind) else {
            return
        }
        if liveStyleSnapshot == nil {
            liveStyleSnapshot = annotations
        }
        var updated = annotations[index]
        updated.style.lineWidth = width
        annotations[index] = updated
    }

    /// 粗细滑块松手：整段拖动只记一个撤销步骤。
    func commitWidthChange() {
        commitStyleChange(actionName: String(localized: "调整标注粗细"))
    }

    /// 滑块松手：整段拖动只记一个撤销步骤。
    func commitFilterChange() {
        commitStyleChange(actionName: String(localized: "调整打码强度"))
    }

    // MARK: - 聚光灯

    /// 聚光灯形状：新聚光灯跟新；选中的是聚光灯则同步改那一条。
    func setSpotlightShape(_ shape: AreaShape) {
        spotlightShape = shape
        updateSelectedSpotlight { $0.spotlight?.shape = shape }
    }

    /// 聚光灯暗度：拖动中实时生效，松手（`commitSpotlightChange`）才进撤销栈。
    func setSpotlightDim(_ dim: Double) {
        let clamped = min(
            max(dim, SpotlightStyle.dimRange.lowerBound),
            SpotlightStyle.dimRange.upperBound
        )
        guard clamped != spotlightDim else { return }
        spotlightDim = clamped
        updateSelectedSpotlight { style in
            var spotlight = style.spotlight ?? SpotlightStyle()
            spotlight.dim = clamped
            style.spotlight = spotlight
        }
    }

    /// 放大镜形状 / 倍数：新放大镜跟着变；选中的是放大镜则同步改那一条。
    /// 两者都是离散档位，一次点击就是一次撤销步骤，不需要滑块那套实时快照。
    func setMagnifierShape(_ shape: AreaShape) {
        magnifierShape = shape
        updateSelectedMagnifier { $0.shape = shape }
    }

    func setMagnifierZoom(_ zoom: Double) {
        let clamped = min(
            max(zoom, MagnifierStyle.zoomLevels.first ?? MagnifierStyle.defaultZoom),
            MagnifierStyle.zoomLevels.last ?? MagnifierStyle.defaultZoom
        )
        magnifierZoom = clamped
        updateSelectedMagnifier { $0.zoom = clamped }
    }

    private func updateSelectedMagnifier(_ mutate: (inout MagnifierStyle) -> Void) {
        guard let selectedID,
              let index = annotations.firstIndex(where: { $0.id == selectedID }),
              annotations[index].kind == .magnifier else {
            return
        }
        var updated = annotations[index]
        var magnifier = updated.style.magnifier ?? MagnifierStyle()
        mutate(&magnifier)
        updated.style.magnifier = magnifier
        update(updated)
    }

    func commitSpotlightChange() {
        commitStyleChange(actionName: String(localized: "调整聚光灯"))
    }

    /// 改选中聚光灯标注的样式；拖动类调用先拍快照，松手才进撤销栈。
    private func updateSelectedSpotlight(_ mutate: (inout AnnotationStyle) -> Void) {
        guard let selectedID,
              let index = annotations.firstIndex(where: { $0.id == selectedID }),
              annotations[index].kind == .spotlight else {
            return
        }
        if liveStyleSnapshot == nil {
            liveStyleSnapshot = annotations
        }
        var updated = annotations[index]
        var style = updated.style
        if style.spotlight == nil {
            style.spotlight = SpotlightStyle()
        }
        mutate(&style)
        updated.style = style
        annotations[index] = updated
    }

    private func commitStyleChange(actionName: String) {
        guard let previous = liveStyleSnapshot else { return }
        liveStyleSnapshot = nil
        guard previous != annotations else { return }
        registerUndo(previous, actionName: actionName)
    }

    func select(_ id: UUID?) {
        updateSelection(id)
    }

    private func updateSelection(_ id: UUID?) {
        guard selectedID != id else { return }
        selectedID = id
        onSelectionChange?()
    }

    // MARK: - 裁剪

    /// 裁剪框是否仍覆盖整幅图像（初始态）。
    /// 此时框内拖动必须理解为「拉一个新框」，否则拖动只是在边界内平移一个整幅大小的框，
    /// 看上去就是「裁剪没反应」。
    var isCropRectFullFrame: Bool {
        guard let cropRect else { return true }
        return cropRect == CGRect(origin: .zero, size: imageSize)
    }

    /// 拖动 / 键盘调整裁剪框：自动取整到整数像素并夹在图像内。
    func updateCropRect(_ rect: CGRect) {
        guard tool == .crop,
              let normalized = AnnotationCropper.normalizedRect(rect, imageSize: imageSize) else {
            return
        }
        cropRect = normalized
    }

    /// 键盘微调裁剪框；`coarse` 时步长为 10 px。位移超边界时保留原框。
    func nudgeCropRect(dx: CGFloat, dy: CGFloat) {
        guard tool == .crop, let crop = cropRect else { return }
        let moved = crop.offsetBy(dx: dx, dy: dy)
        guard let normalized = AnnotationCropper.normalizedRect(moved, imageSize: imageSize),
              normalized.size == crop.size else {
            return
        }
        cropRect = normalized
    }

    /// 取消裁剪：图像与标注都不变，回到选择工具。
    func cancelCrop() {
        guard tool == .crop else { return }
        cropRect = nil
        setTool(.select)
        statusMessage = String(localized: "已取消裁剪")
    }

    /// 应用裁剪：图像与标注整体作为一步撤销记录。范围未变时不产生撤销项。
    @discardableResult
    func applyCrop() -> Bool {
        guard tool == .crop, let crop = cropRect else { return false }
        guard crop != CGRect(origin: .zero, size: imageSize) else {
            cropRect = nil
            setTool(.select)
            statusMessage = String(localized: "裁剪范围未变化")
            return false
        }
        guard let cropped = try? ImageCropper.crop(image, to: crop) else {
            statusMessage = String(localized: "裁剪失败，请重新选择范围")
            return false
        }

        let previous = EditorState(image: image, annotations: annotations)
        image = cropped
        annotations = AnnotationCropper.remap(annotations, croppingTo: crop)
        updateSelection(nil)
        cropRect = nil
        tool = .select
        statusMessage = "已裁剪为 \(cropped.width) × \(cropped.height) px"
        onToolChange?(tool)
        onImageChange?()
        registerUndo(previous, actionName: String(localized: "裁剪"))
        return true
    }

    // MARK: - 旋转与翻转

    /// 顺时针 / 逆时针旋转 90°；裁剪模式中不可用（裁剪框坐标绑定当前尺寸）。
    @discardableResult
    func rotate(clockwise: Bool) -> Bool {
        guard !isCropping else { return false }
        guard let rotated = try? ImageTransformer.rotated(image, clockwise: clockwise) else {
            statusMessage = String(localized: "旋转失败")
            return false
        }
        applyImage(
            rotated,
            actionName: clockwise ? String(localized: "顺时针旋转") : String(localized: "逆时针旋转")
        ) { annotations, size in
            AnnotationTransformer.rotated(
                annotations,
                imageSize: size,
                clockwise: clockwise
            )
        }
        statusMessage = "已\(clockwise ? "顺时针" : "逆时针")旋转（\(rotated.width) × \(rotated.height) px）"
        return true
    }

    /// 水平（左右）/ 垂直（上下）翻转；裁剪模式中不可用。
    @discardableResult
    func flip(horizontal: Bool) -> Bool {
        guard !isCropping else { return false }
        guard let flipped = try? ImageTransformer.flipped(image, horizontal: horizontal) else {
            statusMessage = String(localized: "翻转失败")
            return false
        }
        applyImage(
            flipped,
            actionName: horizontal ? String(localized: "水平翻转") : String(localized: "垂直翻转")
        ) { annotations, size in
            AnnotationTransformer.flipped(
                annotations,
                imageSize: size,
                horizontal: horizontal
            )
        }
        statusMessage = "已\(horizontal ? "水平" : "垂直")翻转"
        return true
    }

    /// 图像 + 标注整体变换，作为一步撤销记录。
    private func applyImage(
        _ newImage: CGImage,
        actionName: String,
        annotations transform: ([EditorAnnotation], CGSize) -> [EditorAnnotation]
    ) {
        let previous = EditorState(image: image, annotations: annotations)
        let previousSize = imageSize
        image = newImage
        self.annotations = transform(previous.annotations, previousSize)
        updateSelection(nil)
        cropRect = nil
        onImageChange?()
        registerUndo(previous, actionName: actionName)
    }

    func clearSelection() {
        updateSelection(nil)
    }

    /// 下一个序号 = 现有序号最大值 + 1。
    ///
    /// 不单独存计数器：删除 / 撤销 / 重做后编号天然自洽，不会出现重号；
    /// 删除中间某个序号也不重排其余编号（截图里的「第 2 步」不会因删了 1 而变义）。
    var nextNumber: Int {
        (annotations.compactMap { $0.kind == .number ? $0.number : nil }.max() ?? 0) + 1
    }

    /// 在点击位置放一个序号徽章：圆心回夹到画布内，保证整圆可见。
    @discardableResult
    func addNumber(at center: CGPoint) -> EditorAnnotation {
        let radius = max(20, activeStyle.lineWidth * 6) / 2
        let clamped = CGPoint(
            x: min(max(center.x, radius), max(radius, imageSize.width - radius)),
            y: min(max(center.y, radius), max(radius, imageSize.height - radius))
        )
        let annotation = EditorAnnotation(
            kind: .number,
            start: clamped,
            end: clamped,
            number: nextNumber,
            style: activeStyle
        )
        add(annotation)
        return annotation
    }

    func add(_ annotation: EditorAnnotation) {
        let previous = annotations
        annotations.append(annotation)
        // 绘制完成后不自动选中：避免画一笔就留下一圈选中框。
        // 需要移动 / 删除时，单击标注再选中（此时才显示选中框）。
        updateSelection(nil)
        registerUndo(previous, actionName: "添加\(annotation.kind.displayName)")
    }

    func replaceLive(_ newAnnotations: [EditorAnnotation]) {
        annotations = newAnnotations
    }

    /// 修改已有标注（移动、重输入文字等）；无变化时不产生撤销项。
    func update(_ annotation: EditorAnnotation) {
        guard let index = annotations.firstIndex(where: { $0.id == annotation.id }),
              annotations[index] != annotation else {
            return
        }
        let previous = annotations
        annotations[index] = annotation
        registerUndo(previous, actionName: "编辑\(annotation.kind.displayName)")
    }

    func delete(id: UUID) {
        guard annotations.contains(where: { $0.id == id }) else { return }
        let previous = annotations
        annotations.removeAll { $0.id == id }
        if selectedID == id {
            updateSelection(nil)
        }
        registerUndo(previous, actionName: String(localized: "删除标注"))
    }

    func commitLiveChange(
        from previous: [EditorAnnotation],
        actionName: String
    ) {
        registerUndo(previous, actionName: actionName)
    }

    func deleteSelected() {
        guard let selectedID,
              annotations.contains(where: { $0.id == selectedID }) else {
            return
        }
        delete(id: selectedID)
    }

    func undo() {
        guard currentUndoManager.canUndo else { return }
        currentUndoManager.undo()
        refreshUndoAvailability()
    }

    func redo() {
        guard currentUndoManager.canRedo else { return }
        currentUndoManager.redo()
        refreshUndoAvailability()
    }

    func renderedImage() -> CGImage? {
        let size = CGSize(width: image.width, height: image.height)
        let content = EditorRenderView(image: image, annotations: annotations)
            .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)
        return renderer.cgImage
    }

    private func registerUndo(_ previousAnnotations: [EditorAnnotation], actionName: String) {
        // 图像也进快照：撤销裁剪时必须把图像一起还原，否则标注坐标会与新尺寸错位。
        registerUndo(
            EditorState(image: image, annotations: previousAnnotations),
            actionName: actionName
        )
    }

    private func registerUndo(_ previous: EditorState, actionName: String) {
        let manager = currentUndoManager
        manager.beginUndoGrouping()
        manager.registerUndo(withTarget: self) { target in
            target.restore(previous)
        }
        manager.setActionName(actionName)
        manager.endUndoGrouping()
        refreshUndoAvailability()
    }

    private func refreshUndoAvailability() {
        let manager = currentUndoManager
        canUndo = manager.canUndo
        canRedo = manager.canRedo
    }

    private func restore(_ snapshot: EditorState) {
        let current = EditorState(image: image, annotations: annotations)
        image = snapshot.image
        annotations = snapshot.annotations
        if let selectedID, !snapshot.annotations.contains(where: { $0.id == selectedID }) {
            updateSelection(nil)
        }
        // 撤销 / 重做过程中不允许停留在裁剪模式（裁剪框坐标依附于旧图像尺寸）。
        if tool == .crop {
            cropRect = nil
            tool = .select
            onToolChange?(tool)
        }
        onImageChange?()
        let manager = currentUndoManager
        manager.registerUndo(withTarget: self) { target in
            target.restore(current)
        }
    }

    /// 撤销快照：图像 + 标注。裁剪会同时改变两者，必须整体进栈。
    private struct EditorState {
        var image: CGImage
        var annotations: [EditorAnnotation]
    }
}

struct EditorRenderView: View {
    let image: CGImage
    let annotations: [EditorAnnotation]

    /// 导出时同样要把马赛克 / 模糊烧进结果图，保持 WYSIWYG。
    @State private var filters = MarkupFilterCache()

    var body: some View {
        let layout = EditorCanvasLayout(
            imageSize: CGSize(width: image.width, height: image.height),
            viewSize: CGSize(width: image.width, height: image.height),
            padding: 0
        )
        ZStack {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
            Canvas { context, _ in
                for annotation in annotations {
                    if let filtered = filters.result(for: annotation, source: image) {
                        context.opacity = 1
                        context.blendMode = .normal
                        context.draw(
                            Image(decorative: filtered.image, scale: 1),
                            in: layout.viewRect(filtered.rect)
                        )
                    } else {
                        EditorDrawing.draw(
                            annotation,
                            in: &context,
                            layout: layout,
                            source: image
                        )
                    }
                }
            }
        }
    }
}
