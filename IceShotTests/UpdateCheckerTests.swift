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

    private static func makeRelease(tag: String) -> RemoteRelease {
        RemoteRelease(
            tagName: tag,
            htmlURL: URL(string: "https://github.com/aice109/ice-shot/releases/tag/\(tag)")!,
            notes: "- 修了点东西"
        )
    }

    /// 假呈现层：只记录被要求展示什么，绝不弹真窗（`NSAlert.runModal()` 会阻塞到用户点击）。
    @MainActor
    private final class FakePresenter: UpdatePresenting {
        var updateVersions: [String] = []
        var upToDateCalls = 0
        var failureCalls = 0
        /// 「前往下载」是否被选中；`false` 模拟用户点「稍后」。
        var userOpensDownload = true

        func presentUpdate(version: String, notes: String, channelTag: String?) -> Bool {
            updateVersions.append(version)
            return userOpensDownload
        }

        func presentUpToDate(currentVersion: String, channelTag: String?) {
            upToDateCalls += 1
        }

        func presentFailure() {
            failureCalls += 1
        }
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
        presenter.userOpensDownload = false
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
}
