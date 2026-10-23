import Foundation
import Testing
@testable import IceShot

/// 颜色十六进制往返 + 标注色板的读写与回退规则。
nonisolated struct ColorPaletteTests {
    // MARK: - 十六进制

    @Test("六位 / 八位十六进制都能往返")
    func hexRoundTrip() throws {
        let red = try #require(EditorColor(hex: "#FF382E"))
        #expect(red.hexString == "#FF382E")
        #expect(abs(red.red - 1) < 0.001)
        #expect(abs(red.green - 0x38 / 255.0) < 0.001)
        #expect(abs(red.blue - 0x2E / 255.0) < 0.001)
        #expect(red.alpha == 1)

        let translucent = try #require(EditorColor(hex: "#FF000080"))
        #expect(translucent.hexString == "#FF000080")
        #expect(abs(translucent.alpha - 0x80 / 255.0) < 0.001)
        #expect(EditorColor(hex: translucent.hexString) == translucent)
    }

    @Test("省略 #、大小写都能解析")
    func hexAcceptsLooseInput() throws {
        let color = try #require(EditorColor(hex: "ff9400"))
        #expect(color == EditorColor(hex: "#FF9400"))
    }

    @Test("非法输入返回 nil，不静默变成黑色")
    func invalidHexReturnsNil() {
        #expect(EditorColor(hex: "") == nil)
        #expect(EditorColor(hex: "#12345") == nil)
        #expect(EditorColor(hex: "#1234567") == nil)
        #expect(EditorColor(hex: "#GGGGGG") == nil)
        #expect(EditorColor(hex: "#FF94 00") == nil)
    }

    // MARK: - 内置色板

    @Test("内置色板 8 色、互不重复、首个是默认红")
    func builtInPaletteIsComplete() {
        let palette = EditorColor.builtInPalette
        #expect(palette.count == 8)
        #expect(Set(palette).count == 8)
        #expect(palette.first == EditorColor(hex: "#FF382E"))
        // 每个色都能原样往返，说明内置值都是 8 bit 可达的。
        #expect(palette.allSatisfy { EditorColor(hex: $0.hexString) == $0 })
    }

    // MARK: - 读写与回退

    @Test("没存过时用内置色板，默认色是色板第一格")
    func fallsBackToBuiltInPalette() {
        withIsolatedDefaults { defaults in
            #expect(ColorPalettePreferences.palette(in: defaults) == EditorColor.builtInPalette)
            #expect(ColorPalettePreferences.defaultColor(in: defaults) == EditorColor.builtInPalette.first)
        }
    }

    @Test("保存后读回同一组颜色")
    func saveThenRead() throws {
        try withIsolatedDefaults { defaults in
            let custom = [
                try #require(EditorColor(hex: "#123456")),
                try #require(EditorColor(hex: "#ABCDEF")),
                try #require(EditorColor(hex: "#000000")),
            ]
            #expect(ColorPalettePreferences.save(custom, to: defaults))
            #expect(ColorPalettePreferences.palette(in: defaults) == custom)
        }
    }

    @Test("少于 2 色的保存被拒绝，原值不动")
    func rejectsTooFewColors() throws {
        try withIsolatedDefaults { defaults in
            let custom = [
                try #require(EditorColor(hex: "#123456")),
                try #require(EditorColor(hex: "#ABCDEF")),
            ]
            #expect(ColorPalettePreferences.save(custom, to: defaults))

            let single = [try #require(EditorColor(hex: "#FFFFFF"))]
            #expect(ColorPalettePreferences.save(single, to: defaults) == false)
            #expect(ColorPalettePreferences.palette(in: defaults) == custom)
        }
    }

    @Test("重复颜色去重，超过上限截断")
    func normalisesDuplicatesAndCount() throws {
        try withIsolatedDefaults { defaults in
            let first = try #require(EditorColor(hex: "#111111"))
            let second = try #require(EditorColor(hex: "#222222"))
            #expect(ColorPalettePreferences.save([first, first, second], to: defaults))
            #expect(ColorPalettePreferences.palette(in: defaults) == [first, second])

            let many = (1...10).compactMap { EditorColor(hex: String(format: "#%06X", $0)) }
            #expect(ColorPalettePreferences.save(many, to: defaults))
            #expect(
                ColorPalettePreferences.palette(in: defaults).count
                    == ColorPalettePreferences.maximumCount
            )
        }
    }

    @Test("存进去的数据坏掉时回退内置色板")
    func corruptStoredPaletteFallsBack() {
        withIsolatedDefaults { defaults in
            defaults.set(["#NOPE", "#123456"], forKey: ColorPalettePreferences.paletteKey)
            #expect(ColorPalettePreferences.palette(in: defaults) == EditorColor.builtInPalette)
        }
    }

    @Test("恢复默认会清掉自定义色板")
    func resetRestoresBuiltIn() throws {
        try withIsolatedDefaults { defaults in
            let custom = [
                try #require(EditorColor(hex: "#123456")),
                try #require(EditorColor(hex: "#ABCDEF")),
            ]
            #expect(ColorPalettePreferences.save(custom, to: defaults))
            ColorPalettePreferences.reset(in: defaults)
            #expect(ColorPalettePreferences.palette(in: defaults) == EditorColor.builtInPalette)
        }
    }

    @Test("当前颜色不在色板里时补一格，保证有选中态")
    func displayPaletteAppendsMissingCurrentColor() throws {
        try withIsolatedDefaults { defaults in
            let other = try #require(EditorColor(hex: "#123456"))
            #expect(ColorPalettePreferences.displayPalette(current: other, in: defaults).last == other)
            #expect(
                ColorPalettePreferences.displayPalette(current: other, in: defaults).count
                    == EditorColor.builtInPalette.count + 1
            )

            // 已在色板里的颜色不重复追加。
            let inPalette = try #require(EditorColor.builtInPalette.first)
            #expect(
                ColorPalettePreferences.displayPalette(current: inPalette, in: defaults)
                    == EditorColor.builtInPalette
            )
        }
    }

    // MARK: - 设置页的增删改

    @Test("换色：原位替换，不改变格数与顺序")
    func replacingKeepsOrderAndCount() throws {
        let first = try #require(EditorColor(hex: "#111111"))
        let second = try #require(EditorColor(hex: "#222222"))
        let third = try #require(EditorColor(hex: "#333333"))
        let updated = try #require(
            ColorPalettePreferences.replacing([first, second], at: 1, with: third)
        )
        #expect(updated == [first, third])
    }

    @Test("换色：换成色板里已有的颜色会被拒（否则会不足 2 色 / 产生重复）")
    func replacingRejectsDuplicateBelowMinimum() throws {
        let first = try #require(EditorColor(hex: "#111111"))
        let second = try #require(EditorColor(hex: "#222222"))
        #expect(ColorPalettePreferences.replacing([first, second], at: 1, with: first) == nil)
        // 三色时换成已有色只去重，不拒绝。
        let third = try #require(EditorColor(hex: "#333333"))
        #expect(
            ColorPalettePreferences.replacing([first, second, third], at: 2, with: first)
                == [first, second]
        )
    }

    @Test("换色：下标越界返回 nil")
    func replacingRejectsInvalidIndex() throws {
        let first = try #require(EditorColor(hex: "#111111"))
        let second = try #require(EditorColor(hex: "#222222"))
        let third = try #require(EditorColor(hex: "#333333"))
        #expect(ColorPalettePreferences.replacing([first, second], at: 2, with: third) == nil)
        #expect(ColorPalettePreferences.replacing([first, second], at: -1, with: third) == nil)
    }

    @Test("添加：满 8 色或颜色重复时被拒")
    func appendingRespectsLimitAndUniqueness() throws {
        let two = [
            try #require(EditorColor(hex: "#111111")),
            try #require(EditorColor(hex: "#222222")),
        ]
        let third = try #require(EditorColor(hex: "#333333"))
        let added = try #require(ColorPalettePreferences.appending(third, to: two))
        #expect(added.count == 3)
        #expect(added.last == third)

        #expect(ColorPalettePreferences.appending(two[0], to: two) == nil)

        let full = EditorColor.builtInPalette
        let extra = try #require(EditorColor(hex: "#123456"))
        #expect(full.count == ColorPalettePreferences.maximumCount)
        #expect(ColorPalettePreferences.appending(extra, to: full) == nil)
    }

    @Test("删除：到最小色数或下标越界时被拒")
    func removingRespectsMinimum() throws {
        let two = [
            try #require(EditorColor(hex: "#111111")),
            try #require(EditorColor(hex: "#222222")),
        ]
        let third = try #require(EditorColor(hex: "#333333"))
        let three = try #require(ColorPalettePreferences.appending(third, to: two))
        #expect(ColorPalettePreferences.removing(three, at: 1) == [two[0], three[2]])
        #expect(ColorPalettePreferences.removing(two, at: 0) == nil)
        #expect(ColorPalettePreferences.removing(three, at: 9) == nil)
    }

    @Test("设置页编辑后能存盘读回")
    func editedPalettePersists() throws {
        try withIsolatedDefaults { defaults in
            let colors = ColorPalettePreferences.palette(in: defaults)
            let replacement = try #require(EditorColor(hex: "#123456"))
            let updated = try #require(
                ColorPalettePreferences.replacing(colors, at: 0, with: replacement)
            )
            #expect(ColorPalettePreferences.save(updated, to: defaults))
            #expect(ColorPalettePreferences.palette(in: defaults).first == replacement)
            #expect(ColorPalettePreferences.defaultColor(in: defaults) == replacement)
        }
    }

    // MARK: - 辅助

    /// 独立 `UserDefaults` suite：不污染全局设置，测试之间也不会互相影响。
    private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suiteName = "IceShotTests.ColorPalette.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }
}
