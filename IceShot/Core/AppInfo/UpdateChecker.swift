import AppKit
import Observation

/// 检查结果的呈现方式。
///
/// 抽成协议是为了单测：`NSAlert.runModal()` 会阻塞到用户点按钮，测试里绝不能真跑到。
/// 生产用 `AlertUpdatePresenter`，测试注入一个只记下「要求展示什么」的实现。
@MainActor
protocol UpdatePresenting {
    /// 发现新版本。
    /// - Returns: 用户的选择；下载器不可用时由实现自己降级到网页。
    func presentUpdate(
        version: String,
        notes: String,
        channelTag: String?,
        canDownloadInApp: Bool
    ) -> UpdateChoice
    func presentUpToDate(currentVersion: String, channelTag: String?)
    func presentFailure()
    /// 下载失败。`canOpenWeb` 为 true 时提示里会给出网页下载入口。
    func presentDownloadFailure(_ error: UpdateDownloadError)
    /// 下载完成，让用户在 Finder 里看到文件。
    func presentDownloadFinished(at url: URL)
    /// 下载过程中的进度面板；返回的句柄用于更新与关闭。
    func presentDownloadProgress(fileName: String) -> UpdateProgressPresentation
    /// 让用户选保存位置并搬过去；返回 `nil` 表示用户取消。
    func presentSavePanel(suggestedName: String, sourceURL: URL) -> URL?
}

/// 用户在更新弹窗里的选择。
enum UpdateChoice: Equatable {
    /// 应用内下载（仅当 `canDownloadInApp` 为 true 时可能出现）。
    case downloadInApp
    /// 打开发布页自行下载。
    case openWeb
    /// 先不更新，本版本不再提示。
    case later
}

/// 进度面板控制句柄。
@MainActor
protocol UpdateProgressPresentation {
    func update(fraction: Double?)
    func dismiss()
}

/// 更新检查的编排者：决定何时查、查到什么算新版本、要不要打扰用户。
///
/// 只做编排，不碰实现细节——网络交给 `ReleaseFetching`，日期比较交给
/// `SemanticVersion`，正文清洗交给 `ReleaseNotesText`。这样单测可以注入假网络
/// 和假 `UserDefaults`，把「节流」「去重」「短路」这些最容易出错的判断全跑一遍。
///
/// 三条静默规则（任何一条命中都不弹窗、只记时间戳）：
/// 1. 用户关掉了自动检查；
/// 2. 距上次检查不足 24 小时；
/// 3. 远端版本不比当前新，或刚好是用户点过「稍后」的那一版。
@MainActor
@Observable
final class UpdateChecker {
    /// 设置页绑定这个值；改动立即落盘并影响下一次检查。
    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: UpdatePreferences.enabledKey)
        }
    }

    private let fetch: ReleaseFetching
    private let defaults: UserDefaults
    private let presenter: UpdatePresenting
    /// 为 `nil` 时界面不提供应用内下载（例如无法定位临时目录）。
    private let downloader: (any UpdateDownloading)?
    private let now: @Sendable () -> Date
    /// 是否为自动化环境（测试宿主）。判据注入而非写死，否则本类型的单测
    /// 自己也算「测试环境」，所有用例会在第一道 guard 就提前返回。
    private let isAutomation: @Sendable () -> Bool
    /// 当前构建版本，构造时取一次即可（运行期不会变，也保证单测可控）。
    private let currentVersion: SemanticVersion?

    /// 正在进行的请求：连开几次面板只发一次网络请求。
    private var inFlight: Task<RemoteRelease, Error>?
    /// 已经弹过窗、或用户点过「稍后」的版本，避免同一版本重复打扰。
    private var skippedVersion: SemanticVersion? {
        didSet {
            defaults.set(skippedVersion?.displayText, forKey: UpdatePreferences.skippedVersionKey)
        }
    }

    init(
        fetch: ReleaseFetching = GitHubReleaseClient(),
        defaults: UserDefaults = .standard,
        presenter: UpdatePresenting,
        downloader: (any UpdateDownloading)? = nil,
        currentVersion: SemanticVersion? = SemanticVersion(tag: AppVersion.shortVersion),
        now: @escaping @Sendable () -> Date = { Date() },
        isAutomation: @escaping @Sendable () -> Bool = { TestEnvironment.isAutomation() }
    ) {
        self.fetch = fetch
        self.defaults = defaults
        self.presenter = presenter
        self.downloader = downloader
        self.currentVersion = currentVersion
        self.now = now
        self.isAutomation = isAutomation
        self.isEnabled = defaults.object(forKey: UpdatePreferences.enabledKey) as? Bool
            ?? UpdatePreferences.isEnabledByDefault
        self.skippedVersion = defaults.string(forKey: UpdatePreferences.skippedVersionKey)
            .flatMap(SemanticVersion.init(tag:))
    }

    /// 自动入口：受开关与 24 小时节流约束。启动与打开菜单栏面板时调用。
    ///
    /// 返回内部 `Task` 供测试 `await`：固定 `sleep` 等待后台任务完成会让用例变慢且不稳定。
    /// 生产调用方忽略返回值即可。
    @discardableResult
    func checkIfDue() -> Task<Void, Never>? {
        // 自动化环境下一律不联网、不弹窗。
        //
        // 这里必须自己再挡一次，不能只靠 `AppDelegate` 启动时的 `guard`：
        // 菜单栏面板打开时也会调本方法，而且那个 `guard` 一旦被改动，
        // 「测试里跑去打开 GitHub」会静默地回来（表现为每跑一次门禁多开几十个标签）。
        guard !isAutomation() else { return nil }
        guard isEnabled else { return nil }
        guard isDue else { return nil }
        return Task { await run(promptUser: false) }
    }

    /// 手动入口：不受节流约束，失败与「已是最新」都要给用户明确答复。
    func checkNow() async {
        // 同 `checkIfDue`：自动化环境不联网、不弹窗。
        guard !isAutomation() else { return }
        await run(promptUser: true)
    }

    // MARK: - 节流

    private var isDue: Bool {
        guard let last = defaults.object(forKey: UpdatePreferences.lastCheckDateKey) as? Date else {
            return true
        }
        // 时钟被往回调时 `timeIntervalSince` 会是负数，此时按「还没到点」处理，
        // 宁可少查一次，也不要因为改了系统时间就在每次启动时都联网。
        let elapsed = now().timeIntervalSince(last)
        return elapsed >= UpdatePreferences.checkInterval
    }

    private func markChecked() {
        defaults.set(now(), forKey: UpdatePreferences.lastCheckDateKey)
    }

    // MARK: - 主流程

    private func run(promptUser: Bool) async {
        defer { markChecked() }

        let release: RemoteRelease
        do {
            release = try await fetchRelease()
        } catch {
            // 后台失败完全静默；用户主动问了就必须有个答覆，否则会以为按钮坏了。
            if promptUser {
                presenter.presentFailure()
            }
            return
        }

        guard let remote = SemanticVersion(tag: release.tagName) else {
            // tag 解析不出来就当作「没有可比的新版本」，不猜。
            if promptUser { presenter.presentFailure() }
            return
        }

        guard let current = currentVersion else {
            if promptUser { presenter.presentFailure() }
            return
        }

        if remote > current {
            // 用户点过「稍后」的版本：自动检查不再打扰；但**手动**检查是用户
            // 主动询问，必须如实答复有新版本，否则会误报「已是最新」。
            let isSkipped = remote == skippedVersion
            if isSkipped && !promptUser {
                return
            }
            // 手动检查重新弹出后，清掉静默标记：用户已经看过这个版本，
            // 再次选「稍后」会重新写入，不选就不应该继续带着旧标记。
            if isSkipped && promptUser {
                skippedVersion = nil
            }
            presentUpdate(release, version: remote)
        } else if promptUser {
            presenter.presentUpToDate(currentVersion: current.displayText, channelTag: AppVersion.channel.tag)
        }
    }

    /// 已有请求直接复用，避免连开面板打出多个请求。
    private func fetchRelease() async throws -> RemoteRelease {
        if let inFlight {
            return try await inFlight.value
        }
        let task = Task { try await fetch.latestRelease() }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    // MARK: - 弹窗

    private func presentUpdate(_ release: RemoteRelease, version: SemanticVersion) {
        // 自动化环境绝不开网页。这里是「开浏览器」的最终出口，
        // 即使上游的 `checkIfDue` / `checkNow` 保护将来被改，也不会变成
        // 无人值守时反复打开发布页（每跑一次门禁多出几十个标签）。
        guard !isAutomation() else { return }

        let asset = release.diskImage
        let choice = presenter.presentUpdate(
            version: version.displayText,
            notes: ReleaseNotesText.condensed(release.notes),
            channelTag: AppVersion.channel.tag,
            canDownloadInApp: asset != nil && downloader != nil
        )

        switch choice {
        case .openWeb:
            NSWorkspace.shared.open(release.htmlURL)
        case .downloadInApp:
            guard let asset, let downloader else {
                // 理论上不会走到：`canDownloadInApp` 已拦过。降级到网页，不静默失败。
                NSWorkspace.shared.open(release.htmlURL)
                return
            }
            Task { await download(asset, using: downloader) }
        case .later:
            // 「稍后」= 这一版不再打扰；发新版照常提示。
            skippedVersion = version
        }
    }

    // MARK: - 应用内下载

    /// 下载 → 校验 → 另存 → 提示。
    ///
    /// 任一步失败都保留在临时目录外不被使用：校验不通过的包会先删除再报错。
    private func download(_ asset: ReleaseAsset, using downloader: any UpdateDownloading) async {
        let progress = presenter.presentDownloadProgress(fileName: asset.name)
        defer { progress.dismiss() }

        let localURL: URL
        // 把进度句柄先装进一个线程安全的盒子，回调里只拿盒子，不碰 `self`。
        let progressBox = ProgressHandleBox(progress)
        do {
            localURL = try await downloader.download(asset) { fraction in
                progressBox.update(fraction)
            }
        } catch let error as UpdateDownloadError {
            presenter.presentDownloadFailure(error)
            return
        } catch {
            presenter.presentDownloadFailure(.failed)
            return
        }

        // 另存到用户选的位置；用户取消就默默结束（包已被临时目录接管，无需额外处理）。
        guard let savedURL = presenter.presentSavePanel(suggestedName: asset.name, sourceURL: localURL) else {
            return
        }
        presenter.presentDownloadFinished(at: savedURL)
    }
}
