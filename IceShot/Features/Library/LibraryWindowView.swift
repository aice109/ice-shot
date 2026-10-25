import SwiftData
import SwiftUI

/// 历史记录独立窗口的根视图。
///
/// 历史库不可用（数据库打不开等）时降级为说明页，而不是让窗口空白或崩溃；
/// 启动错误由 `AppDelegate` 传入，便于用户知道该检查磁盘还是权限。
struct LibraryWindowView: View {
    let library: LibraryStore?
    let container: ModelContainer?
    let editor: EditorOpening?
    let pins: PinBoard?
    let feedback: FeedbackHUDController?
    let startupError: String?

    var body: some View {
        if let library, let container {
            LibraryView(library: library, editor: editor, pins: pins)
                .feedbackHUD(feedback)
                .modelContainer(container)
                .frame(minWidth: 820, minHeight: 520)
        } else {
            ContentUnavailableView(
                String(localized: "历史库不可用"),
                systemImage: "externaldrive.badge.exclamationmark",
                description: Text(startupError ?? "无法打开本机历史记录存储。")
            )
            .frame(minWidth: 520, minHeight: 360)
        }
    }
}
