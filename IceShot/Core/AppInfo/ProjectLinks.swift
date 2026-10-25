import Foundation

/// 项目对外的固定链接。
///
/// 集中在一处，避免 URL 散落在各个 View 里改一处漏一处。
/// 打包脚本的通道（`ICESHOT_CHANNEL`）只影响 DMG 文件名，不影响版本号，
/// 所以 beta 与正式版指向同一批链接，不需要按通道分支。
///
/// 这些链接只在用户**主动点击**时交给 `NSWorkspace` 打开，
/// App 自身不发任何网络请求，沙盒也没有联网权限。
enum ProjectLinks {
    /// 仓库首页：源码、文档、issue。
    nonisolated static let repository = URL(string: "https://github.com/aice109/ice-shot")!

    /// 最新 Release：GitHub 自动解析到最新一条发布，直接给出更新日志与安装包。
    nonisolated static let latestRelease = URL(string: "https://github.com/aice109/ice-shot/releases/latest")!
}
