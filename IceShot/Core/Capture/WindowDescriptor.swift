import CoreGraphics
import Foundation

/// 一个可截取窗口的瞬时描述。
///
/// 只保存在内存中的选择目录里；窗口标题 / 应用名不写日志、不落盘。
struct WindowDescriptor: Sendable, Identifiable, Hashable {
    let id: CGWindowID
    let frame: CGRect
    let ownerPID: pid_t
    let ownerName: String
    /// 归属应用的 bundle ID；系统 overlay（通知中心等）靠它精确识别。
    /// 窗口没有归属应用时为空。
    let ownerBundleID: String?
    let title: String?
    let layer: Int
    let isOnScreen: Bool
    let isActive: Bool

    init(
        id: CGWindowID,
        frame: CGRect,
        ownerPID: pid_t,
        ownerName: String,
        ownerBundleID: String? = nil,
        title: String?,
        layer: Int,
        isOnScreen: Bool,
        isActive: Bool
    ) {
        self.id = id
        self.frame = frame
        self.ownerPID = ownerPID
        self.ownerName = ownerName
        self.ownerBundleID = ownerBundleID
        self.title = title
        self.layer = layer
        self.isOnScreen = isOnScreen
        self.isActive = isActive
    }

    var displayName: String {
        if isMenuBarSurface { return "菜单栏" }
        if isDesktopSurface { return "桌面" }
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedTitle, !trimmedTitle.isEmpty else {
            return ownerName.isEmpty ? "未命名窗口" : ownerName
        }
        guard !ownerName.isEmpty else {
            return trimmedTitle
        }
        return "\(ownerName) — \(trimmedTitle)"
    }

    /// 桌面 / 壁纸：窗口服务器的负层级。
    var isDesktopSurface: Bool {
        layer < 0
    }

    /// 菜单栏（`kCGMainMenuWindowLevel`）：一条横条，没有可用的独立窗口内容。
    var isMenuBarSurface: Bool {
        layer == WindowFilter.menuBarLayer
    }

    /// 系统表面：桌面与菜单栏。它们没有可靠的独立窗口图，截取时改用冻结帧裁切。
    var isSystemSurface: Bool {
        isDesktopSurface || isMenuBarSurface
    }

    /// 整块显示器都被这个窗口的 frame 盖住。
    func covers(_ displayFrame: CGRect) -> Bool {
        frame.contains(displayFrame)
    }
}

enum WindowFilter {
    static let defaultMinimumSize = CGSize(width: 24, height: 24)

    /// 菜单栏窗口层级（`kCGMainMenuWindowLevel`）。它上面是状态栏项（25）与各种
    /// 弹出层 / HUD，再往上还有屏保（1000）——IceShot 自己的截取浮层就在那一层。
    static let menuBarLayer = 24
    /// Dock 的窗口上报整屏 frame（放大层），入选会把所有点都抢走，必须单独排除。
    static let dockLayer = 20
    /// 可作为截取目标的最高层级；桌面 / 壁纸是负层级，一并放行。
    static let maximumSelectableLayer = menuBarLayer

    /// 通知中心的 bundle ID。
    ///
    /// 通知横幅是一个**铺满整屏**、层级 21 的窗口（实测 `frame = (0, 0, 1920, 1080)`）。
    /// 它一旦入选窗口目录，`hitTest` 会在屏幕任意位置优先命中它，点击即变成
    /// 「只截通知」——用 `desktopIndependentWindow` 抓它只会得到通知本体 +
    /// 其余区域全透明，用户看到的就是一张空白图。所以按 bundle ID 精确排除。
    static let notificationCenterBundleID = "com.apple.notificationcenterui"

    /// 系统 overlay 的层级区间：高于 Dock、低于菜单栏。
    /// 通知中心（21）就在这一段；正常应用窗口在 layer 0，不在此列。
    static let systemOverlayLayerRange = (dockLayer + 1)...(menuBarLayer - 1)

    /// 过滤掉不可截取的层级、Dock、过小窗口与屏幕外的窗口。
    ///
    /// 桌面与菜单栏是用户明确要求可截的系统表面，保留在目录里；
    /// 自身截取浮层 / HUD 靠层级排除（1000），不靠 PID。
    static func selectable(
        windows: [WindowDescriptor],
        displayFrames: [CGRect],
        minimumSize: CGSize = defaultMinimumSize
    ) -> [WindowDescriptor] {
        windows.filter { window in
            guard window.id != 0,
                  window.layer <= maximumSelectableLayer,
                  window.layer != dockLayer,
                  window.isOnScreen,
                  window.frame.width >= minimumSize.width,
                  window.frame.height >= minimumSize.height else {
                return false
            }
            // 桌面组里窗口服务器的辅助层（Backstop / underbelly）没有应用名，
            // 截它们只会得到一条毫无意义的色带；壁纸与桌面本身有归属应用。
            if window.layer < 0, window.ownerName.isEmpty {
                return false
            }
            if isTransientSystemOverlay(window, displayFrames: displayFrames) {
                return false
            }
            return displayFrames.contains { $0.intersects(window.frame) }
        }
    }

    /// 临时系统 overlay（通知横幅等）：铺满整屏、处在系统 overlay 层级、不是应用窗口。
    ///
    /// 这类窗口没有独立的可截内容，却因为 frame 盖住整屏而抢走 `hitTest`，
    /// 会让「点一下截窗口」退化成截一张空白图。
    static func isTransientSystemOverlay(
        _ window: WindowDescriptor,
        displayFrames: [CGRect]
    ) -> Bool {
        // 通知中心：按 bundle ID 精确排除（应用名会随系统语言变化，不可靠）。
        if window.ownerBundleID == notificationCenterBundleID {
            return true
        }
        // 兜底：其他铺满整屏的系统 overlay 同样没有可截内容。
        guard systemOverlayLayerRange.contains(window.layer) else {
            return false
        }
        return displayFrames.contains { window.covers($0) }
    }

    /// `windows` 必须按前到后排序；返回最前面的命中窗口。
    static func hitTest(at point: CGPoint, in windows: [WindowDescriptor]) -> WindowDescriptor? {
        windows.first { $0.frame.contains(point) }
    }
}

enum WindowOrdering {
    /// 用 CGWindowList 的前到后顺序重排；不在列表中的窗口保持原相对顺序并排在后面。
    static func sorted(
        _ windows: [WindowDescriptor],
        frontToBackIDs: [CGWindowID]
    ) -> [WindowDescriptor] {
        var rank: [CGWindowID: Int] = [:]
        for (index, id) in frontToBackIDs.enumerated() where rank[id] == nil {
            rank[id] = index
        }
        return windows.enumerated().sorted { lhs, rhs in
            let leftRank = rank[lhs.element.id] ?? Int.max
            let rightRank = rank[rhs.element.id] ?? Int.max
            if leftRank != rightRank {
                return leftRank < rightRank
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}
