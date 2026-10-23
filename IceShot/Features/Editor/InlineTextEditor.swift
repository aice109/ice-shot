import AppKit
import SwiftUI

/// 画布内就地文字输入：一个**没有底色、没有边框、没有内缩**的 `NSTextView`。
///
/// 输入框**自己就是最终样子**：字号、字重、文字色按标注样式给，背景块由调用方按最终几何
/// 画在它下面。所以打字过程中看到的就是提交后的结果，画布不需要也不该再画一份。
///
/// 为什么是 `NSTextView` 而不是 `NSTextField`：`NSTextField` 的 cell 会自己决定字形的
/// 垂直位置（实测比画布上的文字高 2–7 pt，字号越大差得越多），输入中与提交后对不齐。
/// 这里把 `textContainerInset` 与 `lineFragmentPadding` 都设成 0，字形落点与 `Canvas`
/// 里 `Text(...)` 的 `.topLeading` 实测一致（16 / 24 / 32 / 48 pt 都一样）。
///
/// 交互约定：<kbd>Return</kbd> 提交、<kbd>Esc</kbd> 取消、失焦 / 点画布其它位置提交。
struct InlineTextEditor: NSViewRepresentable {
    @Binding var text: String
    /// 视图坐标下的字号（已按画布缩放）；与最终绘制同一个字号。
    var fontSize: CGFloat
    /// 文字色：标注色，带背景时是对比色。
    var textColor: NSColor
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextView {
        let view = InlineTextView()
        view.delegate = context.coordinator
        view.drawsBackground = false
        view.isRichText = false
        view.isEditable = true
        view.isSelectable = true
        // 单行、不换行、可横向超出：宽度由调用方按文字宽度给，允许光标探出一点点。
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = true
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.size = CGSize(
            width: Self.unboundedLength,
            height: Self.unboundedLength
        )
        // 截图上的字不该被画红波浪线；拼写 / 语法检查一律关掉。
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.string = text
        view.font = Self.font(size: fontSize)
        view.textColor = textColor
        view.insertionPointColor = textColor
        view.setAccessibilityLabel("标注文字")
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.parent = self
        // 正在输入时 `view.string` 已经是真值；只有外部改动才回写，否则会打断输入法 / 光标位置。
        if view.string != text {
            view.string = text
        }
        if abs((view.font?.pointSize ?? 0) - fontSize) > 0.01 {
            view.font = Self.font(size: fontSize)
        }
        // 输入中改颜色要立刻可见：文字色与光标色一起换（深底上默认光标会看不见）。
        if view.textColor != textColor {
            view.textColor = textColor
            view.insertionPointColor = textColor
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    private static func font(size: CGFloat) -> NSFont {
        // 不设可读性下限：输入框字号就是最终绘制字号，否则「输入中」与「提交后」会对不上。
        .systemFont(ofSize: max(1, size), weight: .semibold)
    }

    private static var unboundedLength: CGFloat { 10_000 }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: InlineTextEditor
        private var isFinished = false

        init(parent: InlineTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }

        func textDidEndEditing(_ notification: Notification) {
            // 失焦（点了别处 / 浮层收尾）按提交处理，避免输入内容丢失。
            finish(submit: true)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                finish(submit: true)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                finish(submit: false)
                return true
            default:
                return false
            }
        }

        private func finish(submit: Bool) {
            guard !isFinished else { return }
            isFinished = true
            if submit {
                parent.onSubmit()
            } else {
                parent.onCancel()
            }
        }
    }
}

/// 首次进入窗口就抢焦点并全选，方便直接覆写已有文字。
private final class InlineTextView: NSTextView {
    private var hasFocused = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !hasFocused, let window else { return }
        hasFocused = true
        window.makeFirstResponder(self)
        selectAll(nil)
    }
}
