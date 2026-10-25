import CoreGraphics
import Foundation
import Testing
@testable import IceShot

/// 窗口目录过滤与命中：排除系统 chrome / 桌面 / 过小窗口，命中按前到后取最上层。
@MainActor
struct WindowFilterTests {
    private func window(
        id: CGWindowID,
        frame: CGRect = CGRect(x: 100, y: 100, width: 600, height: 400),
        ownerPID: pid_t = 42,
        ownerName: String = "App",
        ownerBundleID: String? = nil,
        title: String? = "Window",
        layer: Int = 0,
        isOnScreen: Bool = true
    ) -> WindowDescriptor {
        WindowDescriptor(
            id: id,
            frame: frame,
            ownerPID: ownerPID,
            ownerName: ownerName,
            ownerBundleID: ownerBundleID,
            title: title,
            layer: layer,
            isOnScreen: isOnScreen,
            isActive: true
        )
    }

    @Test func selectableRejectsNotificationCenterBanner() {
        // 通知横幅：frame 铺满整屏、层级 21。入选会让 hitTest 在任意位置优先命中它，
        // 点击就退化成「只截通知」——抓到的是透明底 + 通知本体。
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let windows = [
            window(id: 1),
            window(
                id: 2,
                frame: display,
                ownerName: "通知中心",
                ownerBundleID: WindowFilter.notificationCenterBundleID,
                title: nil,
                layer: 21
            ),
        ]

        let result = WindowFilter.selectable(windows: windows, displayFrames: [display])

        #expect(result.map(\.id) == [1])
    }

    @Test func selectableRejectsFullScreenSystemOverlayWithoutBundleID() {
        // 兜底规则：拿不到 bundle ID 的系统 overlay，只要铺满整屏、处在 overlay 层级，也不可选。
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let windows = [
            window(id: 1),
            window(id: 2, frame: display, ownerName: "System", title: nil, layer: 21),
            window(id: 3, frame: display, ownerName: "System", title: nil, layer: 23),
        ]

        let result = WindowFilter.selectable(windows: windows, displayFrames: [display])

        #expect(result.map(\.id) == [1])
    }

    @Test func selectableKeepsFullScreenAppAndSmallOverlay() {
        // 正常全屏应用在 layer 0，不能被 overlay 规则误伤；
        // overlay 层级但没铺满整屏（小 HUD）也不是劫持源，照旧保留。
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let windows = [
            window(id: 1, frame: display, title: "Full Screen", layer: 0),
            window(
                id: 2,
                frame: CGRect(x: 1440, y: 900, width: 200, height: 100),
                title: nil,
                layer: 21
            ),
        ]

        let result = WindowFilter.selectable(windows: windows, displayFrames: [display])

        #expect(result.map(\.id) == [1, 2])
    }

    @Test func selectableAcceptsNormalFloatingAndMenubarWindows() {
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let windows = [
            window(id: 1),
            // 贴图 / pin 工具用的浮动面板（.floating = 3）。
            window(id: 2, layer: 3),
            window(id: 3, layer: 8),
            // 菜单栏：整条横带，没有应用名也要保留（用户要求可截）。
            window(
                id: 4,
                frame: CGRect(x: 0, y: 0, width: 1920, height: 30),
                ownerName: "",
                title: nil,
                layer: 24
            ),
        ]

        let result = WindowFilter.selectable(windows: windows, displayFrames: [display])

        #expect(result.map(\.id) == [1, 2, 3, 4])
    }

    @Test func selectableAcceptsDesktopAndSkipsNamelessSystemLayers() {
        // 桌面 / 壁纸在窗口服务器的负层级，用户明确要求可高亮、可截。
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let windows = [
            window(id: 1, frame: display, ownerName: "访达", title: nil, layer: -2147483603),
            window(id: 2, frame: display, ownerName: "WindowManager", title: "Wallpaper", layer: -2147483624),
            // 窗口服务器的辅助层：只会在紧邻菜单栏的位置截到一条无意义色带。
            window(id: 3, frame: display, ownerName: "", title: "Backstop", layer: -2147483626),
            window(
                id: 4,
                frame: CGRect(x: 0, y: 0, width: 1920, height: 122),
                ownerName: "",
                title: "underbelly",
                layer: -2147483602
            ),
        ]

        let result = WindowFilter.selectable(windows: windows, displayFrames: [display])

        #expect(result.map(\.id) == [1, 2])
    }

    @Test func selectableRejectsDockStatusItemsAndOverlayLayers() {
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let windows = [
            window(id: 1),
            // Dock 上报整屏 frame，入选会把所有点都抢走。
            window(id: 2, frame: display, ownerName: "程序坞", title: "Dock", layer: 20),
            // 状态栏项 / 系统 HUD。
            window(id: 3, layer: 25),
            // 屏保层：IceShot 自己的截取浮层就在这一层。
            window(id: 4, frame: display, layer: 1000),
        ]

        let result = WindowFilter.selectable(windows: windows, displayFrames: [display])

        #expect(result.map(\.id) == [1])
    }

    @Test func systemSurfacesAreFlaggedAndNamed() {
        let desktop = window(id: 1, ownerName: "访达", title: nil, layer: -2147483603)
        #expect(desktop.isSystemSurface)
        #expect(desktop.isDesktopSurface)
        // 断言「显示名就是那条已本地化的文案」，而不是钉死某种语言的字符串：
        // 测试进程跑在中文还是英文取决于系统与 App 的语言设置，钉死会让门禁随环境变色。
        #expect(desktop.displayName == String(localized: "桌面"))

        let menubar = window(id: 2, ownerName: "", title: nil, layer: 24)
        #expect(menubar.isSystemSurface)
        #expect(menubar.isMenuBarSurface)
        #expect(menubar.displayName == String(localized: "菜单栏"))

        let normal = window(id: 3)
        #expect(!normal.isSystemSurface)
        #expect(normal.displayName == "App — Window")
    }

    @Test func selectableRejectsTinyOffscreenAndHiddenWindows() {
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let windows = [
            window(id: 1),
            window(id: 2, frame: CGRect(x: 100, y: 100, width: 10, height: 10)),
            window(id: 3, isOnScreen: false),
            window(id: 4, frame: CGRect(x: 3000, y: 3000, width: 600, height: 400)),
        ]

        let result = WindowFilter.selectable(windows: windows, displayFrames: [display])

        #expect(result.map(\.id) == [1])
    }

    @Test func selectableKeepsOwnAppPinnedWindows() {
        // 贴图属于自身 PID，但它是合法目标：截取浮层 / HUD 靠层级带排除，不靠 PID。
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let windows = [
            window(id: 1, ownerPID: 7, ownerName: "IceShot", layer: 3),
            // 截取浮层在 .screenSaver（1000），永不可选。
            window(id: 2, frame: display, ownerPID: 7, ownerName: "IceShot", layer: 1000),
        ]

        let result = WindowFilter.selectable(windows: windows, displayFrames: [display])

        #expect(result.map(\.id) == [1])
    }

    @Test func hitTestReturnsFrontmostWindow() {
        let windows = [
            window(id: 10, frame: CGRect(x: 100, y: 100, width: 500, height: 400)),
            window(id: 11, frame: CGRect(x: 200, y: 150, width: 500, height: 400)),
        ]

        let hit = WindowFilter.hitTest(at: CGPoint(x: 250, y: 200), in: windows)
        #expect(hit?.id == 10)
    }

    @Test func orderingUsesFrontToBackIDsAndKeepsUnknownWindows() {
        let windows = [
            window(id: 20),
            window(id: 21),
            window(id: 22),
        ]

        let ordered = WindowOrdering.sorted(windows, frontToBackIDs: [22, 20])

        #expect(ordered.map(\.id) == [22, 20, 21])
    }

    @Test func orderingAcceptsDuplicateIDsWithoutCrashing() {
        let windows = [window(id: 30), window(id: 31)]
        let ordered = WindowOrdering.sorted(windows, frontToBackIDs: [31, 31, 30])
        #expect(ordered.map(\.id) == [31, 30])
    }

    @Test func displayNameFallsBackToOwnerWhenTitleIsEmpty() {
        let emptyTitle = WindowDescriptor(
            id: 40,
            frame: .zero,
            ownerPID: 1,
            ownerName: "Finder",
            title: "   ",
            layer: 0,
            isOnScreen: true,
            isActive: false
        )
        #expect(emptyTitle.displayName == "Finder")
    }

    @Test func hoverStateIgnoresClearFromOtherDisplay() {
        let state = WindowHoverState()
        state.update(windowID: 1, displayID: 10)

        state.clear(displayID: 11)
        #expect(state.windowID == 1)

        state.clear(displayID: 10)
        #expect(state.windowID == nil)
    }
}
