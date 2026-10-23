import Foundation
#if DEBUG
import OSLog
#endif

/// `Esc` 路径诊断：只在 Debug 构建写统一日志，**不含任何截图内容**（只有键码与布尔状态）。
///
/// 取字模式下 `Esc` 可能被 `Live Text` 的文本视图吞掉，走过哪一层只能靠日志判断；
/// Release 构建里这个函数是空实现。
enum EscapeTrace {
    static func log(_ layer: String, _ detail: @autoclosure @escaping () -> String = "") {
        #if DEBUG
        logger.debug("[\(layer, privacy: .public)] \(detail(), privacy: .public)")
        #endif
    }

    #if DEBUG
    private static let logger = Logger(
        subsystem: "com.aice109.IceShot.dev",
        category: "escape"
    )
    #endif
}
