import AppKit

/// 生产实现的弹窗呈现。
///
/// 统一用 `NSAlert`：它是原生模态、符合 HIG、默认按钮回车即可触发，
/// 对一个「发现新版 → 去下载」的提示来说已经足够，不需要自建窗口。
struct AlertUpdatePresenter: UpdatePresenting {
    func presentUpdate(version: String, notes: String, channelTag: String?) -> Bool {
        NSApplication.shared.activate()

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "发现新版本 \(version)\(suffix(channelTag))"

        // 正文已由 `ReleaseNotesText` 清洗截断；为空时给一句兜底说明。
        alert.informativeText = notes.isEmpty
            ? "点「前往下载」打开 GitHub 发布页。"
            : notes

        alert.addButton(withTitle: "前往下载")
        alert.addButton(withTitle: "稍后")

        return alert.runModal() == .alertFirstButtonReturn
    }

    func presentUpToDate(currentVersion: String, channelTag: String?) {
        NSApplication.shared.activate()

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "IceShot 已是最新版本"
        alert.informativeText = "当前版本 \(currentVersion)\(suffix(channelTag))。"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    func presentFailure() {
        NSApplication.shared.activate()

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "暂时无法检查更新"
        alert.informativeText = "无法连接 GitHub，请检查网络后稍后再试。"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    /// Beta 通道在版本号后补一句，和设置页 / 菜单栏的展示保持一致。
    private func suffix(_ channelTag: String?) -> String {
        guard let channelTag else { return "" }
        return " · \(channelTag)"
    }
}
