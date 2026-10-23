import CoreGraphics
import Testing
@testable import IceShot

/// 框选浮层的指针判定：短位移 = 点击（截高亮窗口），超出阈值 = 拖拽（框选区域）。
struct PointerInteractionTests {
    @Test func subPixelDriftStillCountsAsClick() {
        #expect(PointerInteraction.kind(translation: .zero) == .click)
        #expect(PointerInteraction.kind(translation: CGSize(width: 2.9, height: -2)) == .click)
    }

    @Test func movementAtOrBeyondToleranceCountsAsDrag() {
        #expect(PointerInteraction.kind(translation: CGSize(width: 3, height: 0)) == .drag)
        #expect(PointerInteraction.kind(translation: CGSize(width: 0, height: -40)) == .drag)
        #expect(PointerInteraction.kind(translation: CGSize(width: -120, height: 8)) == .drag)
    }

    @Test func toleranceIsSmallEnoughForRealSelections() {
        // 阈值必须是正向的小常量：误设成 0 会把点击判成拖拽，误设成几十 pt 会吞掉小选区。
        #expect(PointerInteraction.clickTolerance > 0)
        #expect(PointerInteraction.clickTolerance <= 4)
    }

    @Test func smallSelectionIsNeverTreatedAsClick() {
        // 框一个很小的目标（通知横幅、图标）：起止位移小于阈值，但选区真的够大。
        // 若判成点击，会清掉选区并抓底层窗口，用户框到的东西就丢了。
        #expect(
            PointerInteraction.kind(
                translation: .zero,
                selectionSize: CGSize(width: 120, height: 40)
            ) == .drag
        )
        #expect(
            PointerInteraction.kind(
                translation: CGSize(width: 1, height: 2),
                selectionSize: CGSize(width: 1, height: 1)
            ) == .drag
        )
    }

    @Test func subPixelSelectionStillCountsAsClick() {
        // 实测缺陷：按下瞬间 DragGesture 就把选区刷成 0.5 × 0.5，
        // 它宽高非零却不能截；若当成选区，单击会停死——“点了没反应”。
        #expect(
            PointerInteraction.kind(
                translation: .zero,
                selectionSize: CGSize(width: 0.5, height: 0.5)
            ) == .click
        )
        #expect(
            PointerInteraction.kind(
                translation: .zero,
                selectionSize: .zero
            ) == .click
        )
    }

    @Test func emptyClickStillPicksWindow() {
        // 没拉出选区时，空单击仍保持「截高亮窗口」的便利。
        #expect(
            PointerInteraction.kind(translation: .zero, selectionSize: .zero) == .click
        )
        #expect(
            PointerInteraction.kind(
                translation: CGSize(width: 2, height: 2),
                selectionSize: CGSize(width: 0.5, height: 0.5)
            ) == .click
        )
    }

    @Test func largeDragIsDragWithOrWithoutSelection() {
        let drag = CGSize(width: 200, height: 120)
        #expect(
            PointerInteraction.kind(translation: drag, selectionSize: drag) == .drag
        )
        #expect(
            PointerInteraction.kind(translation: drag, selectionSize: .zero) == .drag
        )
    }

    @Test func usableSelectionMatchesCropThreshold() {
        // 判据必须与裁剪入口的门槛一致：小于 1 pt 的选区裁不出来。
        #expect(!PointerInteraction.isUsableSelection(CGSize(width: 0.9, height: 50)))
        #expect(!PointerInteraction.isUsableSelection(CGSize(width: 50, height: 0.9)))
        #expect(PointerInteraction.isUsableSelection(CGSize(width: 1, height: 1)))
        #expect(PointerInteraction.minimumSelectionSide == 1)
    }
}

/// 悬停命中：显示器局部点 → 全局点 → 目录里最前面的窗口；高亮矩形按屏幕裁剪。
@MainActor
struct WindowHoverPickerTests {
    private func display(
        id: CGDirectDisplayID,
        frame: CGRect,
        scale: CGFloat = 2
    ) -> DisplayDescriptor {
        DisplayDescriptor(id: id, frame: frame, appKitFrame: frame, scale: scale)
    }

    private func window(id: CGWindowID, frame: CGRect) -> WindowDescriptor {
        WindowDescriptor(
            id: id,
            frame: frame,
            ownerPID: 42,
            ownerName: "App",
            title: "Window",
            layer: 0,
            isOnScreen: true,
            isActive: true
        )
    }

    @Test func hitTestMapsLocalPointToGlobalCoordinates() {
        let secondary = display(id: 2, frame: CGRect(x: 1920, y: 0, width: 1512, height: 982))
        let windows = [window(id: 7, frame: CGRect(x: 2000, y: 100, width: 400, height: 300))]

        #expect(
            WindowHoverPicker.window(
                atLocalPoint: CGPoint(x: 80, y: 100),
                display: secondary,
                windows: windows
            )?.id == 7
        )
        // 差 1 pt 就在窗口外：确认用的是全局坐标而不是局部坐标。
        #expect(
            WindowHoverPicker.window(
                atLocalPoint: CGPoint(x: 79, y: 100),
                display: secondary,
                windows: windows
            ) == nil
        )
    }

    @Test func hitTestPrefersFrontmostWindow() {
        let primary = display(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let windows = [
            window(id: 10, frame: CGRect(x: 100, y: 100, width: 500, height: 400)),
            window(id: 11, frame: CGRect(x: 200, y: 150, width: 500, height: 400)),
        ]

        let hit = WindowHoverPicker.window(
            atLocalPoint: CGPoint(x: 250, y: 200),
            display: primary,
            windows: windows
        )
        #expect(hit?.id == 10)
    }

    @Test func emptyCatalogNeverHits() {
        let primary = display(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        #expect(
            WindowHoverPicker.window(
                atLocalPoint: CGPoint(x: 1, y: 1),
                display: primary,
                windows: []
            ) == nil
        )
    }

    @Test func highlightRectIsClippedToDisplay() {
        let primary = display(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let clipped = window(id: 3, frame: CGRect(x: 800, y: 700, width: 400, height: 300))

        #expect(
            WindowHoverPicker.highlightRect(for: clipped, display: primary)
                == CGRect(x: 800, y: 700, width: 200, height: 100)
        )
    }

    @Test func highlightRectIsNilForWindowOnAnotherDisplay() {
        let primary = display(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let elsewhere = window(id: 4, frame: CGRect(x: 2000, y: 100, width: 200, height: 200))

        #expect(WindowHoverPicker.highlightRect(for: elsewhere, display: primary) == nil)
    }
}

/// 悬停状态与选区互不干扰：高亮只在「还没框选」时有意义。
@MainActor
struct SelectionOverlayHoverTests {
    @Test func hoverTracksEachDisplayIndependently() {
        let state = SelectionOverlayState()
        state.updateHover(windowID: 5, displayID: 1)

        #expect(state.hoveredWindowID == 5)
        #expect(state.hoveredDisplayID == 1)

        state.clearHover(displayID: 2)
        #expect(state.hoveredWindowID == 5)

        state.clearHover(displayID: 1)
        #expect(state.hoveredWindowID == nil)
        #expect(state.hoveredDisplayID == nil)
    }

    @Test func hoverDoesNotTouchSelectionOrEditing() {
        let state = SelectionOverlayState()
        state.update(displayID: 1, rect: CGRect(x: 10, y: 20, width: 100, height: 50))
        state.updateHover(windowID: 5, displayID: 1)

        #expect(state.selection(for: 1) == CGRect(x: 10, y: 20, width: 100, height: 50))
        #expect(!state.isEditing)

        state.clear(displayID: 1)
        // 清选区不影响悬停：两者由视图按「有没有选区」决定谁可见。
        #expect(state.hoveredWindowID == 5)
    }
}
