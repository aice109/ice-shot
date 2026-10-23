import AppKit
import Observation

/// 检查结果的呈现方式。
///
/// 抽成协议是为了单测：`NSAlert.runModal()` 会阻塞到用户点按钮，测试里绝不能真跑到。
/// 生产用 `AlertUpdatePresenter`，测试注入一个只记下「要求展示什么」的实现。
@MainActor
protocol UpdatePresenting {
    /// 发现新版本；返回用户是否选择「前往下载」。
    func presentUpdate(version: String, notes: String, channelTag: String?) -> Bool
    func presentUpToDate(currentVersion: String, channelTag: String?)
    func presentFailure()
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
    private let now: @Sendable () -> Date
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
        currentVersion: SemanticVersion? = SemanticVersion(tag: AppVersion.shortVersion),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fetch = fetch
        self.defaults = defaults
        self.presenter = presenter
        self.currentVersion = currentVersion
        self.now = now
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
        guard isEnabled else { return nil }
        guard isDue else { return nil }
        return Task { await run(promptUser: false) }
    }

    /// 手动入口：不受节流约束，失败与「已是最新」都要给用户明确答复。
    func checkNow() async {
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
            guard remote != skippedVersion else {
                if promptUser { presenter.presentUpToDate(currentVersion: current.displayText, channelTag: AppVersion.channel.tag) }
                return
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
        let didOpen = presenter.presentUpdate(
            version: version.displayText,
            notes: ReleaseNotesText.condensed(release.notes),
            channelTag: AppVersion.channel.tag
        )

        if didOpen {
            NSWorkspace.shared.open(release.htmlURL)
        } else {
            // 「稍后」= 这一版不再打扰；发新版照常提示。
            skippedVersion = version
        }
    }
}
