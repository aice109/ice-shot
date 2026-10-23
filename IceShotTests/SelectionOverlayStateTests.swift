import CoreGraphics
import Testing
@testable import IceShot

/// 多屏选区状态：同一时间只有一块屏保留选区，进入编辑后锁定。
@MainActor
struct SelectionOverlayStateTests {
    @Test func onlyActiveDisplayKeepsSelection() {
        let state = SelectionOverlayState()
        state.update(displayID: 1, rect: CGRect(x: 10, y: 20, width: 100, height: 50))

        #expect(state.selection(for: 1) == CGRect(x: 10, y: 20, width: 100, height: 50))
        #expect(state.selection(for: 2) == .zero)

        state.update(displayID: 2, rect: CGRect(x: 1, y: 2, width: 3, height: 4))

        #expect(state.selection(for: 1) == .zero)
        #expect(state.selection(for: 2) == CGRect(x: 1, y: 2, width: 3, height: 4))
    }

    @Test func spaceStateCanBeSetAndCleared() {
        let state = SelectionOverlayState()
        #expect(!state.isSpacePressed)

        state.setSpacePressed(true)
        #expect(state.isSpacePressed)

        state.setSpacePressed(false)
        #expect(!state.isSpacePressed)
    }

    @Test func clearOnlyAffectsActiveDisplay() {
        let state = SelectionOverlayState()
        state.update(displayID: 1, rect: CGRect(x: 10, y: 20, width: 100, height: 50))

        state.clear(displayID: 2)
        #expect(state.selection(for: 1).width == 100)

        state.clear(displayID: 1)
        #expect(state.selection(for: 1) == .zero)
    }
}

@MainActor
struct SelectionOverlayEditingTests {
    private func image(width: Int = 4) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: width,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        return context.makeImage()
    }

    @Test func editingKeepsSelectionAndEndsOnClear() throws {
        let state = SelectionOverlayState()
        state.update(displayID: 1, rect: CGRect(x: 10, y: 20, width: 100, height: 50))

        let model = EditorModel(image: try #require(image()), title: "截图")
        state.beginEditing(
            editor: model,
            imageFrame: CGRect(x: 0, y: 0, width: 200, height: 120),
            allowsAdjustment: true
        )

        #expect(state.isEditing)
        #expect(state.editor === model)
        #expect(state.allowsAdjustment)
        #expect(state.selection(for: 1) == CGRect(x: 10, y: 20, width: 100, height: 50))

        state.endEditing()
        #expect(!state.isEditing)
        #expect(state.editor == nil)
        #expect(state.editorImageFrame == .zero)
    }
}
