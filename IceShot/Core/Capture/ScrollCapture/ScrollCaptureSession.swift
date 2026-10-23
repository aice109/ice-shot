import CoreGraphics
import Foundation

/// 长截图采集会话：反复抓同一块区域，交给 `ScrollStitcher` 去重拼接。
///
/// 只在用户主动进入长截图、并框定区域后启动；`finish()` / `cancel()` 或超时立即停止。
/// 所有抓取都在**选区内**、本机完成，不联网、不写日志内容。
@MainActor
final class ScrollCaptureSession {
    struct Status: Equatable {
        var frameCount: Int
        var height: Int
        var message: String?
    }

    /// 抓取间隔：0.35 s，足够跟上手滚动的节奏，也不会把 CPU 打满。
    static let captureInterval: Duration = .milliseconds(350)
    /// 最长采集时间。
    static let maximumDuration: TimeInterval = 60
    /// 连续多少帧没有新内容就提示「可能已经到底」。
    static let idleFrameThreshold = 3

    private let capture: ScreenCapturing
    private let displayID: CGDirectDisplayID
    private let rect: CGRect

    private var stitcher: ScrollStitcher?
    private var task: Task<Void, Never>?
    private var startedAt = Date()
    private var frameCount = 0
    private var idleFrames = 0
    private var didFinish = false

    var onUpdate: ((Status) -> Void)?
    /// 采集结束（用户结束或到上限）后回调合成图。
    var onFinish: ((CGImage) -> Void)?
    var onCancel: (() -> Void)?

    init(capture: ScreenCapturing, displayID: CGDirectDisplayID, rect: CGRect) {
        self.capture = capture
        self.displayID = displayID
        self.rect = rect
    }

    var isRunning: Bool {
        task != nil
    }

    func start() {
        guard task == nil else { return }
        startedAt = Date()
        task = Task { [weak self] in
            await self?.run()
        }
    }

    /// 用户主动结束：停止抓取并输出当前拼接结果。
    func finish() {
        guard !didFinish else { return }
        stopLoop()
        guard let image = stitcher?.makeImage() else {
            didFinish = true
            onCancel?()
            return
        }
        didFinish = true
        onFinish?(image)
    }

    func cancel() {
        guard !didFinish else { return }
        didFinish = true
        stopLoop()
        stitcher = nil
        onCancel?()
    }

    private func stopLoop() {
        task?.cancel()
        task = nil
    }

    private func run() async {
        while !Task.isCancelled {
            if Date().timeIntervalSince(startedAt) > Self.maximumDuration {
                finish()
                return
            }
            do {
                let frame = try await capture.captureRegion(
                    displayID: displayID,
                    rect: rect
                )
                guard !Task.isCancelled else { return }
                consume(frame)
            } catch is CancellationError {
                return
            } catch {
                // 单帧失败（例如窗口切换瞬间）不终止会话，下一帧继续尝试。
                publish(message: "抓取失败，正在重试…")
            }
            try? await Task.sleep(for: Self.captureInterval)
        }
    }

    private func consume(_ frame: CGImage) {
        if stitcher == nil {
            stitcher = ScrollStitcher(
                width: frame.width,
                frameHeight: frame.height
            )
            guard stitcher != nil else {
                cancel()
                return
            }
        }
        guard let outcome = stitcher?.append(frame) else { return }
        frameCount += 1

        switch outcome {
        case .appended(_, let totalHeight), .prepended(_, let totalHeight):
            idleFrames = 0
            publish(message: nil, height: totalHeight)
        case .duplicate:
            idleFrames += 1
            publish(
                message: idleFrames >= Self.idleFrameThreshold
                    ? "看起来已经滚到底了，点「完成」结束"
                    : "等待滚动…"
            )
        case .rejectedJump:
            idleFrames += 1
            publish(message: "滚动太快，慢一点效果更好")
        case .limitReached(let totalHeight):
            publish(message: "已达到高度上限，正在结束…", height: totalHeight)
            finish()
        }
    }

    private func publish(message: String?, height: Int? = nil) {
        onUpdate?(Status(
            frameCount: frameCount,
            height: height ?? stitcher?.totalHeight ?? 0,
            message: message
        ))
    }
}
