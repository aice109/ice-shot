import AppKit
import SwiftUI

/// 声明式光标：视图只说「此刻应该显示什么」，`set` / 恢复由这里统一负责。
///
/// 用法：
/// ```swift
/// someView
///     .onContinuousHover { ... 记下指针位置 ... }
///     .pointerCursor(hoverAxis.map(PointerCursor.resizing) ?? .arrow)
/// ```
///
/// 为什么不能在各处直接 `NSCursor.xxx.set()`：
/// - `NSCursor.set()` 是全局状态，视图消失 / 被替换后没人恢复，
///   光标会停在整块屏幕上不还原；
/// - 多个视图各自「看到自己不需要就设箭头」，顺序不可控，会互相覆盖。
///
/// 这里只在两种时机动作：悬停指针位置变化（重算光标）、视图消失（还原箭头）。
/// 拖拽中的临时覆盖走 `PointerCursorStack`，与本修饰器互不干涉。
struct PointerCursorModifier: ViewModifier {
    let cursor: PointerCursor

    func body(content: Content) -> some View {
        content
            .onChange(of: cursor, initial: true) { _, newValue in
                newValue.apply()
            }
            .onDisappear {
                PointerCursor.arrow.apply()
            }
    }
}

extension View {
    /// 声明该视图当前应该显示的光标（进入 / 变化时 `set`，消失时还原箭头）。
    func pointerCursor(_ cursor: PointerCursor) -> some View {
        modifier(PointerCursorModifier(cursor: cursor))
    }

    /// 只在「有话说」时声明光标；`nil` 表示不表态，留给别的视图决定。
    ///
    /// 用于多个视图叠在同一位置、且各自只在特定条件下接管的场景
    /// （如选区手续 / Space 平移层）。所有层都写 `.arrow` 会互相覆盖。
    func pointerCursorIfPresent(_ cursor: PointerCursor?) -> some View {
        modifier(OptionalPointerCursorModifier(cursor: cursor))
    }
}

/// 可选版本的 `pointerCursor`：`nil` 时完全不动作（既不 `set` 也不还原）。
private struct OptionalPointerCursorModifier: ViewModifier {
    let cursor: PointerCursor?

    func body(content: Content) -> some View {
        content.onChange(of: cursor, initial: true) { _, newValue in
            guard let newValue else { return }
            newValue.apply()
        }
    }
}

/// 拖拽期间的光标覆盖：按下时 `push`，松手时 `pop`，**保证成对**。
///
/// `NSCursor` 的 push / pop 是全局栈，多推一次、少弹一次都会让光标永久错位。
/// 把这一对收进一个「只会弹一次」的持有者里，业务代码不数次数。
@MainActor
final class PointerCursorStack {
    private var isPushed = false

    /// 压栈并显示拖拽光标；已经压过就只改显示，不会重复入栈。
    func push(_ cursor: PointerCursor) {
        if isPushed {
            cursor.apply()
            return
        }
        cursor.push()
        isPushed = true
    }

    /// 出栈；没压过就什么都不做。
    func pop() {
        guard isPushed else { return }
        PointerCursor.pop()
        isPushed = false
    }
}
