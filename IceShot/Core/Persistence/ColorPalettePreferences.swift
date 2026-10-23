import Foundation

/// 标注色板：内置一组默认色，用户改过的色板存本机 `UserDefaults`。
///
/// 只存颜色本身（`#RRGGBB` 字符串），不联网、不同步；
/// 设置页后续只需要读写这里（本单元只做数据层 + 浮窗用上它）。
nonisolated enum ColorPalettePreferences {
    /// `UserDefaults` 中的色板 key。
    static let paletteKey = "annotationColorPalette"
    /// 色板最少几色（少于这个数视为数据损坏，回退内置色板）。
    static let minimumCount = 2
    /// 色板最多几色（浮窗一行放得下、也不至于变成取色器）。
    static let maximumCount = 8

    /// 没改过 / 数据不可用时用的内置色板。
    static var builtInPalette: [EditorColor] { EditorColor.builtInPalette }

    /// 当前色板。
    static var palette: [EditorColor] { palette(in: .standard) }

    /// 新标注默认用的颜色：色板第一格。
    static var defaultColor: EditorColor { defaultColor(in: .standard) }

    static func defaultColor(in defaults: UserDefaults) -> EditorColor {
        palette(in: defaults).first ?? .defaultRed
    }

    static func palette(in defaults: UserDefaults) -> [EditorColor] {
        guard let stored = defaults.stringArray(forKey: paletteKey) else {
            return builtInPalette
        }
        let colors = stored.compactMap(EditorColor.init(hex:))
        // 解析后太少说明数据坏了或被外部改坏，直接回退，不要留一块残缺色板。
        guard colors.count >= minimumCount else { return builtInPalette }
        return Array(normalized(colors).prefix(maximumCount))
    }

    /// 浮窗里要显示的色板：当前颜色不在色板里时（老数据 / 色板被改窄）补一格，
    /// 保证永远有选中态，不会出现「一格都没选中」。
    static func displayPalette(
        current: EditorColor,
        in defaults: UserDefaults = .standard
    ) -> [EditorColor] {
        let palette = palette(in: defaults)
        return palette.contains(current) ? palette : palette + [current]
    }

    /// 保存色板：去重、截断到上限。少于最小色数时视为无效调用，原值不动。
    @discardableResult
    static func save(_ colors: [EditorColor], to defaults: UserDefaults = .standard) -> Bool {
        let normalized = normalized(colors)
        guard normalized.count >= minimumCount else { return false }
        defaults.set(
            normalized.prefix(maximumCount).map(\.hexString),
            forKey: paletteKey
        )
        return true
    }

    /// 恢复内置色板。
    static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: paletteKey)
    }

    // MARK: - 设置页的三个原子操作

    /// 换掉某一格的颜色。下标非法、或换完后与其他格重复导致不足最小色数时返回 `nil`（拒绝）。
    static func replacing(
        _ colors: [EditorColor],
        at index: Int,
        with color: EditorColor
    ) -> [EditorColor]? {
        guard colors.indices.contains(index) else { return nil }
        var updated = colors
        updated[index] = color
        let deduped = normalized(updated)
        guard deduped.count >= minimumCount else { return nil }
        return deduped
    }

    /// 追加一格颜色。已满 / 已存在同一色时返回 `nil`。
    static func appending(
        _ color: EditorColor,
        to colors: [EditorColor]
    ) -> [EditorColor]? {
        guard !colors.contains(color), colors.count < maximumCount else { return nil }
        return colors + [color]
    }

    /// 删掉某一格。下标非法 / 已是最大可删数量（即到达最小色数）时返回 `nil`。
    static func removing(
        _ colors: [EditorColor],
        at index: Int
    ) -> [EditorColor]? {
        guard colors.indices.contains(index), colors.count > minimumCount else { return nil }
        var updated = colors
        updated.remove(at: index)
        return updated
    }

    /// 保持顺序去重。
    private static func normalized(_ colors: [EditorColor]) -> [EditorColor] {
        var seen: Set<EditorColor> = []
        return colors.filter { seen.insert($0).inserted }
    }
}
