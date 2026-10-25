import Foundation
import Testing
@testable import IceShot

/// 延时截图偏好。
///
/// 菜单里原来有 12 条「模式 × 秒数」组合，现在只留一个入口，
/// 秒数在这里配。所以「存进去的怪数字必须被挡回默认」是这层唯一的职责。
struct CapturePreferencesTests {
    /// 用独立 suite 的 UserDefaults，避免污染真实偏好。
    private func makeDefaults() -> UserDefaults {
        let suiteName = "CapturePreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test func defaultsToThreeSecondsWhenUnset() {
        let defaults = makeDefaults()
        #expect(CapturePreferences.countdownSeconds(from: defaults) == 3)
    }

    /// 每一档可选值都必须能原样读回——否则设置界面上选了却不生效。
    @Test func everyOptionRoundTrips() {
        for seconds in CapturePreferences.countdownOptions {
            let defaults = makeDefaults()
            defaults.set(seconds, forKey: CapturePreferences.countdownSecondsKey)
            #expect(CapturePreferences.countdownSeconds(from: defaults) == seconds)
        }
    }

    /// 手改偏好写进一个不在档位里的值（0、负数、未列出的秒数）时退回默认，
    /// 而不是让菜单拿一个奇怪的倒计时。
    @Test func rejectsValuesOutsideOptions() {
        for bogus in [0, -5, 1, 2, 7, 60, 3600] {
            let defaults = makeDefaults()
            defaults.set(bogus, forKey: CapturePreferences.countdownSecondsKey)
            #expect(
                CapturePreferences.countdownSeconds(from: defaults)
                    == CapturePreferences.defaultCountdownSeconds,
                "越界值 \(bogus) 应退回默认"
            )
        }
    }

    /// 默认值本身必须是合法档位，否则全新安装就落在「越界」分支里。
    @Test func defaultIsOneOfTheOptions() {
        #expect(CapturePreferences.countdownOptions.contains(CapturePreferences.defaultCountdownSeconds))
    }
}
