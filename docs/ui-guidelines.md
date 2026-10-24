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
- 只有需要响应指针的悬浮控件才用 `.interactive`。

```swift
// 正确
.glassSurface(.elevated)

// 错误：手绘模糊 / 自调透明度 / 叠加材质
.background(.ultraThinMaterial).opacity(0.7)
```

---

## 对比度：`GlassContrast` 两档

系统液态玻璃调到最透时，玻璃不再提供底衬，直接压在截图内容上的字形会糊。

| 档位 | 用在哪 |
| --- | --- |
| `.standard` | 玻璃浮在受控背景上：系统窗口 chrome、已压暗的区域。不加染色。 |
| `.elevated` | 玻璃直接压在任意截图内容上：操作条、HUD、尺寸标签。加**语义染色**托底。 |

染色规则（来自 `GlassSurface.swift` 的实现注释）：

- 用**动态语义色**（`Color(nsColor:)` 一类的系统色），随深浅色、高对比度自动变。
- **不写死 RGB。**
- 只加薄薄一层（`.windowBackgroundColor` 的 0.25）——目的是"托底"，不是把玻璃做成磨砂板。
  再往上加就明显不像液态玻璃了，剩下的对比交给粗一点的字形与分组形状。

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

新增标注色时照这个模式加，**不要**顺手把它改成语义色。
界面其余部分不接受用户改色，也不接受硬编码色。

---

## 字体与字重

- **优先用语义字号**：`.caption`、`.callout`、`.headline`。现有代码以 `.caption` 为主（34 处）、`.callout`（10 处）、`.headline`（2 处）。
- 字重用 `.fontWeight(.medium)` 等语义值（现有 5 处均为 `.medium`），不写死数值。
- **固定点数只在三种场景允许**：

| 场景 | 例 | 理由 |
| --- | --- | --- |
| 叠加在截图内容上的标记 | `MarkupCanvas` 的文字、`EditorDrawing` 的序号 | 尺寸要跟标注几何走，不能随系统字号变 |
| 全屏 HUD 的巨大数字 | `CountdownHUDController` 的倒计时（46pt rounded） | 视觉元素而非文本 |
| 图标尺寸 | `MenuBarView` 的 22pt 符号 | 是图形不是排版 |

界面上的**正文、标签、按钮文字一律用语义字号**。

### 字号下限

**正文不小于 `.caption`。** 比 `.caption` 更小的字（如 `.caption2`）只允许用于非关键
辅助信息（单位后缀、快捷键提示），且必须在背景上有足够对比。

拿不准就用 `.caption`——它是本仓库的默认字号，现有代码绝大多数文字都是它。

---

## 图标

- 应用图标：`Assets.xcassets/AppIcon.appiconset`。
  开发期图标：`AppIconDev.appiconset`（与正式图标区分，避免混淆）。
- 菜单栏图标：`MenuBarIcon.imageset`，必须是**模板图**（template image），随菜单栏深浅自动反色。
- 品牌标记：`BrandMark.imageset`。
- 生成图标用 `Scripts/generate-app-icon.swift`，不要手工导出一堆尺寸。

---

## 窗口与激活策略

- 菜单栏常驻，**默认不占 Dock**。
- 普通窗口存在时才切到 `.regular` 显示 Dock 图标，窗口关闭后回到 `.accessory`。
  实现在 `App/ActivationPolicyController.swift`。
- 教育用户"用完即走"——不要做常驻大窗口。

---

## 操作条与参数

- 参数**点工具才弹出**，不常驻占操作条。
- 操作条就在选区下方，不遮挡选区内容。
- 布局逻辑在 `Features/Editor/MarkupToolbarLayout.swift`，有对应测试，改动前先看测试。

---

## 标注画布的光标与鼠标手势

光标是「这里现在能做什么」的唯一交代。规则集中在 `Features/Editor/MarkupCursorRule.swift`，
由 `MarkupCursorRuleTests` 逐格锁住。**改这张表就要同时改这两处。**

### 浮层选区阶段

| 位置 | 光标 | 按下后 |
| --- | --- | --- |
| 空白处 | 十字 | 拉新选区 |
| 悬停窗口（未框选） | 高亮该窗口 + 十字 | 单击截该窗口 |
| 选区 8 手柄 | 该方向的缩放箭头 | 缩放 |
| 选区内 + 按住 Space | 抓手 → 拖动中变抓紧 | 平移整块选区 |

### 标注画布

| 位置 | 光标 | 按下后 |
| --- | --- | --- |
| **悬停已有标注**（任何工具） | 抓手 | **拖动该标注** |
| 拖动标注中 | 抓紧 | — |
| 矩形 / 椭圆 / 直线 / 箭头 / 画笔 / 高亮 / 序号 / 马赛克 / 聚光灯 / 放大镜 · 图上空白 | 十字 | 拖拽绘制（画笔另带笔刷圆圈） |
| 文字 · 图上空白 | I-beam | 单击落点 |
| 文字 · 悬停已有文字 | I-beam | 进编辑（与双击同一去向） |
| 裁剪 · 手柄 / 框内 / 框外 | 缩放箭头 / 抓手 / 十字 | 缩放 / 平移裁剪框 / 拉新框 |
| 无工具态（`V`）· 图上空白 | 箭头 | 清空选中 |
| 图外（任何工具） | 箭头 | — |

### 两条容易搞错的前提

- **「悬停已有标注」优先级高于「当前工具」**：画着矩形时也能直接拖走旧标注，
  不需要先按 `V` 回无工具态。代价是**不能在已有标注上起笔画新东西**，得从旁边空白起手
  （标注都是细线条，命中容差约 7 pt，实际很少撞）。
- **唯一例外是文字工具下的文字标注**：那里点它是进编辑，所以光标是 I-beam 而不是抓手。

---

## 动效

- 用系统默认动画曲线与时长，不自定义弹簧参数。
- 尊重「减弱动态效果」辅助功能设置。
- 不做装饰性动画。动效只用于表达状态转换。

---

## 文案

- 界面文案**一律简体中文**，不用英文占位。
- 术语与 README 一致：用「截取」「标注」「贴图」「取字」「文字识别」「历史库」。
- 按钮文案说清动作结果（「复制」「另存为 PNG」），不用「确定」「取消」以外的模糊词。

---

## 隐私在界面上的体现

- 只在用户主动触发时截取，不做后台连续截屏。
- 权限引导要给出明确下一步（一键申请 / 跳转系统设置 / 重启提示），不要只说"需要权限"。
- 日志与错误提示**不得**包含截图内容、文件路径、窗口标题。
