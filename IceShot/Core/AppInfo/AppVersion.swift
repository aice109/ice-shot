import Foundation

/// 发布通道。
///
/// `CFBundleShortVersionString` 按 Apple 规范只放数字与点（`0.2.2`），
/// 所以“还在打磨”这件事不能塞进版本号；单独用这条通道标识：
/// - 界面：菜单栏面板与设置页的版本行显示 `Beta`；
/// - 产物：`Scripts/package.sh` 把通道拼进 DMG 文件名（`IceShot-0.2.2-beta.dmg`），
///   两个包不会搞混。
///
/// 发正式版时只改 `AppVersion.channel` 一处（改成 `.stable`），其它都自动跟随。
enum ReleaseChannel: String {
    case stable
    case beta

    // 通道要在 `nonisolated` 的版本展示函数里读取，这里显式标 nonisolated。
    nonisolated var isBeta: Bool { self == .beta }

    /// 界面上的短标签；正式版不显示。
    nonisolated var tag: String? { isBeta ? "Beta" : nil }
}

/// 应用自身版本信息。
///
/// 版本号只来自工程里的 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`（`Scripts/package.sh`
/// 可在打包时覆盖）。界面里不允许再写死版本号，统一走这里读 `Bundle`。
enum AppVersion {
    /// 当前构建的发布通道。开发阶段是 `.beta`，正式发版前改成 `.stable`。
    nonisolated static let channel: ReleaseChannel = .beta

    nonisolated static var shortVersion: String {
        value(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "0.0.0"
    }

    nonisolated static var buildNumber: String {
        value(forInfoDictionaryKey: "CFBundleVersion") ?? "0"
    }

    /// 设置页展示用：`0.2.2 (4) · Beta` / 正式版 `1.0.0 (12)`。
    nonisolated static var displayText: String {
        text(version: shortVersion, build: buildNumber, channel: channel)
    }

    /// 拼装格式抽出来，方便单测覆盖两种通道。
    nonisolated static func text(version: String, build: String, channel: ReleaseChannel) -> String {
        let base = "\(version) (\(build))"
        guard let tag = channel.tag else { return base }
        return "\(base) · \(tag)"
    }

    nonisolated private static func value(forInfoDictionaryKey key: String, bundle: Bundle = .main) -> String? {
        guard let raw = bundle.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
