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
    /// 长截图起采前的「等目标窗口回到舞台」任务。
    private var scrollStartTask: Task<Void, Never>?
    private let previousApplicationTracker: PreviousApplicationTracker?
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
        feedback: FeedbackHUDController,
        previousApplicationTracker: PreviousApplicationTracker? = nil
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
        self.previousApplicationTracker = previousApplicationTracker
        refreshPermission()
    }

    convenience init(
        history: HistorySaving? = nil,
        pins: PinBoard? = nil,
        editor: EditorOpening? = nil,
        feedback: FeedbackHUDController? = nil,
        previousApplicationTracker: PreviousApplicationTracker? = nil
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
            feedback: hud,
            previousApplicationTracker: previousApplicationTracker
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
            return String(localized: "屏幕录制权限：已授权")
        case .notDetermined:
            return String(localized: "屏幕录制权限：尚未申请")
        case .denied:
            return String(localized: "屏幕录制权限：未授权")
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
        // 采集中（包括起采前的等待窗口）再按一次快捷键 = 结束并出图。
        if scrollSession != nil {
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
                OverlayCoordinates.containsInclusive($0.display.appKitFrame, NSEvent.mouseLocation)
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
            lastMessage = String(localized: "这块区域截取失败，可继续拖拽框选")
            feedback.show(String(localized: "截取失败"))
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
                HangTrace.mark("overlay.onFinish", "\(finish.action)")
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
        // 卡死取证：收尾里每一步都可能碰到系统服务（落历史、弹面板、切前台），逐个留痕。
        let started = ProcessInfo.processInfo.systemUptime
        HangTrace.mark("handleFinish.begin", "\(finish.action) source=\(pendingSource)")
        defer { HangTrace.markDuration("handleFinish.end", from: started) }

        let source = pendingSource
        let batch = pendingAllDisplays
        pendingAllDisplays = nil
        HangTrace.mark("handleFinish.readState")
        // 最后一步：把纯值写进 UserDefaults。不涉及任何窗口 / 系统服务，
        // 留痕是为了把它和后面的 `restorePreviousApplication` 区分开。
        let regionStarted = ProcessInfo.processInfo.systemUptime
        if source == .region {
            lastRegion.save(
                LastRegion(
                    displayID: finish.result.frame.display.id,
                    rect: finish.result.rect,
                    scale: finish.result.frame.display.scale
                )
            )
        }
        HangTrace.markDuration("handleFinish.lastRegion", from: regionStarted)

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
                let target = scrollTargetApplication()
                if restorePreviousApplication() == nil {
                    // 菜单栏入口下 IceShot 本来就是前台，上面这一步不会动手；
                    // 补一次激活，否则台前调度会让目标 App 一直留在舞台侧边。
                    activateForScrollCapture(target)
                }
                beginScrollCapture(
                    displayID: finish.result.frame.display.id,
                    rect: finish.result.rect,
                    targetApplication: target
                )
            }
            return
        }

        let historyImages = source == .allDisplays ? (batch?.images ?? [finish.original]) : [finish.original]

        // 到这一步时已经不在 SwiftUI 的事件派发栈上（`SelectionOverlayController.finish`
        // 把整段收尾推迟了一个 runloop），因此这里创建窗口 / 起模态循环都是安全的。
        HangTrace.mark("handleFinish.actions.begin", "\(finish.action)")
        switch finish.action {
        case .copy:
            if let output = finish.output {
                copyResult(output, isBatch: (batch?.images.count ?? 0) > 1)
            }
        case .save:
            if let output = finish.output {
                saveResult(output, batch: batch, frameStyle: finish.frameStyle)
            }
        case .pin:
            if let output = finish.output {
                pinResult(output, finish: finish)
            }
        case .close:
            break
        }
        HangTrace.mark("handleFinish.actions.done")
        HangTrace.mark("handleFinish.recordHistory.schedule")
        Task { [weak self] in
            await self?.recordHistory(historyImages, source: source)
        }
        HangTrace.mark("handleFinish.recordHistory.scheduled")

        state = .idle
        HangTrace.mark("handleFinish.idle")
    }

    // MARK: - 长截图会话

    private func beginScrollCapture(
        displayID: CGDirectDisplayID,
        rect: CGRect,
        targetApplication: NSRunningApplication?
    ) {
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

        // 起采必须等目标 App 真正回到舞台：台前调度把窗口从侧边滑回来是带动画的，
        // 动画期间抓到的首帧只是桌面。首帧一旦是桌面，后续内容帧全都匹配不上。
        scrollHUD.update(ScrollCaptureSession.Status(
            frameCount: 0,
            height: 0,
            message: String(localized: "正在等待窗口回到前台…")
        ))
        scrollStartTask = Task { [weak self] in
            guard let self else { return }
            await self.waitForTargetApplicationOnStage(targetApplication)
            guard !Task.isCancelled, self.scrollSession === session else { return }
            session.start()
            self.scrollStartTask = nil
        }
    }

    /// 等（并确认）目标 App 回到前台，再留一拍给舞台切换动画。
    ///
    /// 只调用 `activate` 不够：前台标记先切换，前台调度把窗口滑回原位还要时间。
    private func waitForTargetApplicationOnStage(
        _ target: NSRunningApplication?
    ) async {
        guard let target,
              target.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return
        }

        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            guard !Task.isCancelled else { return }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier
                == target.processIdentifier
                || target.isTerminated {
                break
            }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return
            }
        }

        guard !Task.isCancelled else { return }
        try? await Task.sleep(for: .milliseconds(350))
    }

    private func completeScrollCapture() {
        scrollSession?.finish()
    }

    private func cancelScrollCapture() {
        scrollStartTask?.cancel()
        scrollStartTask = nil
        scrollSession = nil
        scrollFrame.dismiss()
        scrollHUD.dismiss()
        restorePreviousApplication()
        state = .idle
    }

    private func finishScrollCapture(with image: CGImage) {
        scrollStartTask?.cancel()
        scrollStartTask = nil
        scrollSession = nil
        scrollFrame.dismiss()
        scrollHUD.dismiss()
        // 长图要交给用户继续编辑：不要把前台还给被截的 App，否则编辑器会被挡住。
        // 只清掉「为浮层激活过」的标记，不执行激活。
        didActivateForCapture = false
        previousApplication = nil
        state = .idle
        editor?.open(image: image, title: String(localized: "长截图"))
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
    /// 贴图：把渲染结果贴到截取选区原来的位置（AppKit 屏幕坐标）。
    ///
    /// **必须晚一拍执行**。`pinResult` 是在 SwiftUI 按钮 action 的同步栈里被调用的：
    /// 此刻浮层面板正在拆除、AppKit 正处于事件分发的重入点。在这个栈上创建
    /// 一个新的 `NSPanel` 并让它的内容视图首帧布局，会与「正在进行的窗口拆除」
    /// 互相等待——实测表现为点「贴图」后整机卡死（日志停在 `CFPrefsD` 之后没有下一行，
    /// 主线程再无任何活动）。
    ///
    /// 推到下一个 runloop（并发一个 `Task`）后栈已经完全退出，创建窗口就是普通操作。
    private func pinResult(_ image: CGImage, finish: SelectionFinish) {
        let display = finish.result.frame.display
        let topLeft = CGPoint(
            x: display.appKitFrame.minX + finish.result.rect.minX,
            y: display.appKitFrame.maxY - finish.result.rect.minY
        )
        guard let pins else {
            lastMessage = String(localized: "贴图不可用")
            return
        }
        // 到这里已经不在 SwiftUI 的事件派发栈上（收尾整体被推迟过），
        // 可以安全地创建贴图面板。
        HangTrace.mark("pin.present.begin")
        pins.present(image: image, topLeft: topLeft)
        HangTrace.mark("pin.present.done")
        lastMessage = String(localized: "已贴图")
        feedback.show(String(localized: "已贴图"))
    }

    private func copyResult(_ image: CGImage, isBatch: Bool) {
        do {
            try clipboard.copy(image)
            if isBatch {
                lastMessage = String(localized: "已复制当前显示器")
                feedback.show(String(localized: "已复制当前屏"))
            } else {
                lastMessage = String(localized: "已复制到剪贴板")
                feedback.show(String(localized: "已复制"))
            }
        } catch {
            state = .failed(message(for: error))
        }
    }

    /// 保存：收尾整体已被推迟出事件派发栈，因此可以放心起模态循环。
    ///
    /// 「全部显示器」时，浮层只处理了当前屏；其余屏在这里套**同一个壳**再一起存。
    /// 历史库仍然只收原图（`handleFinish` 里的 `historyImages`）。
    private func saveResult(
        _ image: CGImage,
        batch: (images: [CGImage], index: Int)?,
        frameStyle: ScreenshotFrameStyle?
    ) {
        HangTrace.mark("save.present.begin")
        defer { HangTrace.mark("save.present.done") }
        do {
            let savedCount: Int
            if let batch, batch.images.count > 1 {
                var images = batch.images
                images[batch.index] = image
                images = framedBatch(images, index: batch.index, style: frameStyle)
                savedCount = try SavePanel.savePNGs(images)
            } else {
                savedCount = try SavePanel.savePNG(image) ? 1 : 0
            }

            if savedCount > 1 {
                lastMessage = "已保存 \(savedCount) 张"
                feedback.show("已保存 \(savedCount) 张")
            } else if savedCount == 1 {
                lastMessage = String(localized: "已保存")
                feedback.show(String(localized: "已保存"))
            }
        } catch {
            state = .failed(message(for: error))
        }
    }

    /// 给批量里的每一张图套同一个壳。
    ///
    /// 当前屏（`index`）已经在浮层里套过壳，**必须跳过**：再套一次就是壳外套壳，
    /// 尺寸凭空再长一圈。这里只负责把其余屏补齐。
    ///
    /// - Parameters:
    ///   - images: 已在 `index` 位置填好成品的整批图。
    ///   - index: 已经带壳的那一张，不重复处理。
    /// - Returns: 每张都带壳的整批图；无样式或套壳失败时原样返回对应项。
    private func framedBatch(
        _ images: [CGImage],
        index: Int,
        style: ScreenshotFrameStyle?
    ) -> [CGImage] {
        guard let style else { return images }
        return images.enumerated().map { offset, image in
            guard offset != index else { return image }
            return (try? ScreenshotFrameComposer.render(image, style: style)) ?? image
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
                String(localized: "需要屏幕录制权限。请在系统设置中允许 IceShot 录制屏幕，然后重启 IceShot 使其生效。")
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
            HangTrace.mark("recordHistory.skip")
            return false
        }
        let started = ProcessInfo.processInfo.systemUptime
        HangTrace.mark("recordHistory.begin")
        defer { HangTrace.markDuration("recordHistory.end", from: started) }
        do {
            try await history.save(images, source: source, createdAt: Date())
            return true
        } catch {
            lastMessage = String(localized: "历史保存失败，截图仍可复制或保存。")
            feedback.show(String(localized: "历史保存失败"))
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

    /// 长截图要还前台给的 App。
    ///
    /// `previousApplication` 通常就是它；但如果启动流程时 IceShot 已经在前台
    /// （菜单栏面板入口），那个值会是 IceShot 自己，于是退回最近的外部前台 App。
    private func scrollTargetApplication() -> NSRunningApplication? {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        if let previousApplication,
           previousApplication.processIdentifier != currentPID,
           !previousApplication.isTerminated {
            return previousApplication
        }
        guard let tracked = previousApplicationTracker?.lastExternalApplication,
              tracked.processIdentifier != currentPID else {
            return nil
        }
        return tracked
    }

    private func activateForScrollCapture(_ application: NSRunningApplication?) {
        guard let application,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !application.isTerminated else {
            return
        }
        _ = application.activate(options: [])
    }

    @discardableResult
    private func restorePreviousApplication() -> NSRunningApplication? {
        // 这一步此前出现在崩溃栈里（`NSRunningApplication.activate`）：它可能同步
        // 询问 LaunchServices，是「收尾时转圈」最可疑的一处，单独计时。
        defer { HangTrace.mark("restoreApp.done", "activated=\(didActivateForCapture)") }
        guard didActivateForCapture else {
            previousApplication = nil
            return nil
        }
        didActivateForCapture = false
        defer { previousApplication = nil }

        guard let previousApplication,
              previousApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !previousApplication.isTerminated else {
            return nil
        }
        _ = previousApplication.activate(options: [])
        return previousApplication
    }

    private func currentDisplay(from displays: [DisplayDescriptor]) -> DisplayDescriptor? {
        let cursor = NSEvent.mouseLocation
        return displays.first {
            OverlayCoordinates.containsInclusive($0.appKitFrame, cursor)
        } ?? displays.first
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
