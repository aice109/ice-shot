import Foundation

/// GitHub Release 里的一个可下载资产。
struct ReleaseAsset: Equatable, Sendable {
    let name: String
    let url: URL
    /// 同名 `.sha256` 文件的地址；没有该资产时为 `nil`，此时跳过校验。
    let checksumTextURL: URL?
}

/// 从 GitHub Release 接口取回的、界面真正需要的那几个字段。
///
/// 刻意只保留必要项：完整响应有几十个字段，其中 `author`、`node_id` 之类
/// 对「提示一下然后下载」毫无用处，留着只会扩大解码失败的面。
struct RemoteRelease: Equatable, Sendable {
    /// `v0.3.2-beta.1` 这样的原始 tag，交给 `SemanticVersion` 解析。
    let tagName: String
    /// 该 Release 的网页地址；网页下载作为兜底路径。
    let htmlURL: URL
    /// Release 正文（Markdown），由 `ReleaseNotesText` 清洗截断后再展示。
    let notes: String
    /// 可下载的安装包；没有可用 `.dmg` 时为空，界面退回网页下载。
    let diskImage: ReleaseAsset?
}
