import AppKit

/// 下载进度面板：一个无标题小浮层，显示文件名与进度条。
///
/// 用 `NSPanel` 而不是 `NSAlert`：`NSAlert.runModal()` 会阻塞主线程，
/// 而下载要同时更新进度。面板是非模态的 `.hudWindow` 风格，不抢激活。
@MainActor
final class UpdateProgressPanel: UpdateProgressPresentation {
    private let panel: NSPanel
    private let progressIndicator: NSProgressIndicator
    private let statusLabel: NSTextField

    init(fileName: String) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 96),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "正在下载"
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false

        statusLabel = NSTextField(labelWithString: fileName)
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        progressIndicator = NSProgressIndicator()
        progressIndicator.style = .bar
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
        progressIndicator.doubleValue = 0
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        let content = panel.contentView ?? NSView()
        content.addSubview(statusLabel)
        content.addSubview(progressIndicator)

        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            statusLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),

            progressIndicator.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            progressIndicator.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            progressIndicator.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 12),
            progressIndicator.heightAnchor.constraint(equalToConstant: 12),
        ])

        panel.center()
        panel.orderFrontRegardless()
    }

    func update(fraction: Double?) {
        guard let fraction else {
            // 总长度未知时退回不确定进度，避免进度条停在 0 看起来像卡死。
            if !progressIndicator.isIndeterminate {
                progressIndicator.isIndeterminate = true
                progressIndicator.startAnimation(nil)
            }
            return
        }
        if progressIndicator.isIndeterminate {
            progressIndicator.stopAnimation(nil)
            progressIndicator.isIndeterminate = false
        }
        progressIndicator.doubleValue = min(max(fraction, 0), 1)
    }

    func dismiss() {
        progressIndicator.stopAnimation(nil)
        panel.orderOut(nil)
    }
}

/// 把 `@MainActor` 的进度句柄包装成可以从后台回调安全调用的盒子。
///
/// `URLSession` 的进度回调是 `@Sendable`、跑在任意线程；而 `UpdateProgressPresentation`
/// 是 `@MainActor` 隔离、非 Sendable。盒子只做一件事：把数值 hop 回主 actor 再转交。
final class ProgressHandleBox: @unchecked Sendable {
    private let handle: any UpdateProgressPresentation

    @MainActor
    init(_ handle: any UpdateProgressPresentation) {
        self.handle = handle
    }

    func update(_ fraction: Double?) {
        let handle = self.handle
        // 不能在后台线程上 assumeIsolated；用 Task 显式跳回主 actor。
        Task { @MainActor in
            handle.update(fraction: fraction)
        }
    }
}
