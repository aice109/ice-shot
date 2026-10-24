import AppKit
import CoreGraphics

/// 指针光标的**唯一映射**：把「这里现在能做什么」翻译成系统 `NSCursor`。
///
/// 为什么要有这一层：
/// - `NSCursor.set()` 是**全局压栈式**的，谁都可以改、谁都应该记得改回来。
///   以前每个视图各写一套 `if edge { ... } else { .arrow.set() }`，漏一处就是
///   「悬停到可缩放的边缘上却还是箭头」——贴图、选区手柄、裁剪框各错各的。
/// - 现在只允许两件事：视图**声明**应该显示什么（`.pointerCursor(_:)`），
///   以及 `push()` / `pop()` 成对地临时覆盖（拖拽中）。不许再散写 `NSCursor.xxx.set()`。
///
/// 本类型是纯数据 + 一次系统调用，方向判定可以直接单测。
enum PointerCursor: Equatable {
    case arrow
    /// 可抓取（点住会移动整块内容，但此刻还没按下）。
    case openHand
    /// 正在拖动。
    case closedHand
    /// 绘制 / 拉新框。
    case crosshair
    /// 文本输入：文字工具下悬停可用“这里可以打字”。
    case iBeam
    /// 可整块搬走（贴图这类「挪动窗口」语义）。
    ///
    /// 具体映射到 `openHand`：AppKit 没有公开的四向移动箭头，手形才是系统里的
    /// 「可拖动 / 可抓取」语义，与窗口移动、选区平移保持一致。
    case move
    case resize(ResizeAxis)
    /// 拖拽中已经「抓住」某个方向的手柄，松手前一直显示对应缩放箭头。
    case resizing(ResizeAxis)

    /// 实际的系统光标。
    var system: NSCursor {
        switch self {
        case .arrow:
            return .arrow
        case .openHand:
            return .openHand
        case .closedHand:
            return .closedHand
        case .crosshair:
            return .crosshair
        case .iBeam:
            return .iBeam
        case .move:
            // AppKit 没有公开的「四向移动箭头」（只有私有 `_moveCursor`），
            // 用公开的 `openHand`：它表达的就是「这整块可以抓走」。
            return .openHand
        case .resize(let axis), .resizing(let axis):
            return axis.system
        }
    }
}

/// 缩放的 8 个方向（与手柄 / 边角一一对应）。
enum ResizeAxis: Equatable, CaseIterable {
    case top
    case bottom
    case leading
    case trailing
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing

    /// 对面那条边 / 角；用于自测与「保持对面不动」类逻辑。
    var opposite: ResizeAxis? {
        switch self {
        case .top: return .bottom
        case .bottom: return .top
        case .leading: return .trailing
        case .trailing: return .leading
        case .topLeading: return .bottomTrailing
        case .topTrailing: return .bottomLeading
        case .bottomLeading: return .topTrailing
        case .bottomTrailing: return .topLeading
        }
    }

    /// 角对应的两条边；边本身返回 `nil`（不自指）。
    var adjacentEdges: [ResizeAxis]? {
        switch self {
        case .topLeading: return [.top, .leading]
        case .topTrailing: return [.top, .trailing]
        case .bottomLeading: return [.bottom, .leading]
        case .bottomTrailing: return [.bottom, .trailing]
        case .top, .bottom, .leading, .trailing: return nil
        }
    }

    /// 两个方向是否共用同一个系统光标（上下同轴、对角同一条斜向）。
    ///
    /// macOS 的缩放箭头本质上是双向的：上 / 下都是 ↕，左上 / 右下是同一条斜向箭头。
    /// 这不是缺陷，导出时靠这个断言锁住「换轴一定换光标」。
    func sharesCursor(with other: ResizeAxis) -> Bool {
        switch (self, other) {
        case (.top, .bottom), (.bottom, .top),
             (.leading, .trailing), (.trailing, .leading),
             (.topLeading, .bottomTrailing), (.bottomTrailing, .topLeading),
             (.topTrailing, .bottomLeading), (.bottomLeading, .topTrailing):
            return true
        default:
            return false
        }
    }

    /// 是不是角（角的判定优先于边）。
    var isCorner: Bool {
        switch self {
        case .topLeading, .topTrailing, .bottomLeading, .bottomTrailing:
            return true
        case .top, .bottom, .leading, .trailing:
            return false
        }
    }

    /// macOS 原生缩放箭头。左右 / 上下用方向明确的两向箭头，
    /// 四角用系统 `frameResize`（macOS 11+），与窗口边缘缩放手感一致。
    var system: NSCursor {
        switch self {
        case .top, .bottom:
            return .resizeUpDown
        case .leading, .trailing:
            return .resizeLeftRight
        case .topLeading:
            return .frameResize(position: .topLeft, directions: .all)
        case .topTrailing:
            return .frameResize(position: .topRight, directions: .all)
        case .bottomLeading:
            return .frameResize(position: .bottomLeft, directions: .all)
        case .bottomTrailing:
            return .frameResize(position: .bottomRight, directions: .all)
        }
    }
}

// MARK: - 光标用法

extension PointerCursor {
    /// 立刻生效（不进栈）。
    ///
    /// 只在「鼠标确实停在这里」时调用；视图生命周期或悬停状态的变化请用
    /// `.pointerCursor(_:)` 声明式接入，别在这里散写。
    func apply() {
        system.set()
    }

    /// 压栈覆盖：用于拖拽期间临时改光标（按下时 push，松手时 pop）。
    ///
    /// `NSCursor` 的栈是全局的，调用方必须**成对**调用；配对由
    /// `PointerCursorStack` 这类持有者保证，业务视图不要自己数次数。
    func push() {
        system.push()
    }

    /// 恢复上一个光标（与 `push()` 配对）。
    static func pop() {
        NSCursor.pop()
    }
}
