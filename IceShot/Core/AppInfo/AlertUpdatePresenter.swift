import AppKit
import UniformTypeIdentifiers

/// 生产实现的弹窗呈现。
///
/// 统一用 `NSAlert` / `NSSavePanel` 这些系统原生控件：符合 HIG、默认按钮回车即可触发，
/// 对一个「发现新版 → 下载 → 另存」的流程来说已经够用，不需要自建窗口。
struct AlertUpdatePresenter: UpdatePresenting {
    func presentUpdate(
        version: String,
        notes: String,
        channelTag: String?,
        canDownloadInApp: Bool
    ) -> UpdateChoice {
        NSApplication.shared.activate()

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "发现新版本 \(version)\(suffix(channelTag))"

        // 正文已由 `ReleaseNotesText` 清洗截断；为空时给一句兜底说明。
        alert.informativeText = notes.isEmpty
            ? "可以立即下载安装包，或前往 GitHub 发布页。"
            : notes

        if canDownloadInApp {
            alert.addButton(withTitle: "立即下载")
            alert.addButton(withTitle: "在网页下载")
            alert.addButton(withTitle: "稍后")
        } else {
            alert.addButton(withTitle: "前往下载")
            alert.addButton(withTitle: "稍后")
        }

        let response = alert.runModal()
        if canDownloadInApp {
            switch response {
            case .alertFirstButtonReturn: return .downloadInApp
            case .alertSecondButtonReturn: return .openWeb
            default: return .later
            }
        }
        return response == .alertFirstButtonReturn ? .openWeb : .later
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

    func presentDownloadFailure(_ error: UpdateDownloadError) {
        NSApplication.shared.activate()

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")

        switch error {
        case .cancelled:
            // 用户自己取消的，不必再弹一次错误框。
            return
        case .checksumMismatch:
            alert.messageText = "安装包校验失败"
            alert.informativeText = """
            下载的文件与 GitHub 上公布的校验值不一致，可能传输中途出错。
            文件已删除，请重试或改用网页下载。
            """
        case .failed:
            alert.messageText = "下载失败"
            alert.informativeText = "无法下载安装包，请检查网络后重试，或改用网页下载。"
        }
        alert.runModal()
    }

    func presentDownloadFinished(at url: URL) {
        NSApplication.shared.activate()

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "下载完成"
        alert.informativeText = """
        已保存到「\(url.deletingLastPathComponent().lastPathComponent)」文件夹。
        打开后把 IceShot 拖到「应用程序」即可完成更新。
        """
        alert.addButton(withTitle: "在 Finder 中显示")
        alert.addButton(withTitle: "好")

        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func presentDownloadProgress(fileName: String) -> UpdateProgressPresentation {
        UpdateProgressPanel(fileName: fileName)
    }

    /// 中转到 `NSSavePanel`，默认目录是「下载」。
    ///
    /// 走保存面板而不是直接写 `~/Downloads`：沙盒里写用户下载目录需要额外 entitlement，
    /// 而保存面板本来就是用户的授权通道，不必为此扩大权限面。
    func presentSavePanel(suggestedName: String, sourceURL: URL) -> URL? {
        let panel = NSSavePanel()
        panel.title = "保存安装包"
        panel.prompt = "保存"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.diskImage]
        if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            panel.directoryURL = downloads
        }

        NSApplication.shared.activate()
        guard panel.runModal() == .OK, let destination = panel.url else {
            return nil
        }

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: sourceURL, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    /// Beta 通道在版本号后补一句，和设置页 / 菜单栏的展示保持一致。
    private func suffix(_ channelTag: String?) -> String {
        guard let channelTag else { return "" }
        return " · \(channelTag)"
    }
}
