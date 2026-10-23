import Foundation
import Testing
@testable import IceShot

/// 更新检查的编排逻辑：节流、短路、去重。
///
/// 不真打网络：注入假 `ReleaseFetching`；不污染全局偏好：每次用独立
/// `UserDefaults(suiteName:)`（与 `ScreenRecordingPermission` 的注入范式一致）。
///
/// 这些测试**只覆盖不弹窗的路径**——弹窗要跑 `NSAlert.runModal()`，在单测里会阻塞，
/// 所以「有新版本」的场景只断言网络没有被额外打、以及时间戳照常写入。
struct UpdateCheckerTests {
    /// 假网络层：记录调用次数，按需返回结果。
    private final class FakeFetcher: ReleaseFetching, @unchecked Sendable {
        var result: Result<RemoteRelease, Error>
        private(set) var callCount = 0

        init(result: Result<RemoteRelease, Error>) {
            self.result = result
        }

        func latestRelease() async throws -> RemoteRelease {
            callCount += 1
            return try result.get()
        }
    }

    private static func makeRelease(tag: String, withDiskImage: Bool = false) -> RemoteRelease {
        let dmg = withDiskImage
            ? ReleaseAsset(
                name: "IceShot-\(tag).dmg",
                url: URL(string: "https://example.invalid/IceShot.dmg")!,
                checksumTextURL: nil
            )
            : nil
        return RemoteRelease(
            tagName: tag,
            htmlURL: URL(string: "https://github.com/aice109/ice-shot/releases/tag/\(tag)")!,
            notes: "- 修了点东西",
            diskImage: dmg
        )
    }

    /// 假呈现层：只记录被要求展示什么，绝不弹真窗（`NSAlert.runModal()` 会阻塞到用户点击）。
    @MainActor
    private final class FakePresenter: UpdatePresenting {
        var updateVersions: [String] = []
        var upToDateCalls = 0
        var failureCalls = 0
        var downloadFailureCalls = 0
        var finishedURLs: [URL] = []
        /// 用户在更新弹窗里的选择；默认「稍后」以外要显式设。
        var choice: UpdateChoice = .openWeb
        /// 保存面板返回的地址；`nil` 模拟用户取消。
        var saveDestination: URL?

        func presentUpdate(
            version: String,
            notes: String,
            channelTag: String?,
            canDownloadInApp: Bool
        ) -> UpdateChoice {
            updateVersions.append(version)
            return choice
        }

        func presentUpToDate(currentVersion: String, channelTag: String?) {
            upToDateCalls += 1
        }

        func presentFailure() {
            failureCalls += 1
        }

        func presentDownloadFailure(_ error: UpdateDownloadError) {
            downloadFailureCalls += 1
        }

        func presentDownloadFinished(at url: URL) {
            finishedURLs.append(url)
        }

        func presentDownloadProgress(fileName: String) -> UpdateProgressPresentation {
            NoopProgressPresentation()
        }

        func presentSavePanel(suggestedName: String, sourceURL: URL) -> URL? {
            saveDestination
        }
    }

    @MainActor
    private final class NoopProgressPresentation: UpdateProgressPresentation {
        func update(fraction: Double?) {}
        func dismiss() {}
    }

    /// 每个用例一份独立的偏好域，避免并行测试互相影响。
    private func makeDefaults() -> UserDefaults {
        let suite = "UpdateCheckerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @MainActor
    private func makeChecker(
        fetcher: FakeFetcher,
        defaults: UserDefaults,
        presenter: FakePresenter,
        current: String = "0.3.1",
        now: Date = Date()
    ) -> UpdateChecker {
        UpdateChecker(
            fetch: fetcher,
            defaults: defaults,
            presenter: presenter,
            currentVersion: SemanticVersion(tag: current),
            now: { now }
        )
    }

    // MARK: - 节流

    @MainActor
    @Test func checksWhenNeverCheckedBefore() async {
        let fetcher = FakeFetcher(result: .success(Self.makeRelease(tag: "v0.3.1")))
        let defaults = makeDefaults()
        let checker = makeChecker(fetcher: fetcher, defaults: defaults, presenter: FakePresenter())

        await checker.checkIfDue()?.value

        #expect(fetcher.callCount == 1)
        #expect(defaults.object(forKey: UpdatePreferences.lastCheckDateKey) != nil)
    }

    @MainActor
    @Test func skipsWhenCheckedWithinInterval() async {
        let fetcher = FakeFetcher(result: .success(Self.makeRelease(tag: "v0.3.1")))
        let defaults = makeDefaults()
        let now = Date()
        defaults.set(now.addingTimeInterval(-60), forKey: UpdatePreferences.lastCheckDateKey)

        let checker = makeChecker(fetcher: fetcher, defaults: defaults, presenter: FakePresenter(), now: now)
        await checker.checkIfDue()?.value

        #expect(fetcher.callCount == 0)
    }

    @MainActor
    @Test func checksAgainAfterIntervalElapsed() async {
        let fetcher = FakeFetcher(result: .success(Self.makeRelease(tag: "v0.3.1")))
        let defaults = makeDefaults()
        let now = Date()
        let stale = now.addingTimeInterval(-(UpdatePreferences.checkInterval + 60))
        defaults.set(stale, forKey: UpdatePreferences.lastCheckDateKey)

        let checker = makeChecker(fetcher: fetcher, defaults: defaults, presenter: FakePresenter(), now: now)
        await checker.checkIfDue()?.value

        #expect(fetcher.callCount == 1)
    }

    /// 时钟被往回调时不联网：宁可少查一次，也不要每次启动都打请求。
    @MainActor
    @Test func skipsWhenClockMovedBackwards() async {
        let fetcher = FakeFetcher(result: .success(Self.makeRelease(tag: "v0.3.1")))
        let defaults = makeDefaults()
        let now = Date()
        // 「上次检查」在未来 3 天
        defaults.set(now.addingTimeInterval(3 * 24 * 60 * 60), forKey: UpdatePreferences.lastCheckDateKey)

        let checker = makeChecker(fetcher: fetcher, defaults: defaults, presenter: FakePresenter(), now: now)
        await checker.checkIfDue()?.value

        #expect(fetcher.callCount == 0)
    }

    // MARK: - 开关

    @MainActor
    @Test func disabledByDefaultIsFalse() {
        let defaults = makeDefaults()
        let checker = makeChecker(fetcher: FakeFetcher(result: .success(Self.makeRelease(tag: "v9.9.9"))), defaults: defaults, presenter: FakePresenter())
        #expect(checker.isEnabled) // 默认开启
    }

    @MainActor
    @Test func disablingStopsAutomaticChecks() async {
        let fetcher = FakeFetcher(result: .success(Self.makeRelease(tag: "v9.9.9")))
        let defaults = makeDefaults()
        let checker = makeChecker(fetcher: fetcher, defaults: defaults, presenter: FakePresenter())
        checker.isEnabled = false

        await checker.checkIfDue()?.value

        #expect(fetcher.callCount == 0)
        #expect(defaults.bool(forKey: UpdatePreferences.enabledKey) == false)
    }

    @MainActor
    @Test func switchPersistsToDefaults() {
        let defaults = makeDefaults()
        let checker = makeChecker(fetcher: FakeFetcher(result: .success(Self.makeRelease(tag: "v1.0.0"))), defaults: defaults, presenter: FakePresenter())
        checker.isEnabled = false
        #expect(defaults.object(forKey: UpdatePreferences.enabledKey) as? Bool == false)
    }

    // MARK: - 失败也记时间戳

    /// 断网时不该每次开面板都重试：失败同样写入时间戳。
    @MainActor
    @Test func failureStillRecordsCheckDate() async {
        let fetcher = FakeFetcher(result: .failure(ReleaseFetchError.unavailable))
        let defaults = makeDefaults()
        let checker = makeChecker(fetcher: fetcher, defaults: defaults, presenter: FakePresenter())

        await checker.checkIfDue()?.value

        #expect(fetcher.callCount == 1)
        #expect(defaults.object(forKey: UpdatePreferences.lastCheckDateKey) != nil)
    }

    // MARK: - 版本判定

    @MainActor
    @Test func noUpdateDoesNotWriteSkippedVersion() async {
        let fetcher = FakeFetcher(result: .success(Self.makeRelease(tag: "v0.3.1-beta.1")))
        let defaults = makeDefaults()
        let checker = makeChecker(fetcher: fetcher, defaults: defaults, presenter: FakePresenter(), current: "0.3.1")

        await checker.checkIfDue()?.value

        #expect(fetcher.callCount == 1)
        #expect(defaults.string(forKey: UpdatePreferences.skippedVersionKey) == nil)
    }

    @MainActor
    @Test func malformedRemoteTagDoesNotMarkSkipped() async {
        let fetcher = FakeFetcher(result: .success(Self.makeRelease(tag: "nightly-build")))
        let defaults = makeDefaults()
        let checker = makeChecker(fetcher: fetcher, defaults: defaults, presenter: FakePresenter())

        await checker.checkIfDue()?.value

        #expect(defaults.string(forKey: UpdatePreferences.skippedVersionKey) == nil)
    }

    // MARK: - 并发复用

    /// 连开几次面板只发一次请求：`inFlight` 会被复用。
    @MainActor
    @Test func concurrentChecksShareOneRequest() async {
        let fetcher = FakeFetcher(result: .success(Self.makeRelease(tag: "v0.3.1")))
        let defaults = makeDefaults()
        let checker = makeChecker(fetcher: fetcher, defaults: defaults, presenter: FakePresenter())

        async let first: Void = checker.checkNow()
        async let second: Void = checker.checkNow()
        async let third: Void = checker.checkNow()
        _ = await (first, second, third)

        #expect(fetcher.callCount == 1)
    }

    // MARK: - 提示内容

    /// 远端更高 → 弹更新窗，版本号已经剥掉 `v` 与 `-beta.N`。
    @MainActor
    @Test func presentsUpdateWhenRemoteIsNewer() async {
        let fetcher = FakeFetcher(result: .success(Self.makeRelease(tag: "v0.4.0-beta.1")))
        let presenter = FakePresenter()
        let checker = makeChecker(fetcher: fetcher, defaults: makeDefaults(), presenter: presenter)

        await checker.checkNow()

        #expect(presenter.updateVersions == ["0.4.0"])
        #expect(presenter.upToDateCalls == 0)
        #expect(presenter.failureCalls == 0)
    }

    /// 同版本（含 beta 后缀差异）不算新版本。
    @MainActor
    @Test func sameVersionReportsUpToDateOnManualCheck() async {
        let fetcher = FakeFetcher(result: .success(Self.makeRelease(tag: "v0.3.1-beta.1")))
        let presenter = FakePresenter()
        let checker = makeChecker(fetcher: fetcher, defaults: makeDefaults(), presenter: presenter, current: "0.3.1")

        await checker.checkNow()

        #expect(presenter.updateVersions.isEmpty)
        #expect(presenter.upToDateCalls == 1)
    }

    @MainActor
    @Test func manualFailureIsReported() async {
        let fetcher = FakeFetcher(result: .failure(ReleaseFetchError.unavailable))
        let presenter = FakePresenter()
        let checker = makeChecker(fetcher: fetcher, defaults: makeDefaults(), presenter: presenter)

        await checker.checkNow()

        #expect(presenter.failureCalls == 1)
    }

    /// 后台检查失败必须完全静默——不能因为断网就在启动时弹错误框。
    @MainActor
    @Test func automaticFailureIsSilent() async {
        let fetcher = FakeFetcher(result: .failure(ReleaseFetchError.unavailable))
        let presenter = FakePresenter()
        let checker = makeChecker(fetcher: fetcher, defaults: makeDefaults(), presenter: presenter)

        await checker.checkIfDue()?.value

        #expect(presenter.failureCalls == 0)
        #expect(presenter.updateVersions.isEmpty)
    }

    /// 用户点「稍后」→ 该版本永久静默；之后的自动检查不再弹窗。
    @MainActor
    @Test func tappingLaterSilencesThatVersion() async {
        let fetcher = FakeFetcher(result: .success(Self.makeRelease(tag: "v0.4.0")))
        let presenter = FakePresenter()
        presenter.choice = .later
        let defaults = makeDefaults()
        let now = Date()
        let checker = makeChecker(fetcher: fetcher, defaults: defaults, presenter: presenter, now: now)

        await checker.checkNow()
        #expect(presenter.updateVersions == ["0.4.0"])
        #expect(defaults.string(forKey: UpdatePreferences.skippedVersionKey) == "0.4.0")

        // 隔天再自动检查：同一版本不再打扰。
        let later = now.addingTimeInterval(UpdatePreferences.checkInterval + 60)
        let secondPresenter = FakePresenter()
        let secondFetcher = FakeFetcher(result: .success(Self.makeRelease(tag: "v0.4.0")))
        let secondChecker = UpdateChecker(
            fetch: secondFetcher,
            defaults: defaults,
            presenter: secondPresenter,
            currentVersion: SemanticVersion(tag: "0.3.1"),
            now: { later }
        )

        await secondChecker.checkIfDue()?.value

        #expect(secondFetcher.callCount == 1)
        #expect(secondPresenter.updateVersions.isEmpty)
    }

    /// 静默只针对那一版：更高版本仍然弹窗。
    @MainActor
    @Test func newerVersionBreaksThroughSkip() async {
        let defaults = makeDefaults()
        defaults.set("0.4.0", forKey: UpdatePreferences.skippedVersionKey)
        let presenter = FakePresenter()
        let checker = makeChecker(
            fetcher: FakeFetcher(result: .success(Self.makeRelease(tag: "v0.5.0"))),
            defaults: defaults,
            presenter: presenter
        )

        await checker.checkNow()

        #expect(presenter.updateVersions == ["0.5.0"])
    }

    // MARK: - 应用内下载编排

    /// 假下载器：记录被请求的资产，可控制成功 / 失败。
    private final class FakeDownloader: UpdateDownloading {
        let result: Result<URL, UpdateDownloadError>
        /// 用 `LockedFlag` 思路的轻量互斥，避开在 async 上下文直接拿 `NSLock`。
        private let names = LockedNames()

        var requestedNames: [String] {
            names.all
        }

        init(result: Result<URL, UpdateDownloadError>) {
            self.result = result
        }

        func download(
            _ asset: ReleaseAsset,
            onProgress: @Sendable @escaping (Double?) -> Void
        ) async throws -> URL {
            names.append(asset.name)
            onProgress(0.5)
            return try result.get()
        }
    }

    /// 下载器用的线程安全可变数组。
    private final class LockedNames: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []

        var all: [String] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }

        func append(_ value: String) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }
    }

    /// 用户选「立即下载」且下载成功 → 走保存面板 → 提示完成。
    @MainActor
    @Test func inAppDownloadSuccessSavesAndNotifies() async {
        let localURL = URL(fileURLWithPath: "/tmp/IceShot-9.9.9.dmg")
        let savedURL = URL(fileURLWithPath: "/tmp/saved/IceShot-9.9.9.dmg")
        let downloader = FakeDownloader(result: .success(localURL))
        let presenter = FakePresenter()
        presenter.choice = .downloadInApp
        presenter.saveDestination = savedURL

        let checker = UpdateChecker(
            fetch: FakeFetcher(result: .success(Self.makeRelease(tag: "v9.9.9", withDiskImage: true))),
            defaults: makeDefaults(),
            presenter: presenter,
            downloader: downloader,
            currentVersion: SemanticVersion(tag: "0.3.1")
        )

        await checker.checkNow()
        // 下载在内部 Task 里跑，等它完成
        try? await Task.sleep(for: .milliseconds(150))

        #expect(downloader.requestedNames == ["IceShot-v9.9.9.dmg"])
        #expect(presenter.finishedURLs == [savedURL])
        #expect(presenter.downloadFailureCalls == 0)
    }

    /// 校验失败要报错，且**不**走保存面板。
    @MainActor
    @Test func checksumMismatchReportsFailureWithoutSaving() async {
        let downloader = FakeDownloader(result: .failure(.checksumMismatch))
        let presenter = FakePresenter()
        presenter.choice = .downloadInApp
        presenter.saveDestination = URL(fileURLWithPath: "/tmp/should-not-save.dmg")

        let checker = UpdateChecker(
            fetch: FakeFetcher(result: .success(Self.makeRelease(tag: "v9.9.9", withDiskImage: true))),
            defaults: makeDefaults(),
            presenter: presenter,
            downloader: downloader,
            currentVersion: SemanticVersion(tag: "0.3.1")
        )

        await checker.checkNow()
        try? await Task.sleep(for: .milliseconds(150))

        #expect(presenter.downloadFailureCalls == 1)
        #expect(presenter.finishedURLs.isEmpty)
    }

    /// 没有下载器时界面不能提供「立即下载」，选到它要降级到网页而不是静默失败。
    @MainActor
    @Test func downloadChoiceWithoutDownloaderFallsBackToWeb() async {
        let presenter = FakePresenter()
        presenter.choice = .downloadInApp

        let checker = UpdateChecker(
            fetch: FakeFetcher(result: .success(Self.makeRelease(tag: "v9.9.9", withDiskImage: true))),
            defaults: makeDefaults(),
            presenter: presenter,
            downloader: nil,
            currentVersion: SemanticVersion(tag: "0.3.1")
        )

        await checker.checkNow()
        try? await Task.sleep(for: .milliseconds(100))

        // 降级：不报失败，也不声称完成。
        #expect(presenter.downloadFailureCalls == 0)
        #expect(presenter.finishedURLs.isEmpty)
    }

    /// 用户在保存面板取消 → 不提示完成，也不算失败。
    @MainActor
    @Test func cancellingSavePanelIsSilent() async {
        let downloader = FakeDownloader(result: .success(URL(fileURLWithPath: "/tmp/x.dmg")))
        let presenter = FakePresenter()
        presenter.choice = .downloadInApp
        presenter.saveDestination = nil

        let checker = UpdateChecker(
            fetch: FakeFetcher(result: .success(Self.makeRelease(tag: "v9.9.9", withDiskImage: true))),
            defaults: makeDefaults(),
            presenter: presenter,
            downloader: downloader,
            currentVersion: SemanticVersion(tag: "0.3.1")
        )

        await checker.checkNow()
        try? await Task.sleep(for: .milliseconds(150))

        #expect(presenter.finishedURLs.isEmpty)
        #expect(presenter.downloadFailureCalls == 0)
    }
}
