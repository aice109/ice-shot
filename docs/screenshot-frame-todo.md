# 截图带壳：进度与未完成事项

本文交接「截图带壳」当前做到哪里、还差什么。设计、视觉规格与验收标准见
[screenshot-frame.md](screenshot-frame.md)。

更新时间：2026-10-26。

---

## 一、当前结论

**M1–M4 全部完成。**

现在已经可以：

- 在截图浮层和编辑器操作条里点「带壳」按钮；
- 在 popover 里开关带壳，并看到窗口壳预览；
- 预览使用与最终导出相同的 CoreGraphics 渲染器，先按选区裁剪再套壳；
- **复制 / 保存 / 贴图输出带壳图**；关掉带壳后与原图逐像素一致；
- 「全部显示器」批量保存时，各屏套同一个壳；
- **选择样式（窗口 / 仅阴影）、外观、背景、边距、标题、阴影开关**，改完立即重绘预览；
- **窗口来源的截图首次开启自动用「仅阴影」**，避免双层交通灯；
- **跨次记住上次用过的样式**；每次截图仍然默认关闭带壳；
- 编辑器窗口 `⌘B` 快速开关；
- 历史库始终只存原图。

没有剩余未完成项；进一步扩展（拼图 / 背景美化）属于另一个功能。

---

## 二、已经落地的代码

| 位置 | 内容 |
| --- | --- |
| `IceShot/Core/Imaging/ScreenshotFrameStyle.swift` | 样式值类型：窗口 / 仅阴影、外观、背景、边距、阴影、标题 |
| `IceShot/Core/Imaging/ScreenshotFramePalette.swift` | 固定内容色、交通灯颜色、背景渐变 |
| `IceShot/Core/Imaging/ScreenshotFrameComposer.swift` | 纯 CoreGraphics / CoreText 渲染器，支持预览降采样 |
| `IceShot/Core/Capture/OverlayPixelGeometry.swift` | 浮层选区 → 模型图像素的唯一换算，导出与预览共用 |
| `IceShot/Features/Editor/ScreenshotFramePopover.swift` | 开关 + 全部样式控件 + 预览 popover |
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

### M3 · 样式选项 ✅

popover 现在是完整的样式面板：

- 样式：窗口 / 仅阴影。
- 外观：自动 / 浅色 / 深色。
- 背景：透明 / 石墨 / 海蓝 / 晨曦 / 极光。
- 边距：小 / 中 / 大。
- 标题输入框，默认空（不自动填窗口标题）。
- 阴影开关。
- 每项改动写回 `EditorModel.setFrameStyle`，`task(id: model.frameStyle)` 立即重绘预览。
- 窗口来源的截图默认「仅阴影」：`ScreenshotSource` 随 `SelectionOverlayController.present`
  进 `Session`，再由 `EditorModel.applyDefaultFrameStyle(for:)` 落到默认样式；
  用户手动改过就不会再被覆盖。切回「窗口」时 popover 会说明会出现双层交通灯。
- 新增文案已补 English，`LocalizationTests` 通过。

popover 宽度按**英文**文案定到 420 pt：
五档背景英文全展约 321 pt，而 360 宽只剩 328 pt 可用，余量不足 7 pt，字重一变就截断。

验收：逐项切换，popover 预览与最终复制 / 保存结果一致；窗口截图不会出现双层交通灯。

### M4 · 完整收尾 ✅

- `ScreenshotFramePreferences`：`UserDefaults` 记住上次用过的样式。
  **没有**给 `ScreenshotFrameStyle` 加 `Codable`：那会把导出渲染的输入与磁盘格式绑死，
  以后删一档背景就得写迁移。改为逐字段存原始值字符串，坏一项只退一项。
- 两条规则分开：**记住样式**，但**每次截图仍默认关闭带壳**。
- 窗口来源的例外叠加在「记住的样式」之上：只把壳形态改成仅阴影，
  用户调过的背景 / 边距 / 标题留着。
- 全部显示器批量套壳（M2 已完成）。
- 中英文案补齐，`LocalizationTests` 通过。
- 更新路线图与设计文档。
- `⌘B` 快速开关（编辑器窗口；工具栏 tooltip 已标明）。

顺带修掉一个自己引入的语义坑：`defaultFrameStyle` 原本只在 `init` 时读一次，
导致「关掉再开启」会丢掉刚调好的样式。现在 `setFrameStyle` 同步它，
同一会话内开关也能保持。

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

带壳四个切片已全部完成。后续可选方向（都不在本系列范围内）：

- 拼图 / 背景美化（路线图 P2 的另一半）。
- 如果在编辑器画布上做实时带壳预览，需先解冑与选区、边框、手柄的坐标绑定。
- 支持把带壳结果写成一张新历史记录（目前有意不做，历史只存原图）。

不变的底线：本地处理、只在用户主动触发时截取、不静默上传；不新增权限、不联网、
不改 SwiftData 模型 / schema。
