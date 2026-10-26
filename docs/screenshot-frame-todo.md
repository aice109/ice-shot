# 截图带壳：进度与未完成事项

本文交接「截图带壳」当前做到哪里、还差什么。设计、视觉规格与验收标准见
[screenshot-frame.md](screenshot-frame.md)。

更新时间：2026-10-26。

---

## 一、当前结论

**M1、M2 已完成；M3–M4 未开始。**

现在已经可以：

- 在截图浮层和编辑器操作条里点「带壳」按钮；
- 在 popover 里开关带壳，并看到窗口壳预览；
- 预览使用与最终导出相同的 CoreGraphics 渲染器，先按选区裁剪再套壳；
- **复制 / 保存 / 贴图输出带壳图**；关掉带壳后与原图逐像素一致；
- 「全部显示器」批量保存时，各屏套同一个壳；
- 历史库始终只存原图。

现在**还不能**：

- 选择仅阴影、外观、背景、边距、标题、阴影开关（M3）；
- 记住上次样式（M4）；
- 窗口来源的截图自动默认「仅阴影」（M3）。

---

## 二、已经落地的代码

| 位置 | 内容 |
| --- | --- |
| `IceShot/Core/Imaging/ScreenshotFrameStyle.swift` | 样式值类型：窗口 / 仅阴影、外观、背景、边距、阴影、标题 |
| `IceShot/Core/Imaging/ScreenshotFramePalette.swift` | 固定内容色、交通灯颜色、背景渐变 |
| `IceShot/Core/Imaging/ScreenshotFrameComposer.swift` | 纯 CoreGraphics / CoreText 渲染器，支持预览降采样 |
| `IceShot/Core/Capture/OverlayPixelGeometry.swift` | 浮层选区 → 模型图像素的唯一换算，导出与预览共用 |
| `IceShot/Features/Editor/ScreenshotFramePopover.swift` | 开关 + 预览 popover |
| `IceShot/Features/Editor/MarkupToolbar.swift` | 输出胶囊里的「带壳」按钮与 popover 状态 |
| `IceShot/Features/Editor/MarkupToolbarLayout.swift` | 输出项 `.frame`，排在复制 / 保存之前 |
| `IceShot/Features/Editor/EditorModel.swift` | `frameStyle` 状态与开关方法，不进入 `image` / 撤销栈 |
| `IceShot/Features/Editor/EditorRootView.swift` | 编辑器预览内容：`model.renderedImage()` |
| `IceShotTests/ScreenshotFrameExportTests.swift` | M2 输出接入的行为锁定（无壳逐像素一致、先裁后壳、批量不重复套壳、历史隔离） |
| `IceShot/Features/Capture/Overlay/SelectionOverlayView.swift` | 浮层预览内容：渲染标注 → 按选区裁剪 |
| `IceShot/Features/Capture/Overlay/SelectionOverlayController.swift` | 像素裁剪改用 `OverlayPixelGeometry` |
| `IceShotTests/ScreenshotFrameComposerTests.swift` | 渲染器尺寸、透明底、渐变底、明暗、交通灯、投影、方向、预览缩放 |
| `IceShotTests/MarkupToolbarLayoutTests.swift` | 输出项顺序锁定 |
| `IceShot/en.lproj/Localizable.strings` | M1 新增中文文案的英文条目 |

当前「带壳」已经作用于最终输出，但仍**不烘进 `image`**。
这个边界不能破坏：历史库必须继续保存原图。

---

## 三、已完成切片

### M2 · 输出接入 ✅

目标（已达成）：开启带壳后，复制 / 保存 / 贴图得到带壳图；关闭后与原图逐像素一致。

落地方式：

1. **统一合成入口** `ScreenshotFrameComposer.compose(_:cropRect:style:maximumDimension:)`
   —— 内容 → 成品的唯一出口，固定「先裁剪，后套壳」。
   `style` 为 `nil` 时**直接返回裁剪结果**，不多经过一次重绘。
2. **浮层**：`SelectionOverlayController.outputImage` 保持
   「渲染标注 → 按选区裁剪 → 套壳」，套壳读 `state.editor?.frameStyle`。
3. **编辑器**：新增 `EditorModel.exportImage(content:)`，
   `EditorWindowController` 的 `copyAction` / `saveAction` / `pinAction` 改用
   它；`renderedImage()` 保持不变（画布、OCR、取字还用它）。
4. **批量保存**：`SelectionFinish` 带上 `frameStyle`，
   `CaptureCoordinator.framedBatch` 给其余屏补同一层壳，并**跳过当前屏**
   （它已在浮层里套过，否则会壳外套壳，尺寸凭空再长一圈）。
   复制 / 贴图仍然只处理当前屏。
5. **历史**：`historyImages` 一行未动，仍然只收原图。
6. **文案**：popover 提示改成实际行为「复制 / 保存 / 贴图会带上这层壳；历史记录仍存原图」。
7. **测试**：`IceShotTests/ScreenshotFrameExportTests.swift` 锁住无壳逐像素一致、
   先裁后壳的尺寸、批量不重复套壳、带壳不动模型图像与撤销栈。

顺手修掉的存量问题：`ScreenshotFrameComposer` 用的是 `nonisolated`，
但它依赖的 `ScreenshotFrameStyle` / `ScreenshotFramePalette` / `ImageCropper` /
`CaptureError` 都受 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` 默认隔离，
于是构建里有 6 条存量警告。按仓库已有惯例（`ImageEncoder`、`BarcodeDetector` 等）
给这四个类型标上 `nonisolated`，警告清零。

手工验收：截图 → 开启带壳 → 复制 / 保存 / 贴图，得到带壳图；关闭后得到原图；
历史记录里的图始终是原图；全部显示器模式下保存的多张图都带同一个壳。

---

## 四、未完成工作

### M3 · 样式选项（下一步）

`ScreenshotFrameStyle` 和渲染器已经支持，但 popover 还没有对应控件。

需要补：

- 样式：窗口 / 仅阴影。
- 外观：自动 / 浅色 / 深色。
- 背景：透明 / 石墨 / 海蓝 / 晨曦 / 极光。
- 边距：小 / 中 / 大。
- 标题输入框，默认空。
- 阴影开关。
- 参数变化后立即重绘预览，并同步到 `EditorModel.setFrameStyle`。
- 窗口来源的截图首次开启时默认「仅阴影」，避免双层交通灯。
  目前 `SelectionOverlayController` 不持有截图来源，需要把来源或默认样式传进编辑器。
- 新增文案补 English，`LocalizationTests` 会卡住漏翻。

验收：逐项切换，popover 预览与最终复制 / 保存结果一致；窗口截图不会出现双层交通灯。

### M4 · 完整收尾

- `ScreenshotFramePreferences`：用 `UserDefaults` 记住**上次使用的样式**。
  每次截图仍然默认关闭；开启时沿用上次样式。`ScreenshotFrameStyle` 需要可持久化
  （例如补 `Codable`，或在偏好层做原始值映射）。
- 全部显示器批量保存统一套壳。**（M2 已完成）**
- 中英文案补齐。
- 更新 `docs/roadmap.md` 的 P2「拼图 / 带壳 / 背景美化」状态与说明。
- 如需要，更新 `docs/architecture.md` 的带壳数据流。
- 最终跑 `Scripts/gate.sh`，零警告后再提交。
- 可选优化：`⌘B` 快速开关，暂不阻塞主线。

---

## 四、已知边界与风险

- 主画布仍然显示原图，带壳只在 popover 预览和最终输出。把壳画进画布会与选区、
  边框、手柄的坐标绑定冲突，暂不做。
- 自动外观只采样截图顶部一条的亮度，不读系统外观；这是为了保证导出稳定。
- 带壳渲染使用固定内容色，不跟随 App 主题，这是有意的例外，和标注色板同理。
- 标题不会自动填窗口标题，避免把窗口标题里的隐私信息带进导出图。
- 透明背景 + 阴影需要留白，边距不能为 0；当前三档边距都预留了投影空间。
- 预览固定降采样，导出使用全分辨率；两者共用渲染器，避免行为漂移。
- 目前没有把带壳状态接入撤销栈，也不应该接入：它是输出设置，不是标注。

---

## 五、调试提醒

点复制 / 保存 / 贴图后如果整个 App「卡死」，先检查 Xcode 断点导航器（`⌘8`），
确认没有停在 `CaptureCoordinator.handleFinish` 的断点。本次曾发现一个启用的本地断点
停在该函数里，表现为复制时卡住；断点属于本地 Xcode 用户数据，不在仓库里。

如果想抓真实的收尾耗时：

```bash
ICESHOT_HANG_TRACE=1 Scripts/gate.sh
```

然后运行 Debug 产物复现，诊断文件会通过菜单栏的诊断入口导出。

---

## 六、下一步

M2 已完成并通过门禁。下一步是 M3（样式选项），顺序建议：

1. popover 补控件：样式 / 外观 / 背景 / 边距 / 标题 / 阴影，全部同步到 `EditorModel.setFrameStyle`。
2. 窗口来源的截图首次开启默认「仅阴影」：需把截图来源（`ScreenshotSource`）或默认样式
   从 `CaptureCoordinator` 传进 `EditorModel`。
3. 新增文案补 `en.lproj/Localizable.strings`，`LocalizationTests` 会卡住漏翻。
4. 跑 `Scripts/gate.sh`，手工验收后提交，再进入 M4。

不变的底线：本地处理、只在用户主动触发时截取、不静默上传；不新增权限、不联网、
不改 SwiftData 模型 / schema。
