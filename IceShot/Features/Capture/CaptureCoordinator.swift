import AppKit
import Observation

/// 截图流程的总协调器：权限预检 → 冻结帧 → 选区 / 窗口选择 → 就地编辑 → 收尾。
///
/// 所有入口（菜单、菜单栏、全局快捷键、重复上次区域）都收敛到这里，
/// 用 `state` 保证同一时间只跑一个截图流程；依赖通过 init 注入，便于测试替身。
@MainActor
@Observable
final class CaptureCoordinator {
    /// 截图流程的互斥状态；UI 据此禁用重复入口与显示提示。
    enum State: Equatable {
        case idle
        case preparing
        case selecting
        case selectingWindow
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var permissionStatus: ScreenRecordingPermissionStatus = .notDetermined
    private(set) var lastMessage: String?

    private let permission: ScreenRecordingPermissionChecking
    private let capture: ScreenCapturing
    private let windowCatalog: WindowCatalogProviding
    private let overlay: SelectionOverlayPresenting
    private let windowOverlay: WindowSelectionOverlayPresenting
    private let clipboard: ClipboardWriter
    private let countdown: CountdownPresenting
    private let lastRegion: LastRegionStoring
    private let history: HistorySaving?
    private let pins: PinBoard?
    private let editor: EditorOpening?
    private let scrollHUD: ScrollCaptureHUDController
    private let scrollFrame = ScrollCaptureFrameController()
    private let feedback: FeedbackHUDController
    private var scrollSession: ScrollCaptureSession?
    private var previousApplication: NSRunningApplication?
    private var didActivateForCapture = false
    /// 防止连点把同一次窗口抓取提交成两次（抓取是 async 的，浮层在这期间仍可点）。
    private var isPickingWindow = false
    private var pendingSource: ScreenshotSource = .region
    private var pendingAllDisplays: (images: [CGImage], index: Int)?

    init(
        permission: ScreenRecordingPermissionChecking,
        capture: ScreenCapturing,
        windowCatalog: WindowCatalogProviding,
        overlay: SelectionOverlayPresenting,
        windowOverlay: WindowSelectionOverlayPresenting,
        clipboard: ClipboardWriter,
        countdown: CountdownPresenting,
        lastRegion: LastRegionStoring,
        history: HistorySaving?,
        pins: PinBoard? = nil,
        editor: EditorOpening? = nil,
        scrollHUD: ScrollCaptureHUDController? = nil,
        feedback: FeedbackHUDController
    ) {
        self.permission = permission
        self.capture = capture
        self.windowCatalog = windowCatalog
        self.overlay = overlay
        self.windowOverlay = windowOverlay
        self.clipboard = clipboard
        self.countdown = countdown
        self.lastRegion = lastRegion
        self.history = history
        self.pins = pins
        self.editor = editor
        self.scrollHUD = scrollHUD ?? ScrollCaptureHUDController()
        self.feedback = feedback
        refreshPermission()
    }

    convenience init(
        history: HistorySaving? = nil,
        pins: PinBoard? = nil,
        editor: EditorOpening? = nil,
        feedback: FeedbackHUDController? = nil
    ) {
        let capture = ScreenCaptureService()
        let hud = feedback ?? FeedbackHUDController()
        self.init(
            permission: ScreenRecordingPermission(),
            capture: capture,
            windowCatalog: capture,
            overlay: SelectionOverlayController(feedback: hud),
            windowOverlay: WindowSelectionOverlayController(),
            clipboard: ClipboardWriter(),
            countdown: CountdownHUDController(),
            lastRegion: LastRegionStore(),
            history: history,
            pins: pins,
            editor: editor,
            feedback: hud
        )
    }

    var isBusy: Bool {
        switch state {
        case .preparing, .selecting, .selectingWindow:
            return true
        case .idle, .failed:
            return false
        }
    }

    var isSelecting: Bool {
        state == .selecting || state == .selectingWindow
    }

    var permissionSummary: String {
        switch permissionStatus {
        case .authorized:
            return "屏幕录制权限：已授权"
        case .notDetermined:
            return "屏幕录制权限：尚未申请"
        case .denied:
            return "屏幕录制权限：未授权"
        }
    }

    func refreshPermission() {
        permissionStatus = permission.status()
    }

    func requestPermission() async -> ScreenRecordingPermissionStatus {
        let status = await permission.request()
        permissionStatus = status
        return status
    }

    func openPermissionSettings() {
        permission.openSystemSettings()
    }

    func cancelCurrentSelection() {
        if scrollSession != nil {
            cancelScrollCapture()
            return
        }
        guard isSelecting else { return }
        overlay.dismiss()
        windowOverlay.dismiss()
        pendingAllDisplays = nil
        restorePreviousApplication()
        state = .idle
    }

    func startRegionCapture(
        delay: Duration = .zero,
        countdownSeconds: Int = 0
    ) async {
        guard await prepareForCapture(delay: delay) else {
            return
        }
        guard await runCountdown(countdownSeconds) else {
            return
        }

        do {
            let frames = try await capture.captureDisplayFrames()
            guard !frames.isEmpty else {
                throw CaptureError.noDisplays
            }
            // 窗口目录是「能不能点窗口」的加分项：取不到就降级成纯框选，不打断区域截图。
            let windows = (try? await windowCatalog.windowCatalog()) ?? []

            state = .selecting
            activateForOverlay()
            presentOverlay(frames: frames, preset: nil, source: .region, windows: windows)
        } catch is CancellationError {
            restorePreviousApplication()
            state = .idle
        } catch {
            restorePreviousApplication()
            state = .failed(message(for: error))
        }
    }

    func startWindowCapture(
        delay: Duration = .zero,
        countdownSeconds: Int = 0
    ) async {
        guard await prepareForCapture(delay: delay) else {
            return
        }
        guard await runCountdown(countdownSeconds) else {
            return
        }

        do {
            let frames = try await capture.captureDisplayFrames()
            guard !frames.isEmpty else {
                throw CaptureError.noDisplays
            }
            let windows = try await windowCatalog.windowCatalog()

            state = .selectingWindow
            activateForOverlay()
            windowOverlay.present(
                frames: frames,
                windows: windows,
                onPick: { [weak self] window in
                    guard let self else { return }
                    Task {
                        await self.presentWindowEditor(window: window, frames: frames)
                    }
                },
                onCancel: { [weak self] in
                    self?.restorePreviousApplication()
                    self?.state = .idle
                }
            )
        } catch is CancellationError {
            restorePreviousApplication()
            state = .idle
        } catch {
            restorePreviousApplication()
            state = .failed(message(for: error))
        }
    }

    func startFullScreenCapture(
        delay: Duration = .zero,
        countdownSeconds: Int = 0
    ) async {
        guard await prepareForCapture(delay: delay) else {
            return
        }
        guard await runCountdown(countdownSeconds) else {
            return
        }

        do {
            let displays = ScreenGeometry.makeDescriptors()
            guard let display = currentDisplay(from: displays) else {
                throw CaptureError.noDisplays
            }
            let image = try await capture.captureDisplay(display.id)
            let frames = [DisplayFrame(display: display, image: image)]
            let preset = SelectionPreset(
                displayID: display.id,
                rect: CGRect(origin: .zero, size: display.pointSize),
                image: image
            )
            presentEditor(frames: frames, preset: preset, source: .display)
        } catch is CancellationError {
            restorePreviousApplication()
            state = .idle
        } catch {
            restorePreviousApplication()
            state = .failed(message(for: error))
        }
    }

    /// 长截图：先框选区域，再让用户自己滚动，IceShot 反复抓同一块区域并拼接。
    /// 会重复抓屏，但只在用户主动进入、且限定选区内进行。
    func startScrollCapture(delay: Duration = .zero) async {
        if let session = scrollSession, session.isRunning {
            // 采集中再按一次快捷键 = 结束并出图。
            completeScrollCapture()
            return
        }
        guard await prepareForCapture(delay: delay) else {
            return
        }

        do {
            let frames = try await capture.captureDisplayFrames()
            guard !frames.isEmpty else {
                throw CaptureError.noDisplays
            }
            state = .selecting
            activateForOverlay()
            presentOverlay(frames: frames, preset: nil, source: .scroll)
        } catch is CancellationError {
            restorePreviousApplication()
            state = .idle
        } catch {
            restorePreviousApplication()
            state = .failed(message(for: error))
        }
    }

    func startRepeatLastRegion(
        delay: Duration = .zero,
        countdownSeconds: Int = 0
    ) async {
        guard let region = lastRegion.load(),
              let display = ScreenGeometry.makeDescriptors().first(where: {
                  $0.id == region.displayID
              }),
              region.isValid(for: display) else {
            // 没有上次区域，或显示器 / 分辨率已变化：回退到区域选择。
            await startRegionCapture(
                delay: delay,
                countdownSeconds: countdownSeconds
            )
            return
        }

        guard await prepareForCapture(delay: delay) else {
            return
        }
        guard await runCountdown(countdownSeconds) else {
            return
        }

        do {
            let image = try await capture.captureDisplay(display.id)
            let pixelRect = ScreenGeometry.pixelRect(
                fromDisplayLocal: region.rect,
                scale: display.scale
            )
            let cropped = try ImageCropper.crop(image, to: pixelRect)
            let frames = [DisplayFrame(display: display, image: image)]
            let preset = SelectionPreset(
                displayID: display.id,
                rect: region.rect,
                image: cropped
            )
            presentEditor(frames: frames, preset: preset, source: .region)
        } catch is CancellationError {
            restorePreviousApplication()
            state = .idle
        } catch {
            restorePreviousApplication()
            state = .failed(message(for: error))
        }
    }

    func startAllDisplaysCapture(
        delay: Duration = .zero,
        countdownSeconds: Int = 0
    ) async {
        guard await prepareForCapture(delay: delay) else {
            return
        }
        guard await runCountdown(countdownSeconds) else {
            return
        }

        do {
            let frames = try await capture.captureDisplayFrames()
            guard !frames.isEmpty else {
                throw CaptureError.noDisplays
            }
            let images = frames.map(\.image)
            let currentIndex = frames.firstIndex {
                $0.display.appKitFrame.contains(NSEvent.mouseLocation)
            } ?? 0
            let current = frames[currentIndex]
            pendingAllDisplays = (images: images, index: currentIndex)
            let preset = SelectionPreset(
                displayID: current.display.id,
                rect: CGRect(origin: .zero, size: current.display.pointSize),
                image: images[currentIndex]
            )
            presentEditor(frames: frames, preset: preset, source: .allDisplays)
        } catch is CancellationError {
            restorePreviousApplication()
            state = .idle
        } catch {
            restorePreviousApplication()
            state = .failed(message(for: error))
        }
    }

    // MARK: - 窗口截图 → 就地编辑

    /// 窗口图像的来源。
    private enum WindowPresetMode {
        /// 所见即所得：从冻结帧裁该窗口可见区域（框选浮层里的点击）。
        case whatYouSee
        /// 抓窗口自身，能拿到被遮挡的完整内容（独立窗口入口）。
        case fullWindow
    }

    /// 窗口选择模式（`⇧⌘K`）：点中即抓这扇窗的**完整内容**。
    private func presentWindowEditor(
        window: WindowDescriptor,
        frames: [DisplayFrame]
    ) async {
        guard state == .selectingWindow else { return }
        do {
            let picked = try await windowPreset(
                for: window,
                frames: frames,
                mode: .fullWindow
            )
            guard state == .selectingWindow else { return }
            presentEditor(frames: frames, preset: picked.preset, source: picked.source)
        } catch is CancellationError {
            restorePreviousApplication()
            state = .idle
        } catch {
            restorePreviousApplication()
            state = .failed(message(for: error))
        }
    }

    /// 框选浮层里点中了高亮窗口：抓这扇窗（浮层盖着也能抓）后进就地编辑。
    ///
    /// 浮层保持可见直到窗口图就绪，避免中间闪过一帧桌面；抓取失败不结束本次截图，
    /// 提示后用户可以直接改拖拽框选。
    private func pickWindowFromRegion(
        _ window: WindowDescriptor,
        frames: [DisplayFrame]
    ) {
        guard !isPickingWindow else { return }
        isPickingWindow = true
        Task { [weak self] in
            await self?.presentPickedWindow(window, frames: frames)
            self?.isPickingWindow = false
        }
    }

    private func presentPickedWindow(
        _ window: WindowDescriptor,
        frames: [DisplayFrame]
    ) async {
        guard state == .selecting else { return }
        do {
            let picked = try await windowPreset(
                for: window,
                frames: frames,
                mode: .whatYouSee
            )
            guard state == .selecting else { return }
            presentEditor(frames: frames, preset: picked.preset, source: picked.source)
        } catch {
            guard state == .selecting else { return }
            lastMessage = "这块区域截取失败，可继续拖拽框选"
            feedback.show("截取失败")
        }
    }

    /// 抓一扇窗并算出它在显示器上的选区与历史来源。
    ///
    /// `mode` 决定图像从哪来：
    /// - `.whatYouSee`（框选浮层里点击）：从冻结帧裁该窗口可见区域，**所见即所得**——
    ///   叠在上面的通知、菜单、其他窗口都会一并截到，和悬停高亮看到的一致。
    /// - `.fullWindow`（独立窗口入口 `⇧⌘K`）：单独抓窗口自身，能拿到被遮挡的完整内容。
    private func windowPreset(
        for window: WindowDescriptor,
        frames: [DisplayFrame],
        mode: WindowPresetMode
    ) async throws -> (preset: SelectionPreset, source: ScreenshotSource) {
        // 桌面 / 菜单栏没有可靠的独立窗口图，只能用冻结帧裁切。
        if window.isSystemSurface || mode == .whatYouSee {
            guard let preset = systemSurfacePreset(for: window, frames: frames) else {
                throw CaptureError.invalidSelection
            }
            return (preset, window.isMenuBarSurface ? .window : windowSource(window))
        }

        let image = try await capture.captureWindow(window.id, includeShadow: false)
        guard let geometry = WindowPresetGeometry.make(
            windowFrame: window.frame,
            imageSize: CGSize(width: image.width, height: image.height),
            displays: frames.map(\.display)
        ) else {
            throw CaptureError.invalidSelection
        }
        let cropped = try ImageCropper.crop(image, to: geometry.imagePixelRect)
        let preset = SelectionPreset(
            displayID: geometry.displayID,
            rect: geometry.displayLocalRect,
            image: cropped
        )
        return (preset, .window)
    }

    /// 系统表面（桌面 / 菜单栏）的历史来源：菜单栏算窗口，其余（桌面）算全屏图。
    private func windowSource(_ window: WindowDescriptor) -> ScreenshotSource {
        window.isDesktopSurface ? .display : .window
    }

    private func systemSurfacePreset(
        for window: WindowDescriptor,
        frames: [DisplayFrame]
    ) -> SelectionPreset? {
        guard let display = WindowPresetGeometry.bestDisplay(
            for: window.frame,
            in: frames.map(\.display)
        ),
            let frame = frames.first(where: { $0.display.id == display.id }),
            let rect = WindowPresetGeometry.systemSurfaceRect(
                windowFrame: window.frame,
                display: display
            ) else {
            return nil
        }
        let pixelRect = ScreenGeometry.pixelRect(
            fromDisplayLocal: rect,
            scale: display.scale
        )
        guard let cropped = try? ImageCropper.crop(frame.image, to: pixelRect) else {
            return nil
        }
        return SelectionPreset(displayID: display.id, rect: rect, image: cropped)
    }

    // MARK: - 浮层与收尾

    private func presentOverlay(
        frames: [DisplayFrame],
        preset: SelectionPreset?,
        source: ScreenshotSource,
        windows: [WindowDescriptor] = []
    ) {
        pendingSource = source
        overlay.present(
            frames: frames,
            preset: preset,
            autoEditOnSelection: source != .scroll,
            windows: windows,
            onWindowPick: { [weak self] window in
                self?.pickWindowFromRegion(window, frames: frames)
            },
            onFinish: { [weak self] finish in
                self?.handleFinish(finish)
            },
            onCancel: { [weak self] in
                self?.pendingAllDisplays = nil
                self?.restorePreviousApplication()
                self?.state = .idle
            }
        )
    }

    private func presentEditor(
        frames: [DisplayFrame],
        preset: SelectionPreset,
        source: ScreenshotSource
    ) {
        state = .selecting
        activateForOverlay()
        presentOverlay(frames: frames, preset: preset, source: source)
    }

    private func handleFinish(_ finish: SelectionFinish) {
        let source = pendingSource
        let batch = pendingAllDisplays
        pendingAllDisplays = nil

        if source == .region {
            lastRegion.save(
                LastRegion(
                    displayID: finish.result.frame.display.id,
                    rect: finish.result.rect,
                    scale: finish.result.frame.display.scale
                )
            )
        }

        // 长截图：选区确定后不落历史、不进标注，先开始连续抓取。
        if source == .scroll {
            if finish.action == .close {
                restorePreviousApplication()
                state = .idle
            } else {
                // 先把前台还给被截的 App，再开始采集：
                // 框选浮层是 IceShot 的 `.screenSaver` 层级 NSPanel，它关闭时如果 IceShot 仍是
                // 前台，IceShot 自己的常规窗口（设置 / 历史）会随之露出来，正挡在用户框好的区域上。
                // 顺序不能换：先激活自己再恢复对方，恢复会被丢掉。
                restorePreviousApplication()
                beginScrollCapture(
                    displayID: finish.result.frame.display.id,
                    rect: finish.result.rect
                )
            }
            return
        }

        let historyImages = source == .allDisplays ? (batch?.images ?? [finish.original]) : [finish.original]

        switch finish.action {
        case .copy:
            if let output = finish.output {
                copyResult(output, isBatch: (batch?.images.count ?? 0) > 1)
            }
        case .save:
            if let output = finish.output {
                saveResult(output, batch: batch)
            }
        case .pin:
            if let output = finish.output {
                pinResult(output, finish: finish)
            }
        case .close:
            break
        }

        Task { [weak self] in
            await self?.recordHistory(historyImages, source: source)
        }

        restorePreviousApplication()
        state = .idle
    }

    // MARK: - 长截图会话

    private func beginScrollCapture(displayID: CGDirectDisplayID, rect: CGRect) {
        let session = ScrollCaptureSession(
            capture: capture,
            displayID: displayID,
            rect: rect
        )
        scrollSession = session

        let anchor = CGPoint(
            x: rect.midX,
            y: rect.minY
        )
        // 选区浮层已关闭：用一圈点击穿透的边框标出正在抓取的范围。
        scrollFrame.present(
            screenRect: screenRect(for: rect, displayID: displayID)
        )
        scrollHUD.present(
            near: screenPoint(for: anchor, displayID: displayID),
            onFinish: { [weak self] in
                self?.completeScrollCapture()
            },
            onCancel: { [weak self] in
                self?.cancelScrollCapture()
            }
        )

        session.onUpdate = { [weak self] status in
            self?.scrollHUD.update(status)
        }
        session.onFinish = { [weak self] image in
            self?.finishScrollCapture(with: image)
        }
        session.onCancel = { [weak self] in
            self?.cancelScrollCapture()
        }
        session.start()
    }

    private func completeScrollCapture() {
        scrollSession?.finish()
    }

    private func cancelScrollCapture() {
        scrollSession = nil
        scrollFrame.dismiss()
        scrollHUD.dismiss()
        restorePreviousApplication()
        state = .idle
    }

    private func finishScrollCapture(with image: CGImage) {
        scrollSession = nil
        scrollFrame.dismiss()
        scrollHUD.dismiss()
        // 长图要交给用户继续编辑：不要把前台还给被截的 App，否则编辑器会被挡住。
        // 只清掉「为浮层激活过」的标记，不执行激活。
        didActivateForCapture = false
        previousApplication = nil
        state = .idle
        editor?.open(image: image, title: "长截图")
        Task { [weak self] in
            await self?.recordHistory([image], source: .scroll)
        }
    }

    /// 选区在某块屏上的屏幕矩形（AppKit 坐标，左下原点）。
    private func screenRect(for rect: CGRect, displayID: CGDirectDisplayID) -> CGRect {
        guard let descriptor = ScreenGeometry.makeDescriptors().first(where: {
            $0.id == displayID
        }) else {
            return .zero
        }
        return CGRect(
            x: descriptor.appKitFrame.minX + rect.minX,
            y: descriptor.appKitFrame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// 选区在某块屏上的局部坐标 → AppKit 屏幕坐标（y 向上）。
    private func screenPoint(for point: CGPoint, displayID: CGDirectDisplayID) -> CGPoint {
        guard let descriptor = ScreenGeometry.makeDescriptors().first(where: {
            $0.id == displayID
        }) else {
            return NSEvent.mouseLocation
        }
        return CGPoint(
            x: descriptor.appKitFrame.minX + point.x,
            y: descriptor.appKitFrame.maxY - point.y
        )
    }

    /// 贴图：把渲染结果贴到截取选区原来的位置（AppKit 屏幕坐标）。
    private func pinResult(_ image: CGImage, finish: SelectionFinish) {
        let display = finish.result.frame.display
        let topLeft = CGPoint(
            x: display.appKitFrame.minX + finish.result.rect.minX,
            y: display.appKitFrame.maxY - finish.result.rect.minY
        )
        guard let pins else {
            lastMessage = "贴图不可用"
            return
        }
        pins.present(image: image, topLeft: topLeft)
        lastMessage = "已贴图"
        feedback.show("已贴图")
    }

    private func copyResult(_ image: CGImage, isBatch: Bool) {
        do {
            try clipboard.copy(image)
            if isBatch {
                lastMessage = "已复制当前显示器"
                feedback.show("已复制当前屏")
            } else {
                lastMessage = "已复制到剪贴板"
                feedback.show("已复制")
            }
        } catch {
            state = .failed(message(for: error))
        }
    }

    private func saveResult(
        _ image: CGImage,
        batch: (images: [CGImage], index: Int)?
    ) {
        do {
            let savedCount: Int
            if let batch, batch.images.count > 1 {
                var images = batch.images
                images[batch.index] = image
                savedCount = try SavePanel.savePNGs(images)
            } else {
                savedCount = try SavePanel.savePNG(image) ? 1 : 0
            }

            if savedCount > 1 {
                lastMessage = "已保存 \(savedCount) 张"
                feedback.show("已保存 \(savedCount) 张")
            } else if savedCount == 1 {
                lastMessage = "已保存"
                feedback.show("已保存")
            }
        } catch {
            state = .failed(message(for: error))
        }
    }

    private func prepareForCapture(delay: Duration) async -> Bool {
        guard !isBusy else {
            if isSelecting {
                cancelCurrentSelection()
            }
            return false
        }

        lastMessage = nil
        state = .preparing
        previousApplication = NSWorkspace.shared.frontmostApplication
        didActivateForCapture = false
        pendingAllDisplays = nil
        refreshPermission()
        countdown.dismiss()
        feedback.dismiss()
        NotificationCenter.default.post(name: .iceShotDismissMenuBarPanel, object: nil)

        if permissionStatus != .authorized {
            NSApplication.shared.activate()
            didActivateForCapture = true
            permissionStatus = await permission.request()
        }

        guard permissionStatus == .authorized else {
            restorePreviousApplication()
            state = .failed(
                "需要屏幕录制权限。请在系统设置中允许 IceShot 录制屏幕，然后重启 IceShot 使其生效。"
            )
            // 打开原生引导窗口，让用户直接点按钮申请 / 跳到系统设置。
            NotificationCenter.default.post(name: .iceShotShowPermissionOnboarding, object: nil)
            return false
        }

        do {
            if delay != .zero {
                try await Task.sleep(for: delay)
            }
            return true
        } catch is CancellationError {
            state = .idle
            return false
        } catch {
            state = .failed(message(for: error))
            return false
        }
    }

    private func recordHistory(
        _ images: [CGImage],
        source: ScreenshotSource
    ) async -> Bool {
        guard HistoryPreferences.isEnabled, let history, !images.isEmpty else {
            return false
        }
        do {
            try await history.save(images, source: source, createdAt: Date())
            return true
        } catch {
            lastMessage = "历史保存失败，截图仍可复制或保存。"
            feedback.show("历史保存失败")
            return false
        }
    }

    private func runCountdown(_ seconds: Int) async -> Bool {
        guard seconds > 0 else {
            return true
        }
        let proceed = await countdown.run(seconds: seconds)
        if !proceed {
            restorePreviousApplication()
            state = .idle
        }
        return proceed
    }

    private func activateForOverlay() {
        didActivateForCapture = true
        NSApplication.shared.activate()
    }

    private func restorePreviousApplication() {
        guard didActivateForCapture else {
            previousApplication = nil
            return
        }
        didActivateForCapture = false
        defer { previousApplication = nil }

        guard let previousApplication,
              previousApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !previousApplication.isTerminated else {
            return
        }
        _ = previousApplication.activate(options: [])
    }

    private func currentDisplay(from displays: [DisplayDescriptor]) -> DisplayDescriptor? {
        let cursor = NSEvent.mouseLocation
        return displays.first { $0.appKitFrame.contains(cursor) } ?? displays.first
    }

    private func message(for error: Error) -> String {
        if let captureError = error as? CaptureError,
           let description = captureError.errorDescription {
            return description
        }
        let nsError = error as NSError
        return "操作失败（错误码 \(nsError.code)）。请重试。"
    }
}
