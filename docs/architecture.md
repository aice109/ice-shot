# 架构说明

代码在哪、谁依赖谁、从哪里开始读。**不含易腐烂的状态快照**——项目当前能做什么见
[roadmap](roadmap.md)，版本变更见 [CHANGELOG](../CHANGELOG.md)。

---

## 三层结构

单一 Xcode target、单 module。三个 target 共用一个 module 名：`IceShot`、`IceShotTests`、
`IceShotUITests`。

```
IceShot/
├── IceShotApp.swift      @main，只声明 Scene
├── App/                  应用外壳 + 依赖装配
├── Core/                 无 UI 的业务与领域逻辑
└── Features/             SwiftUI 界面层
```

依赖方向**单向**：`Features` → `Core`。`Core` 不得反向依赖 `Features`。
`App` 可以依赖两者，因为它是装配层。

---

## IceShot/App —— 应用外壳与装配

| 文件 | 职责 |
| --- | --- |
| `IceShotApp.swift` | `@main`。只声明 `MenuBarExtra`、`Window("历史记录")`、`Settings` 三个 Scene。**Scene 只做组装，不创建业务对象**。 |
| `App/AppDelegate.swift` | **唯一组合根**。集中创建 `CaptureCoordinator`、`GlobalHotkeyManager`、`EditorCoordinator`、`PinBoard`、`FeedbackHUDController`、`UpdateChecker`、`ModelContainer`、`LibraryStore`，持有 `startupError`。 |
| `App/ActivationPolicyController.swift` | 运行时在 `.regular` ⇄ `.accessory` 之间切换，普通窗口存在时才显示 Dock 图标。 |
| `App/MenuBarView.swift` | 菜单栏面板 UI：权限状态、各截取入口、历史与设置。 |
| `App/HotkeyMenuShortcut.swift` | 把 `HotkeyBinding` 映射成 SwiftUI 的 `KeyEquivalent` / `EventModifiers`，供菜单快捷键使用。 |
| `App/SettingsWindowPresenter.swift` | 静态命名空间，负责把设置窗口强制前置；处理激活策略竞态。 |

**新增全局服务时，在 `AppDelegate` 里创建并注入**，不要在 View 或 Scene 里直接 `init`。

---

## IceShot/Core —— 领域层

无 UI。可单测，`IceShotTests` 绝大多数用例针对这一层。

| 目录 | 职责 |
| --- | --- |
| `AppInfo/` | 版本号、语义化版本比较、更新检查与下载、更新偏好与进度面板、更新日志文案整形。 |
| `Capture/` | 截取领域：`ScreenCaptureService`（真实现）与 `ScreenCapturing`（协议）、`DisplayGeometry`、`SelectionGeometry`、`MagnifierGeometry`、`WindowDescriptor`、`PointerSelection`、`ResizeHandle`、`LastRegion`、`ScrollCapture/`（长截图拼接）。 |
| `DesignSystem/` | 目前只有 `GlassSurface.swift`：系统材质的统一封装。见 [ui-guidelines](ui-guidelines.md)。 |
| `Hotkeys/` | 全局快捷键的模型与注册。 |
| `Imaging/` | 图像处理：标注裁剪 / 变换、空白帧检测、剪贴板、编码、缩放、保存面板、缩略图。 |
| `Interaction/` | 指针与交互的基础设施。 |
| `OCR/` | 系统 Vision 的文字识别流水线。全部本机执行。 |
| `Permissions/` | 屏幕录制权限的检测与引导。 |
| `Persistence/` | SwiftData 模型（`ScreenshotRecord`）、`LibraryStore`、`FileStore`、`LibraryPaths`、`LibraryRuntime`、搜索、偏好、错误类型。 |
| `Pinning/` | 贴图（置顶浮动窗口）的领域模型。 |
| `Utilities/` | 通用工具。 |

### 协议 + 实现在同目录

`ScreenCapturing`（协议）与 `ScreenCaptureService`（实现）并列，`HistorySaving` 同理。
测试用协议注入替身，不要在测试里驱动真实截屏。

---

## IceShot/Features —— 界面层

| 目录 | 职责 |
| --- | --- |
| `Capture/` | 选区浮层、窗口高亮、倒计时等截取时的界面。 |
| `Editor/` | 标注编辑器，本仓库最大的 Feature。`EditorCoordinator` 协调、`EditorModel` 状态机、`EditorRootView` 根视图、`MarkupCanvas` 绘制层、`MarkupToolbar` 操作条、`InlineTextEditor` 内联文本、`EditorKeyMapping` 快捷键映射。 |
| `Library/` | 历史库窗口。 |
| `Permissions/` | 权限引导界面。 |
| `Pinning/` | 贴图窗口的界面部分。 |
| `Settings/` | 设置面板。 |

---

## 测试组织

- `IceShotTests/` —— 全部 **Swift Testing**（`import Testing` + `@Test`），无 XCTest 单元测试。
  测试对象是 Core 层纯逻辑：几何计算、编码、版本比较、拼接、搜索、快捷键映射等。
- `IceShotUITests/` —— 单文件，极少量 XCTest 冒烟用例。

命名：测试文件名 = 被测类型 + `Tests`（如 `SelectionGeometryTests.swift`）。
一个测试文件对应一个被测单元，不为省文件而合并无关断言。

## 并发

工程 `SWIFT_VERSION = 5.0`，**未开启严格并发检查**（无 `SWIFT_STRICT_CONCURRENCY`）。
并发安全靠手工纪律，编译器不会替你兜底。

- **UI 一律 `@MainActor`**。绝大多数 `Features/` 与 `App/` 类型都标注了。
- **跨并发域传递的值类型标 `Sendable`**。如 `DisplayFrame`、`SelectionResult`、`WindowDescriptor`、`LastRegion`、`CaptureError`。
- **磁盘 IO 走 `actor`**。`Core/Persistence/FileStore.swift` 是标准范例：所有磁盘操作在 actor 内，只接受/返回相对文件名。
- **不让非 Sendable 类型跨 actor**。`UpdateProgressPanel` 的做法可参考：用盒子把数值 hop 回主 actor 再转交。

新增跨界传值时不标 `Sendable`，编译器不会报错，但运行时可能崩。这是本仓库最容易埋雷的地方。

---

## 阅读路径建议

1. `IceShotApp.swift` → 看有哪些入口。
2. `App/AppDelegate.swift` → 看全局对象怎么创建、怎么串起来。
3. 挑一个功能纵向读：`Features/<功能>` 的 Coordinator → `Core/<能力>` 的服务 → 对应测试。
4. `Scripts/gate.sh` → 看质量判据。
