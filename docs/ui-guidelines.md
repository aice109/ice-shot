# 界面规范

界面、材质、颜色、动效的规则。做任何 UI 之前先读这一份。

底座：系统原生控件 + **Liquid Glass（液态玻璃）**，遵循
[Apple HIG（macOS）](https://developer.apple.com/design/human-interface-guidelines/macos)。

---

## 第一原则：材质交给系统

**不手绘模糊，不叠加自调透明度，不伪造玻璃。**

所有材质背景都走 `Core/DesignSystem/GlassSurface.swift`：

- macOS 26 起使用 Liquid Glass。
- 更低版本回退到系统材质（`.regularMaterial`）。
- 效果强度由**用户在系统设置里**决定，应用不做可读性补偿。

```swift
// 正确
.glassSurface(.clear, in: Capsule())

// 错误：手绘模糊 / 自调透明度 / 叠加材质
.background(.ultraThinMaterial).opacity(0.7)
```

---

## 玻璃档位：`GlassSurfaceKind`

| 档位 | 系统行为 | 用在哪 |
| --- | --- | --- |
| `.clear` | 最透，几乎不托底 | **浮层默认**：操作条、HUD、尺寸标签、放大镜、选区提示 |
| `.regular` | 系统按上下文调透明度 | 受控背景：窗口底、列表、表单 |
| `.interactive` | `.regular` + 指针响应 | 需要悬停/按下的悬浮控件 |

**浮层一律用 `.clear`。** 液态玻璃的"液态感"来自底层内容透上来，
用 `.regular` 会把浮层压成一块磨砂板，看起来和系统材质没区别。

---

## 染色：`GlassContrast`

**默认 `.none`——不染色，不托底，应用不管可读性。**

最透档位下字形变淡是用户主动选择的结果。用什么强度由系统设置决定，
应用不替他做决定，也不用语义染色伪造底衬。

| 档位 | 含义 |
| --- | --- |
| `.none` | 不染色（**默认**）。完全交给系统强度设置。 |
| `.standard` | 与 `.none` 等价，仅为既有调用点语义可读而保留。 |
| `.boosted` | 逃生口：`.windowBackgroundColor` 的 0.25 染色托底。**默认不用。** |

`.boosted` 只在真机实测确认某个浮层透到完全不可读时才启用，且要写清原因。
它不是常规选项。

---

## 形状变形：`glassMorphID`

26 起的液态玻璃能**从旧形状流成新形状**，这是它最有辨识度的动效。

```swift
GlassGroup(spacing: 12) {
    cluster { toolBar }
        .glassMorphID("tools", in: namespace)
    cluster { actionBar }
        .glassMorphID("actions", in: namespace)
}
```

规则：

- 同一个 `@Namespace` 下，id 相同的玻璃在增删时互相流动。
- `GlassGroup(spacing:)` 的 spacing **大于**组间留白时，靠近的玻璃会真实吸附成一体。
- 低于 26 时 `glassMorphID` 是无操作透传——调用点不必写版本分支。

**什么时候值得用**：形态切换是同一块玻璃在变（工具条 ↔ 裁剪条）；
**什么时候不该用**：两个无关浮层各自出现（别为了动画硬凑成一次变形）。

---

## 颜色

- **界面颜色禁止硬编码 RGB / Hex。**
- 一律用动态语义色：`Color(nsColor: .windowBackgroundColor)`、`.labelColor`、`.separatorColor` 等。
- 品牌强调色在 `Assets.xcassets/AccentColor.colorset`，用 `Color.accentColor` 引用。
- 用户可自定义的只有标注色板：内置 2–8 色，用户可在设置里换（`Core/Persistence/ColorPalettePreferences.swift`）。

### 唯一例外：标注色板

`Features/Editor/EditorAnnotation.swift` 里的标注颜色是**硬编码 RGB**，这是故意为之：

- 标注要烧进截图，颜色必须**固定**，不能随浅色/深色模式变。
- `defaultRed`、`readableDark`、`readableLight` 三个值属于标注内容自身，不是界面 chrome。
