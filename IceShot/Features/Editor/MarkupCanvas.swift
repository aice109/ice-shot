import AppKit
import SwiftUI

/// 截图 / 编辑器共用的标注画布：背景图 + 标注层 + 绘制 / 移动手势。
///
/// 编辑器窗口用它（带留白与页面底色）；截图浮层用它（无留白，直接铺在选区上）。
struct MarkupCanvas: View {
    let model: EditorModel
    var padding: CGFloat = 24
    var showsBackground: Bool = true
    /// 允许开始交互的画布局部矩形；浮层用它把交互限制在选区内（默认整张图）。
    var interactionRect: CGRect?
    /// 无标注时双击触发（浮层用来「直接复制并关闭」）。
    var onQuickCopy: (() -> Void)?

    @State private var draft: EditorAnnotation?
    @State private var interaction: Interaction = .idle
    @State private var textDraft: TextDraft?
    @State private var filters = MarkupFilterCache()
    /// 指针位置（视图坐标）：绘制工具用来画笔刷圆圈。
    @State private var hoverPoint: CGPoint?
    @State private var cursor: PointerCursor = .arrow
    /// 本次裁剪拖动前的裁剪框：拖得太小 / 拖到图外时用来回退。
    @State private var cropBaseline: CGRect?

    /// 裁剪框最小边长（原图像素）；太小会误触，也避免裁出无意义的图。
    private static let minimumCropSize: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            let layout = EditorCanvasLayout(
                imageSize: model.imageSize,
                viewSize: proxy.size,
                padding: padding
            )
            ZStack {
                if showsBackground {
                    Color(nsColor: .underPageBackgroundColor)
                }

                Image(decorative: model.image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(
                        width: layout.imageRect.width,
                        height: layout.imageRect.height
                    )
                    .position(
                        x: layout.imageRect.midX,
                        y: layout.imageRect.midY
                    )

                Canvas { context, _ in
                    for annotation in model.annotations {
                        // 正在输入的文字用原生输入框显示，避免和旧文本重影。
                        if annotation.id == textDraft?.id { continue }
                        if let filtered = filters.result(for: annotation, source: model.image) {
                            context.opacity = 1
                            context.blendMode = .normal
                            context.draw(
                                Image(decorative: filtered.image, scale: 1),
                                in: layout.viewRect(filtered.rect)
                            )
                            continue
                        }
                        EditorDrawing.draw(
                            annotation,
                            in: &context,
                            layout: layout,
                            source: model.image
                        )
                    }
                    if let selected = model.selectedAnnotation,
                       selected.id != textDraft?.id {
                        EditorDrawing.drawSelection(
                            selected,
                            in: &context,
                            layout: layout
                        )
                    }
                    if let draft {
                        context.opacity = 1
                        context.blendMode = .normal
                        // 马赛克 / 模糊拖动中就给实时预览；预览是降采样图，放大时保持硬边。
                        if let filtered = filters.result(
                            for: draft,
                            source: model.image,
                            preview: true
                        ) {
                            context.draw(
                                Image(decorative: filtered.image, scale: 1)
                                    .interpolation(.none),
                                in: layout.viewRect(filtered.rect)
                            )
                        } else {
                            EditorDrawing.draw(
                                draft,
                                in: &context,
                                layout: layout,
                                source: model.image
                            )
                        }
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)

                if let hoverPoint, let diameter = brushRingDiameter(layout: layout) {
                    brushRing(diameter: diameter)
                        .position(hoverPoint)
                        .allowsHitTesting(false)
                }

                if model.tool == .crop, let crop = model.cropRect {
                    cropOverlay(crop, layout: layout)
                }

                // 取字模式：系统 Live Text 层盖在图像上，拖选文字 / ⌘C 复制；
                // 放在最后，确保它先于画布手势拿到鼠标事件。
                if model.isTextPicking {
                    LiveTextOverlay(image: model.image, store: model.liveTextStore)
                        .frame(
                            width: layout.imageRect.width,
                            height: layout.imageRect.height
                        )
                        .position(
                            x: layout.imageRect.midX,
                            y: layout.imageRect.midY
                        )
                }

                if let textDraft {
                    textEditor(textDraft, layout: layout)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(gesture(layout: layout))
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    updateHover(at: location, layout: layout)
                case .ended:
                    hoverPoint = nil
                    if case .idle = interaction {
                        setCursor(.arrow)
                    }
                }
            }
            .modifier(QuickCopyModifier(enabled: onQuickCopy != nil, action: quickCopy))
            .simultaneousGesture(
                SpatialTapGesture(count: 2, coordinateSpace: .local)
                    .onEnded { value in
                        editExistingText(at: value.location, layout: layout)
                    }
            )
        }
    }

    // MARK: - 文字

    /// 输入态：输入框自己就是最终样子（字号 / 文字色），背景块按最终几何画在它下面。
    ///
    /// 画布不画这条标註（见上面 `annotations` 循环里的 `continue`），因此打字过程中看到的
    /// 就是提交后的结果；几何全部来自 `TextEditingFrame`，与 `EditorDrawing` 的 `.text` 分支同源。
    private func textEditor(_ draft: TextDraft, layout: EditorCanvasLayout) -> some View {
        let frame = editingFrame(for: draft, layout: layout)
        let background = frame.annotation.textBackground
        let fieldWidth = frame.textSize.width + TextEditingFrame.caretAllowance
        // 用 `Group` 而不是再套一层 `ZStack`：两个子视图直接落在画布这层，
        // `.position` 才按画布坐标摆放（套一层的话坐标系变成那个小 ZStack）。
        return Group {
            if background.drawsBackground {
                RoundedRectangle(
                    cornerRadius: frame.annotation.textBackgroundCornerRadius * layout.scale
                )
                .fill(frame.annotation.style.color.color.opacity(background.fillOpacity))
                .frame(width: frame.boxRect.width, height: frame.boxRect.height)
                .position(x: frame.boxRect.midX, y: frame.boxRect.midY)
            }

            if draft.text.isEmpty {
                textPlaceholder(frame)
            }

            InlineTextEditor(
                text: textBinding,
                fontSize: frame.fontSize,
                textColor: frame.textColor,
                onSubmit: { commitTextEditing() },
                onCancel: { cancelTextEditing() }
            )
            // 宽度多留一个插入点的余量，否则字尾光标会被裁掉；这段不算进背景块。
            .frame(width: fieldWidth, height: frame.textSize.height)
            .position(
                x: frame.textOrigin.x + fieldWidth / 2,
                y: frame.textOrigin.y + frame.textSize.height / 2
            )
        }
    }

    /// 空输入时的提示文案：用同一个文字色降到 35% 透明度，不自带底色，不破所见即所得。
    private func textPlaceholder(_ frame: TextEditingFrame) -> some View {
        let text = "输入文字"
        let size = (text as NSString).size(withAttributes: [.font: Self.textFont(size: frame.fontSize)])
        let width = ceil(size.width)
        let height = ceil(size.height)
        return Text(text)
            .font(.system(size: frame.fontSize, weight: .semibold))
            .foregroundStyle(Color(nsColor: frame.textColor).opacity(0.35))
            .frame(width: width, height: height)
            .position(x: frame.textOrigin.x + width / 2, y: frame.textOrigin.y + height / 2)
            .allowsHitTesting(false)
    }

    /// 提示文案与输入框用同一个字体（只是取尺寸用）。
    private static func textFont(size: CGFloat) -> NSFont {
        .systemFont(ofSize: max(1, size), weight: .semibold)
    }

    /// 输入态几何 / 配色；点中判定的矩形也用它，保证「点到的就是看到的」。
    private func editingFrame(for draft: TextDraft, layout: EditorCanvasLayout) -> TextEditingFrame {
        TextEditingFrame(
            text: draft.text,
            origin: draft.origin,
            style: style(for: draft),
            layout: layout
        )
    }

    /// 输入态样式：新建文字跟着当前默认值走（输入中换颜色 / 字号 / 背景要立刻可见），
    /// 改已有文字保留它自己的样式——否则重输一遍会把这条标注的参数悄悄换掉。
    private func style(for draft: TextDraft) -> AnnotationStyle {
        draft.isNew ? model.textStyle : draft.style
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { textDraft?.text ?? "" },
            set: { newValue in
                textDraft?.text = newValue
            }
        )
    }

    private func beginTextEditing(at point: CGPoint, existing: EditorAnnotation?) {
        let style = existing?.style ?? model.activeStyle
        textDraft = TextDraft(
            id: existing?.id ?? UUID(),
            isNew: existing == nil,
            origin: existing?.start ?? point,
            text: existing?.text ?? "",
            style: style
        )
        draft = nil
    }

    private func commitTextEditing() {
        guard let draft = textDraft else { return }
        textDraft = nil
        let trimmed = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // 清空已有文字 = 删除这条标注；新建的空文字直接丢弃。
            if !draft.isNew {
                model.delete(id: draft.id)
            }
            return
        }
        var style = style(for: draft)
        if style.fontSize == nil {
            style.fontSize = 24
        }
        let annotation = EditorAnnotation(
            id: draft.id,
            kind: .text,
            start: draft.origin,
            end: draft.origin,
            text: trimmed,
            style: style
        )
        if draft.isNew {
            model.add(annotation)
        } else {
            model.update(annotation)
        }
    }

    private func cancelTextEditing() {
        textDraft = nil
    }

    /// 双击已有文字：直接回到输入态（不用先切到文字工具）。
    private func editExistingText(at viewPoint: CGPoint, layout: EditorCanvasLayout) {
        guard textDraft == nil,
              model.tool != .crop,
              layout.imageRect.contains(viewPoint),
              interactionRect?.contains(viewPoint) ?? true else {
            return
        }
        let point = clampedImagePoint(layout.imagePoint(viewPoint), layout: layout)
        guard let hit = hitAnnotation(at: point, layout: layout), hit.kind == .text else {
            return
        }
        beginTextEditing(at: hit.start, existing: hit)
    }

    private func quickCopy(at point: CGPoint) {
        // 不判工具：之前只在「无工具」态生效，但指针格已经不在操作条上，
        // 用户基本不会停留在那个隐藏状态，这条快速复制等于永远不触发。
        // 「一条标注都没有」才是真正的意图判定——那时双击空白只可能是想直接拿走截图。
        guard model.annotations.isEmpty else { return }
        if let interactionRect, !interactionRect.contains(point) {
            return
        }
        onQuickCopy?()
    }

    private func gesture(layout: EditorCanvasLayout) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if case .idle = interaction {
                    begin(at: value.startLocation, layout: layout)
                }
                update(to: value.location, layout: layout)
            }
            .onEnded { value in
                finish(at: value.location, layout: layout)
            }
    }

    private func begin(at viewPoint: CGPoint, layout: EditorCanvasLayout) {
        // 取字模式下画布不接管鼠标：手势留给 Live Text 层。
        guard !model.isTextPicking else {
            interaction = .idle
            return
        }
        // 点在输入框上：交给 NSTextField 自己处理（定位光标 / 拖选），结束编辑。
        if let textDraft,
           editingFrame(for: textDraft, layout: layout).boxRect.insetBy(dx: -4, dy: -4).contains(viewPoint) {
            interaction = .idle
            return
        }
        // 点画布其它位置 = 结束当前文字输入（先提交，不丢内容）。
        commitTextEditing()

        guard layout.imageRect.contains(viewPoint),
              interactionRect?.contains(viewPoint) ?? true else {
            interaction = .idle
            return
        }

        let point = clampedImagePoint(layout.imagePoint(viewPoint), layout: layout)
        let hit = hitAnnotation(at: point, layout: layout)

        if model.tool == .crop {
            beginCropping(at: point, viewPoint: viewPoint, layout: layout)
            return
        }

        if model.tool == .select {
            if let hit {
                model.select(hit.id)
                setCursor(.closedHand)
                interaction = .moving(
                    id: hit.id,
                    original: hit,
                    originalAnnotations: model.annotations,
                    start: point
                )
            } else {
                model.clearSelection()
                interaction = .idle
            }
            return
        }

        guard model.tool.annotationKind != nil else {
            interaction = .idle
            return
        }
        // 绘制时不保留旧选中框；是否新选中由松手时的判定决定。
        model.clearSelection()
        draft = nil
        interaction = .drawing(start: point, hitID: hit?.id)
    }

    private func update(to viewPoint: CGPoint, layout: EditorCanvasLayout) {
        // 按住拖动时系统可能不再派发 hover，这里用拖拽坐标维持笔刷圆圈；
        // 指针拖出图像范围时隐藏，避免圆圈停在边界上。
        if model.tool.annotationKind?.usesStrokePath == true {
            hoverPoint = layout.imageRect.insetBy(dx: -6, dy: -6).contains(viewPoint)
                ? viewPoint
                : nil
        }
        let point = clampedImagePoint(layout.imagePoint(viewPoint), layout: layout)

        switch interaction {
        case .idle:
            break
        case .drawing(let start, _):
            guard let kind = model.tool.annotationKind else { return }
            // 文字与序号都不靠拖拽创建：按下点就是落点，松手时生成。
            guard kind != .text, kind != .number else { return }
            if draft == nil {
                // 超过最小位移才算「绘制」，避免单击已有标注时闪出一个点。
                guard distance(start, point) > movementThreshold(layout: layout) else {
                    return
                }
                draft = EditorAnnotation(
                    kind: kind,
                    start: start,
                    end: point,
                    points: [start],
                    style: model.activeStyle
                )
            }
            guard var annotation = draft else { return }
            if annotation.kind.usesStrokePath {
                if annotation.points.last != point {
                    annotation.points.append(point)
                }
                annotation.end = point
            } else {
                annotation.end = constrainedEnd(
                    from: annotation.start,
                    to: point,
                    kind: annotation.kind
                )
            }
            draft = annotation
        case .moving(let id, let original, let originalAnnotations, let start):
            let delta = CGPoint(x: point.x - start.x, y: point.y - start.y)
            let moved = original.offsetBy(dx: delta.x, dy: delta.y)
            let updated = originalAnnotations.map { $0.id == id ? moved : $0 }
            model.replaceLive(updated)
        case .creatingCrop(let anchor):
            model.updateCropRect(cropRect(from: anchor, to: point))
        case .resizingCrop(let handle, let original, _):
            // 拖出热区后仍显示该方向的缩放箭头，否则中途会跳回十字。
            setCursor(.resizing(handle.axis))
            let aspect = NSEvent.modifierFlags.contains(.shift)
                ? original.width / max(original.height, 1)
                : nil
            model.updateCropRect(resizedRect(original, handle: handle, to: point, aspect: aspect))
        case .movingCrop(let original, let start):
            setCursor(.closedHand)
            model.updateCropRect(movedRect(original, by: CGPoint(
                x: point.x - start.x,
                y: point.y - start.y
            )))
        }
    }

    private func finish(at viewPoint: CGPoint, layout: EditorCanvasLayout) {
        update(to: viewPoint, layout: layout)
        switch interaction {
        case .drawing(let start, let hitID):
            if let annotation = draft, isValid(annotation) {
                model.add(annotation)
            } else if model.tool == .number {
                // 序号工具：单击即落一个自动递增的徽章。
                model.addNumber(at: start)
            } else if model.tool == .text {
                // 文字工具：单击定位，命中已有文字则直接改它。
                beginTextEditing(at: start, existing: hittingText(hitID))
            } else if let hitID {
                // 单击已有标注：只选中它。工具**保持不动**——指针格已经不在操作条上，
                // 再自动跳回 `select` 在界面上只表现为「当前工具高亮无声地没了」，像是 bug。
                model.select(hitID)
            }
            draft = nil
        case .moving(_, _, let originalAnnotations, _):
            if originalAnnotations != model.annotations {
                model.commitLiveChange(
                    from: originalAnnotations,
                    actionName: "移动标注"
                )
            }
        case .creatingCrop, .resizingCrop:
            // 框太小（误触 / 拖到图外）时回到拖动前的裁剪框，避免出现 1 px 的怪框。
            if let crop = model.cropRect,
               crop.width < Self.minimumCropSize || crop.height < Self.minimumCropSize,
               let baseline = cropBaseline {
                model.updateCropRect(baseline)
            }
            cropBaseline = nil
        case .movingCrop:
            cropBaseline = nil
        case .idle:
            break
        }
        interaction = .idle
        // 松手后按当前指针位置恢复手形 / 十字光标。
        updateHover(at: viewPoint, layout: layout)
    }

    // MARK: - 裁剪

    private func beginCropping(
        at point: CGPoint,
        viewPoint: CGPoint,
        layout: EditorCanvasLayout
    ) {
        model.clearSelection()
        let current = model.cropRect ?? CGRect(origin: .zero, size: model.imageSize)
        cropBaseline = current

        if let handle = cropHandle(at: viewPoint, crop: current, layout: layout) {
            setCursor(.crosshair)
            interaction = .resizingCrop(handle: handle, original: current, start: point)
            return
        }
        // 框还是整幅（初始态）时，框内拖动就是拉新框；否则框内拖动 = 平移整个框。
        if !model.isCropRectFullFrame, layout.viewRect(current).contains(viewPoint) {
            setCursor(.closedHand)
            interaction = .movingCrop(original: current, start: point)
            return
        }
        // 框外（或整幅初始态）按下 = 重新拉一个框；先给 1 px 占位，拖太小会在松手时回退到原框。
        setCursor(.crosshair)
        interaction = .creatingCrop(anchor: point)
        model.updateCropRect(
            CGRect(origin: point, size: CGSize(width: 1, height: 1))
        )
    }

    /// 拖拽建立的裁剪框；按住 `⇧` 约束为正方形。
    private func cropRect(from anchor: CGPoint, to point: CGPoint) -> CGRect {
        var rect = CGRect(
            x: min(anchor.x, point.x),
            y: min(anchor.y, point.y),
            width: abs(point.x - anchor.x),
            height: abs(point.y - anchor.y)
        )
        guard NSEvent.modifierFlags.contains(.shift) else { return rect }
        let side = max(rect.width, rect.height)
        rect.size = CGSize(width: side, height: side)
        if point.x < anchor.x {
            rect.origin.x = anchor.x - side
        }
        if point.y < anchor.y {
            rect.origin.y = anchor.y - side
        }
        return rect
    }

    /// 手柄拖拽：被拖动的边跟着指针走，对边固定；按住 `⇧` 以框中心保持原始纵横比。
    private func resizedRect(
        _ original: CGRect,
        handle: CropHandle,
        to point: CGPoint,
        aspect: CGFloat?
    ) -> CGRect {
        var rect = original
        switch handle {
        case .topLeft:
            rect = CGRect(
                x: point.x, y: point.y,
                width: original.maxX - point.x, height: original.maxY - point.y
            )
        case .top:
            rect = CGRect(
                x: original.minX, y: point.y,
                width: original.width, height: original.maxY - point.y
            )
        case .topRight:
            rect = CGRect(
                x: original.minX, y: point.y,
                width: point.x - original.minX, height: original.maxY - point.y
            )
        case .leading:
            rect = CGRect(
                x: point.x, y: original.minY,
                width: original.maxX - point.x, height: original.height
            )
        case .trailing:
            rect = CGRect(
                x: original.minX, y: original.minY,
                width: point.x - original.minX, height: original.height
            )
        case .bottomLeft:
            rect = CGRect(
                x: point.x, y: original.minY,
                width: original.maxX - point.x, height: point.y - original.minY
            )
        case .bottom:
            rect = CGRect(
                x: original.minX, y: original.minY,
                width: original.width, height: point.y - original.minY
            )
        case .bottomRight:
            rect = CGRect(
                x: original.minX, y: original.minY,
                width: point.x - original.minX, height: point.y - original.minY
            )
        }

        var standardized = rect.standardized
        guard let aspect, aspect > 0,
              standardized.width >= 1, standardized.height >= 1 else {
            return standardized
        }
        if standardized.width / standardized.height > aspect {
            let height = standardized.width / aspect
            standardized.origin.y -= (height - standardized.height) / 2
            standardized.size.height = height
        } else {
            let width = standardized.height * aspect
            standardized.origin.x -= (width - standardized.width) / 2
            standardized.size.width = width
        }
        return standardized
    }

    /// 平移裁剪框：保持尺寸，只在图像内平移（到边界就停住，不缩框）。
    private func movedRect(_ original: CGRect, by delta: CGPoint) -> CGRect {
        var moved = original.offsetBy(dx: delta.x.rounded(), dy: delta.y.rounded())
        moved.origin.x = min(max(moved.minX, 0), max(0, model.imageSize.width - moved.width))
        moved.origin.y = min(max(moved.minY, 0), max(0, model.imageSize.height - moved.height))
        return moved
    }

    /// 命中的裁剪手柄；热区判定与选区手柄共用 `ResizeHitZone`
    /// （角优先、半径与画出来的小方块对齐，避免「看得到手柄却抓不住」）。
    private func cropHandle(
        at viewPoint: CGPoint,
        crop: CGRect,
        layout: EditorCanvasLayout
    ) -> CropHandle? {
        guard let axis = ResizeHitZone.axis(at: viewPoint, in: layout.viewRect(crop)) else {
            return nil
        }
        return CropHandle(axis: axis)
    }

    /// 裁剪框：压暗框外 + 白边 + 8 个手柄 + 尺寸标签（跟随框顶边）。
    private func cropOverlay(_ crop: CGRect, layout: EditorCanvasLayout) -> some View {
        let rect = layout.viewRect(crop)
        let imageRect = layout.imageRect
        let handles: [CGPoint] = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.midY),
            CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.midX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY),
        ]
        let labelY = max(imageRect.minY + 14, rect.minY - 16)
        let labelX = min(
            max(rect.midX, imageRect.minX + 64),
            imageRect.maxX - 64
        )

        return ZStack {
            Path { path in
                path.addRect(imageRect)
                path.addRect(rect)
            }
            .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))

            Rectangle()
                .strokeBorder(Color.white, lineWidth: 1)
                .frame(width: max(1, rect.width), height: max(1, rect.height))
                .position(x: rect.midX, y: rect.midY)

            ForEach(handles.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 1)
                            .strokeBorder(Color.black.opacity(0.3), lineWidth: 0.5)
                    )
                    .frame(width: 7, height: 7)
                    .position(handles[index])
            }

            Text("\(Int(crop.width)) × \(Int(crop.height)) px")
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .glassSurface(.regular, contrast: .elevated, in: Capsule())
                .position(x: labelX, y: labelY)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - 笔刷圆圈与光标

    /// 绘制工具的笔刷直径（视图坐标）；其它工具返回 `nil`。
    private func brushRingDiameter(layout: EditorCanvasLayout) -> CGFloat? {
        guard model.tool.annotationKind?.usesStrokePath == true else { return nil }
        let diameter = model.activeStyle.lineWidth * max(layout.scale, 0.01)
        return max(10, diameter)
    }

    private func brushRing(diameter: CGFloat) -> some View {
        ZStack {
            Circle()
                .strokeBorder(Color.black.opacity(0.55), lineWidth: 2.5)
            Circle()
                .strokeBorder(Color.white.opacity(0.95), lineWidth: 1)
        }
        .frame(width: diameter, height: diameter)
    }

    private func updateHover(at location: CGPoint, layout: EditorCanvasLayout) {
        let isPaintTool = model.tool.annotationKind?.usesStrokePath == true
        if isPaintTool,
           layout.imageRect.insetBy(dx: -6, dy: -6).contains(location) {
            hoverPoint = location
        } else {
            hoverPoint = nil
        }

        // 拖拽中的光标由拖拽流程自己维护（closedHand）。
        guard case .idle = interaction else { return }

        if model.tool == .crop {
            guard let crop = model.cropRect else {
                setCursor(.crosshair)
                return
            }
            // 手柄 = 该方向的缩放箭头；框内 = 可拖动（抓手）；框外 = 拉新框（十字）。
            // 以前手柄处也是十字，看不出「抓住哪个角能等比缩放」。
            if let handle = cropHandle(at: location, crop: crop, layout: layout) {
                setCursor(.resizing(handle.axis))
                return
            }
            let inside = !model.isCropRectFullFrame
                && layout.viewRect(crop).contains(location)
            setCursor(inside ? .openHand : .crosshair)
            return
        }

        if model.tool == .select, hoveredAnnotation(at: location, layout: layout) != nil {
            setCursor(.openHand)
        } else if isPaintTool, hoverPoint != nil {
            setCursor(.crosshair)
        } else {
            setCursor(.arrow)
        }
    }

    private func hoveredAnnotation(
        at viewPoint: CGPoint,
        layout: EditorCanvasLayout
    ) -> EditorAnnotation? {
        guard layout.imageRect.contains(viewPoint) else { return nil }
        let point = clampedImagePoint(layout.imagePoint(viewPoint), layout: layout)
        return hitAnnotation(at: point, layout: layout)
    }

    /// 唯一的「改光标」入口：映射统一走 `PointerCursor`，不再散写 `NSCursor.xxx.set()`。
    private func setCursor(_ kind: PointerCursor) {
        guard cursor != kind else { return }
        cursor = kind
        kind.apply()
    }

    private func clampedImagePoint(
        _ point: CGPoint,
        layout: EditorCanvasLayout
    ) -> CGPoint {
        CGPoint(
            x: min(max(point.x, 0), model.imageSize.width),
            y: min(max(point.y, 0), model.imageSize.height)
        )
    }

    /// 顶部优先命中：后画的标注盖在上面，先命中它。
    /// 容差按当前缩放换算成屏幕约 7 pt，缩小时也不会「点不中」。
    private func hitAnnotation(
        at point: CGPoint,
        layout: EditorCanvasLayout
    ) -> EditorAnnotation? {
        let tolerance = 7 / max(layout.scale, 0.01)
        return model.annotations.reversed().first { $0.hitTest(point, tolerance: tolerance) }
    }

    private func hittingText(_ id: UUID?) -> EditorAnnotation? {
        guard let id else { return nil }
        return model.annotations.first { $0.id == id && $0.kind == .text }
    }

    private func movementThreshold(layout: EditorCanvasLayout) -> CGFloat {
        max(0.5, 1.5 / max(layout.scale, 0.01))
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private func constrainedEnd(
        from start: CGPoint,
        to end: CGPoint,
        kind: AnnotationKind
    ) -> CGPoint {
        guard NSEvent.modifierFlags.contains(.shift) else {
            return end
        }

        if kind == .rectangle || kind == .ellipse || kind == .spotlight || kind == .magnifier {
            let rect = SelectionGeometry.rect(
                from: start,
                to: end,
                lockAspect: true,
                fromCenter: false
            )
            return CGPoint(
                x: rect.maxX,
                y: rect.maxY
            )
        }

        if kind == .line || kind == .arrow {
            let dx = end.x - start.x
            let dy = end.y - start.y
            let length = hypot(dx, dy)
            guard length > 0 else { return end }
            let step = CGFloat.pi / 4
            let angle = (atan2(dy, dx) / step).rounded() * step
            return CGPoint(
                x: start.x + cos(angle) * length,
                y: start.y + sin(angle) * length
            )
        }

        return end
    }

    private func isValid(_ annotation: EditorAnnotation) -> Bool {
        if annotation.kind.usesStrokePath {
            return annotation.points.count > 1
        }
        return abs(annotation.end.x - annotation.start.x) >= 1
            || abs(annotation.end.y - annotation.start.y) >= 1
    }
}

/// 裁剪框的 8 个手柄。
private enum CropHandle {
    case topLeft
    case top
    case topRight
    case leading
    case trailing
    case bottomLeft
    case bottom
    case bottomRight

    /// 光标提示用的统一方向。
    var axis: ResizeAxis {
        switch self {
        case .topLeft: return .topLeading
        case .top: return .top
        case .topRight: return .topTrailing
        case .leading: return .leading
        case .trailing: return .trailing
        case .bottomLeft: return .bottomLeading
        case .bottom: return .bottom
        case .bottomRight: return .bottomTrailing
        }
    }

    /// 由统一方向反查手柄（热区判定只产出方向）。
    init(axis: ResizeAxis) {
        switch axis {
        case .topLeading: self = .topLeft
        case .top: self = .top
        case .topTrailing: self = .topRight
        case .leading: self = .leading
        case .trailing: self = .trailing
        case .bottomLeading: self = .bottomLeft
        case .bottom: self = .bottom
        case .bottomTrailing: self = .bottomRight
        }
    }
}

private enum Interaction {
    case idle
    /// 绘制工具的按下状态；`hitID` 记录按下点命中的已有标注，用于「单击选中」。
    case drawing(start: CGPoint, hitID: UUID?)
    case moving(
        id: UUID,
        original: EditorAnnotation,
        originalAnnotations: [EditorAnnotation],
        start: CGPoint
    )
    /// 裁剪：框外拉起新框（`anchor` 为固定角）。
    case creatingCrop(anchor: CGPoint)
    /// 裁剪：拖动手柄，`original` 为拖拽前的框。
    case resizingCrop(handle: CropHandle, original: CGRect, start: CGPoint)
    /// 裁剪：在框内拖动整体平移。
    case movingCrop(original: CGRect, start: CGPoint)
}

/// 文字输入会话：`origin` 是图像坐标的文字左上角。
private struct TextDraft: Equatable {
    var id: UUID
    var isNew: Bool
    var origin: CGPoint
    var text: String
    var style: AnnotationStyle
}

/// 双击快捷复制：只在浮层启用，且与拖拽手势并行，不干扰绘制。
private struct QuickCopyModifier: ViewModifier {
    let enabled: Bool
    let action: (CGPoint) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.simultaneousGesture(
                SpatialTapGesture(count: 2, coordinateSpace: .local)
                    .onEnded { value in action(value.location) }
            )
        } else {
            content
        }
    }
}
