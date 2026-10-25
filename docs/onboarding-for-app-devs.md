# 给前端 / Android 开发者的 IceShot 上手指南

你是写 Web 或 Android 的，现在要读或改这个原生 macOS 项目。这份文档做一件事：
**用你已有的模型去映射这套代码**，告诉你从哪个文件进去、每一步在干什么、哪些地方
Web / Android 的经验会骗你。

读完这份你应该能做到：跑起来、改一个标注工具的颜色、加一个菜单按钮、知道改哪儿会炸。

> 事实核查入口：架构细节以 [architecture.md](architecture.md) 为准，工程规则以
> [engineering.md](engineering.md) 为准，界面规范以 [ui-guidelines.md](ui-guidelines.md)
> 为准。这份文档是"翻译层"，不是权威来源；两者冲突时以上述三份为准。

---

## 0. 先用一句话对齐认知

IceShot 是一个**常驻菜单栏、不占 Dock** 的 macOS 截图工具。用户按 `⇧⌘X` → 屏幕冻结 →
拖一个框 → 松开后立刻在原地进入标注 → 点"复制"或"保存"。

它的技术本质是：

| 你熟悉的 | IceShot 里对应的 |
| --- | --- |
| 一个单 Activity / 单页 Web App | 一个 `@main App` 结构体，但**主界面是菜单栏弹出面板**，不是全屏窗口 |
| 路由 / Navigator | 三个 Swift `Scene`：菜单栏面板、`Window("历史记录")`、`Settings` |
| DI 容器（Hilt / Koin / Provider） | `AppDelegate`（手写手动注入，没有框架） |
| ViewModel + `StateFlow` / React state | `@Observable` 类（`CaptureCoordinator`、`EditorModel`） |
| Canvas / SurfaceView 自绘 | SwiftUI `Canvas` + `GraphicsContext`，或 Cocoa `CGContext` |
| Bitmap / Skia | `CGImage` + Core Graphics + Core Image（GPU 滤镜） |
| 系统截图 API（MediaProjection） | **ScreenCaptureKit**（`SCScreenshotManager`） |
| SQLite / Room / IndexedDB | **SwiftData**（`@Model` + `@Query`）+ 磁盘文件 |
| 全局热键（Android 无对应物） | Carbon `RegisterEventHotKey` |
| 前台服务 / 常驻通知 | 菜单栏图标（`MenuBarExtra`） |

一句话：**UI 用声明式框架（SwiftUI），像素级的事情全部下沉到命令式框架（AppKit / Core Graphics），
两者在同一次用户操作里交替出现。** 这是本项目对前端 / Android 背景的人最容易迷路的地方。

---

## 1. 项目基本盘

| 项 | 值 | 说明 |
| --- | --- | --- |
| 语言 | Swift 5（`SWIFT_VERSION = 5.0`） | **没开**严格并发检查，编译器不会帮你查线程问题 |
| UI | SwiftUI + AppKit 混用 | 见第 3 节 |
| 最低系统 | macOS 15.0 | 有条件分支用 macOS 26 的 Liquid Glass |
| IDE | Xcode 27+ | 不是 VS Code + 命令行那一套 |
| 工程 | 单 target、单 module | 没有多模块，没有 SPM 第三方依赖 |
| 持久化 | SwiftData + 沙盒文件 | 数据库只存元数据，图片存文件 |
| 构建门禁 | `Scripts/gate.sh` | 构建 + 全部测试 + **零警告** |
| 包管理 | 无 | 只用系统框架。别想着 `npm install` / Gradle 依赖 |

**没有任何第三方库。** 没有 Alamofire、没有 Kingfisher、没有 RxSwift、没有 Metal 封装。
系统框架能做的就调系统框架——这是项目的硬规则。

代码规模参考（自己跑 `find IceShot -name '*.swift' | xargs wc -l` 比记数字靠谱）：

```
IceShot/            应用本体，App + Core + Features 三层
IceShotTests/       Swift Testing 单元测试（针对 Core 纯逻辑）
IceShotUITests/     XCTest 冒烟，极少
Scripts/            门禁 / 打包 / 图标生成
docs/               文档
```

---

## 2. 三分钟把它跑起来

```bash
# 1. 配签名团队（只需一次，Team ID 不进版本库）
cp Signing.local.xcconfig.example Signing.local.xcconfig
# 编辑它，写入 DEVELOPMENT_TEAM = 你的TeamID
# 查 Team ID：security find-identity -v -p codesigning

# 2. 打开工程 → ⌘R
open IceShot.xcodeproj

# 3. 命令行跑门禁（改完代码必须跑，这是"做完"的唯一判据）
Scripts/gate.sh
```

第一次运行时的事：

- 应用会引导你要**屏幕录制权限**（系统设置 → 隐私与安全性 → 录屏与系统录音）。
- 授权后要**重启一次 IceShot**，这是 macOS 的机制，不是 bug。
- 应用启动后**没有窗口**，去屏幕右上角菜单栏找照相机图标。
- 截图快捷键：`⇧⌘X` 区域、`⇧⌘K` 窗口、`⇧⌘F` 全屏。

常见坑：

| 现象 | 原因 / 解法 |
| --- | --- |
| `gate.sh` 报 `code object is not signed at all` | `rm -rf build/GateDerivedData` 后重跑 |
| 截出来是黑的 / 一张纯白图 | 权限没给，或给了没重启 |
| 应用一闪而过 | 它是 `LSUIElement`（菜单栏应用），本来就不出现在 Dock |
| 新增的 .swift 文件没被编译 | 检查是不是放到了 `IceShot/` 目录外。工程用**文件系统同步分组**，不用手改 `project.pbxproj` |

---

## 3. 最关键的一课：SwiftUI 负责布局，AppKit 负责"接管屏幕"

这是和 Web / Android 差别最大的地方，先讲透。

### Web / Android 的心智模型

```
用户点击 → 框架把事件派发给组件 → 组件更新状态 → 框架重新渲染
```

一切都在**你的应用窗口内部**发生。你把页面画在浏览器 / Activity 的 Surface 上。

### IceShot 的模型

截图工具要干的事，是**盖住整个屏幕、盖住别的应用**。这不是"在窗口里布局"能解决的。
所以它有三层同时存在的东西：

```
┌─────────────────────────────────────────────────────┐
│ 第 3 层  SwiftUI          ← 布局、控件、画图、文本     │  MarkupCanvas / MenuBarView / LibraryView
├─────────────────────────────────────────────────────┤
│ 第 2 层  AppKit 窗口/事件  ← NSPanel、鼠标键盘、光标   │  CaptureOverlayPanel / NSWindow / NSEvent monitor
├─────────────────────────────────────────────────────┤
│ 第 1 层  系统能力          ← 抓屏、OCR、热键、文件      │  ScreenCaptureKit / Vision / Carbon / SwiftData
└─────────────────────────────────────────────────────┘
```

- **第 1 层**用系统框架。你的业务代码通过**协议**（`ScreenCapturing`、`TextRecognizing`）调它，
  测试时换成假实现。
- **第 2 层**是 AppKit。截取浮层是一个 `.borderless` + `nonactivatingPanel` 的 `NSPanel`，
  层级设为 `.screenSaver`（比一切窗口都高）。鼠标键盘事件用 `NSEvent.addLocalMonitorForEvents`
  抢在响应链之前处理。光标用 `NSCursor` 手动设置。
- **第 3 层**是 SwiftUI。它**只负责把这一帧画出来**，不管窗口怎么存在、事件从哪来。

对应到你的经验：

| 你要做的事（Web 直觉） | IceShot 的做法 |
| --- | --- |
| 弹一个全屏遮罩 `<div style="position:fixed;inset:0">` | 每块显示器一个 `NSPanel`，`level = .screenSaver` |
| 监听 `mousemove` | `NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged])` |
| `document.body.style.cursor = 'crosshair'` | `cursor.set()`，且规则抽成纯函数可单测（`SelectionCursorRule`） |
| Esc 关闭弹层 | **不要**指望默认行为：`NSPanel` 默认把 Esc 走成 `performClose:`，整个浮层会消失。项目里重写 `performClose` / `close` 统一转成"取消"语义 |

> 真实例子，读一下 `Features/Capture/Overlay/CaptureOverlayPanel.swift` 的注释。
> 里面解释了为什么不能只靠 SwiftUI 的 `onContinuousHover`（它的追踪区只跟着具体子视图走，
> 指针停在手柄上时父层收不到事件，光标就"不跟手"）。这类"为什么不用更简洁的写法"
> 的注释在仓库里很密集，**它们比代码本身更值得读**。

### 状态如何流动

```
用户点菜单 / 按热键
      ↓
CaptureCoordinator.startRegionCapture()      ← @MainActor @Observable，全部入口都收敛到这里
      ↓  state = .selecting（UI 据此禁用重复入口）
ScreenCaptureService.captureDisplayFrames()   ← 抓每块屏的冻结帧
      ↓
SelectionOverlayController.present(frames:)   ← 每块屏开一个 NSPanel
      ↓  SwiftUI 画 SelectionOverlayView（冻结图 + 压暗 + 放大镜 + 操作条）
用户拖框 → 松手 → onSelectionReady
      ↓
SelectionOverlayState.beginEditing(editor: EditorModel)   ← 就地进入标注，用同一个画布
      ↓
用户点「复制」→ MarkupAction.copy → SelectionFinish
      ↓
CaptureCoordinator.handleFinish()             ← 复制 / 保存 / 贴图 / 写历史，四件事在这一个函数里分支
      ↓
state = .idle，浮层关闭，前台还给被截的 App
```

注意几点：

- **`CaptureCoordinator` 是截图流程的总状态机**。它用 `state: State` 保证同一时刻只跑一个
  截图流程。你要加新的截图入口，就加一个 `startXxx()` 方法，**不要**绕开它自己开窗口。
- **不要用 ViewModel**。项目里**没有 ViewModel 层**。`EditorModel` 是"状态机 + 数据模型"，
  不是 MVVM 里的 VM。View 直接读它。
- **不是 Hilt**：所有依赖在 `App/AppDelegate.swift` 的 `init` 里手工 `new` 出来然后注入。
  加一个全局服务 = 在 `AppDelegate` 里创建并 `let` 住。

---

## 4. 目录地图（按你在 Web / Android 里的目录直觉对照）

```
IceShot/
├── IceShotApp.swift        ≈ App.kt / main.jsx        只有 Scene 声明，不创建业务对象
├── App/                    ≈ app 模块 / application 层
│   ├── AppDelegate.swift   组合根（= 你的 Application.onCreate + Hilt module）
│   ├── MenuBarView.swift   菜单栏面板（= 主界面）
│   ├── ActivationPolicyController.swift   Dock 图标显隐
│   └── SettingsWindowPresenter.swift
├── Core/                   ≈ domain + data 层，纯逻辑，无 UI
│   ├── Capture/            抓屏、几何、选区、长截图拼接
│   ├── Imaging/            裁剪、编码、剪贴板、缩略图、保存面板
│   ├── Persistence/        SwiftData 模型 + 文件存储
│   ├── OCR/                Vision 文字识别
│   ├── Hotkeys/            全局快捷键
│   ├── Pinning/            贴图窗口的领域模型
│   ├── Interaction/        光标、坐标换算
│   ├── Permissions/        屏幕录制权限
│   ├── AppInfo/            版本号、更新检查
│   ├── DesignSystem/       GlassSurface（材质封装，唯一在 Core 里的 SwiftUI）
│   └── Utilities/
└── Features/               ≈ ui 层（页面 + 组件）
    ├── Capture/            选区浮层、窗口高亮、倒计时 HUD、长截图 HUD
    ├── Editor/             标注编辑器（仓库最大的功能）
    ├── Library/            历史库窗口
    ├── Pinning/            贴图窗口
    ├── Settings/           设置面板
    └── Permissions/        权限引导
```

依赖方向是**单向**的：

```
Features ──→ Core
    ↑          ↑
    └── App ───┘     App 是装配层，可以依赖两边
```

`Core` **不准** import `Features`。这跟你把 `data/` 反向依赖 `ui/` 一样属于架构错误，
但这里没有 lint 拦你，靠自觉。

---

## 5. 入口逐个走一遍（建议按这个顺序读代码）

### 5.1 `IceShot/IceShotApp.swift` —— 有什么入口

`≈` 你的 `MainActivity` / 路由表。它只干三件事：

1. `MenuBarExtra` —— 菜单栏图标 + 点击弹出的面板（`MenuBarView`）。
   注意 `.menuBarExtraStyle(.window)`：面板里能放任意 SwiftUI 视图，不是只有菜单项。
2. `CommandMenu("截图")` —— 应用菜单栏里的"截图"菜单，写了**全部**截图入口
   （区域 / 重复上次 / 窗口 / 全屏 / 长截图 / 全部显示器 / 延时 / 取消）。
   延时截图没有对应的热键入口，只从菜单进。
3. `Window("历史记录", id: "library")` + `Settings` —— 两个独立窗口。
   `.defaultLaunchBehavior(.suppressed)` 表示启动时不主动弹。

读这个文件时留意：**每个按钮只是 `Task { await coordinator.startXxx(...) }`。**
Scene 里不许 `init` 业务对象，全部从 `appDelegate` 拿。

### 5.2 `IceShot/App/AppDelegate.swift` —— 谁被创建、怎么串起来

`≈` Hilt 的 `@Module` + `Application.onCreate()`。181 行，必读。

```
AppDelegate.init()
  ├─ LibraryRuntimeFactory.make()   → ModelContainer + LibraryStore + LibraryPaths
  ├─ PinBoard()                     贴图看板
  ├─ FeedbackHUDController()        "已复制"这类短反馈的统一通道
  ├─ EditorCoordinator(pins:feedback:library:)   编辑器窗口持有者（同时只留一个窗口）
  ├─ CaptureCoordinator(history:pins:editor:feedback:)   截图总协调器
  ├─ GlobalHotkeyManager(coordinator:)   全局热键，动作最终也是调 coordinator
  └─ UpdateChecker(presenter:downloader:)  GitHub Release 更新检查
```

`applicationDidFinishLaunching` 里做四件事：注册热键、建激活策略控制器、做权限预检并弹引导、
跑历史库维护（清理过期）、延迟 500ms 检查更新（避免和模态引导抢焦点）。

**测试宿主判定**：`ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil`
时跳过欢迎框、热键注册、联网检查。你加启动逻辑时**必须**尊重这个开关，否则测试会卡住。

### 5.3 `Features/Capture/CaptureCoordinator.swift` —— 一次截图的完整生命周期

871 行，是理解整个应用的**最佳单文件**。核心 API 一览：

| 方法 | 干什么 |
| --- | --- |
| `startRegionCapture(delay:countdownSeconds:)` | 区域：抓冻结帧 → 开选区浮层（带窗口目录，可点窗口） |
| `startWindowCapture(...)` | 窗口：抓帧 → 窗口高亮浮层 → 点了抓该窗口完整内容 |
| `startFullScreenCapture(...)` | 全屏：只抓光标所在那块屏，直接给预设选区 |
| `startAllDisplaysCapture(...)` | 全部显示器：全部抓，编辑器里可切换 |
| `startRepeatLastRegion(...)` | 复用 `LastRegionStore` 里的上次选区，显示器变了自动回退到框选 |
| `startScrollCapture(delay:)` | 长截图：框选 → 不落历史 → 连续抓同一区域拼接 |
| `cancelCurrentSelection()` | Esc / 菜单"取消当前截图" |

私有但关键的几个：

- `prepareForCapture(delay:)` —— 互斥检查、权限检查、记下当前前台 App。
- `handleFinish(_ finish: SelectionFinish)` —— **收尾的唯一分岔口**：按 `finish.action`
  （`.copy` / `.save` / `.pin` / `.close`）分支，最后统一写历史 + 把前台还给用户原来的 App。
- `windowPreset(for:frames:mode:)` —— 窗口图从哪来，`.whatYouSee`（所见即所得，裁冻结帧）
  还是 `.fullWindow`（抓窗口自身，能拿被遮挡内容）。

**要加一个截图变体，就在这里加一个 `startXxx()`，然后在 `IceShotApp.swift` 加按钮。**
不要自己开 `NSPanel`。

### 5.4 `Features/Capture/Overlay/*` —— 浮层怎么搭起来

| 文件 | 职责 | 类比 |
| --- | --- | --- |
| `CaptureOverlayPanel` | `NSPanel` 子类：层级、Esc 语义、"关不掉"保护、指针监视器 | 一个特制的全屏 Overlay Window |
| `SelectionOverlayController` | 每块屏开一个 panel，管生命周期和键盘监视 | Overlay 的 Presenter |
| `SelectionOverlayView` | SwiftUI 视图：冻结图、压暗、放大镜、尺寸标签、手柄 | 页面本体 |
| `SelectionOverlayState` | 多屏共享的选区状态（单例状态，同一时刻只有一块屏有选区） | 状态 Store |
| `MagnifierView` | 8× 像素放大镜 | 组件 |
| `WindowHighlightView` | 悬停窗口高亮 | 组件 |

`SelectionOverlayView.swift` 700 行，是浮层里最重的一个。它有个巧妙的点：
**区域截图时模型图是"整个冻结帧"，选区只是它的可视窗口**，所以进入编辑态后还能继续
调选区而不丢标注；窗口 / 全屏 / 重复区域用"预设图像"，选区锁定。

### 5.5 `Features/Editor/*` —— 编辑器（最大的模块）

如果只读两个文件，读 `EditorModel.swift`（状态机）和 `MarkupCanvas.swift`（绘制）。

```
EditorCoordinator          打开 / 关闭编辑器窗口（同时只留一个）
  ↓
EditorWindowController     NSWindowController，持有 model，装配工具栏与状态栏
  ↓
EditorRootView             SwiftUI 根视图
  ├─ MarkupToolbar         玻璃胶囊操作条（浮层与编辑器共用同一条）
  ├─ MarkupCanvas          画布：背景图 + 标注层 + 绘制/移动手势
  └─ InlineTextEditor      文字标注的内联输入
```

状态机 `EditorModel` 里有什么（挑重点）：

```
image: CGImage               当前图像（裁剪/旋转会换掉它）
annotations: [EditorAnnotation]   已有标注（纯值类型数组）
selectedID: UUID?            当前选中的标注
tool: EditorTool             .select(哨兵) / .crop / .rectangle / .arrow / .text / .pixelate / ...
color / lineWidth            新标注样式
cropRect: CGRect?            裁剪模式下的裁剪框
isTextPicking: Bool          取字模式（Live Text）
optionsTarget: OptionsTarget? 二级选项浮窗（按 Esc 先关它）
```

**撤销怎么做**：不是"反向操作"，而是 **snapshot 快照**。每次操作把 `EditorState(image + annotations)`
存一份进 `UndoManager`，撤销就是把快照换回来。注意 `image` 也进快照——撤销裁剪时必须连图像一起还原。

**标注怎么渲染**：

- 屏幕预览：`EditorDrawing.draw(annotation, in: &GraphicsContext, layout:)`，画在 SwiftUI `Canvas` 上。
- 导出成品：`EditorModel.renderedImage()` 用 `ImageRenderer` 把同一个视图渲成 `CGImage`，
  **scale = 1**（因为坐标本来就是原图像素）。
- 马赛克/模糊：`MarkupFilters.MarkupFilterCache`，走 Core Image 的 `CIPixellate` / `CIGaussianBlur`，
  用蒙版贴回原图。拖拽中用 720px 降采样预览保帧率，松手后按原像素重算。

**坐标**：全部在**原图像素空间**（左上原点）。画到屏幕上时经 `EditorCanvasLayout` 统一换算，
线宽也跟着 `scale` 缩放。所以窗口缩放时标注和原图的比例永远一致。

### 5.6 `Features/Library/*` —— 历史库

`≈` 一个列表页 + 详情页 + 数据仓库。

- `LibraryView.swift` 用 `@Query(sort: \ScreenshotRecord.createdAt, order: .reverse)` 拿数据。
  **这是 SwiftData 的响应式查询**——数据库一变，View 自动刷新，不需要你手动 refresh。
- 三栏 `NavigationSplitView`：筛选 → 列表 → 详情。
- 双击进编辑器、右键菜单、`⌫` 删除、`.onDrag` 拖到 Finder。
- 选中项会 `setProtectedRecord(id)` 保护起来，自动清理不会删掉你正在看的图。

### 5.7 `Core/Persistence/*` —— 数据怎么存

**关键设计：数据库只存元数据，图片存文件。**

```swift
@Model
final class ScreenshotRecord {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var pixelWidth / pixelHeight / byteSize: Int
    var sourceRaw: String          // 枚举以字符串存库，避免迁移限制
    var originalFileName: String   // 相对文件名，不是绝对路径
    var thumbnailFileName: String
    var editFileName: String?
    var ocrText: String?
    var tags: [String]
    var isFavorite: Bool
}
```

理由（写在注释里）：列表查询只读元数据，图片按需从磁盘加载，既控数据库体积，
也避免删记录时遗漏大文件。

**磁盘 IO 全在一个 `actor` 里**（`Core/Persistence/FileStore.swift`）。这是本项目并发纪律的范例：
actor 内做所有磁盘操作，只接受/返回**相对文件名**，返回绝对的 `URL` 只有少数 `nonisolated` 的只读路径方法。

**schema 版本化**：`IceShotSchemaV1` + `IceShotMigrationPlan`。当前只有 V1，所以 `stages` 为空。
**改模型字段是高危操作**（会让已存的历史库迁移失败丢数据），必须先加 `VersionedSchema` 再补迁移阶段。
这是 `AGENTS.md` 明文要求"动手前先问"的事项之一。

### 5.8 `Core/Capture/ScrollCapture/*` —— 长截图怎么拼

值得单独看一眼，因为算法很干净：

1. 用户在框好的区域里**自己滚动**（不需要辅助功能权限）。
2. `ScrollCaptureSession` 每 350ms 抓一次同一区域（上限 60 秒）。
3. `ScrollStitcher` 把"已拼接结果的底部 120px 条带"当模板，在当前帧里竖直搜索最小灰度差位置，
   得到位移量，位移之后的部分就是新内容，追加到底部。
4. 全程 **1:1 像素不缩放**，接缝不会因为重采样发糊。
5. 位移超过帧高 70% 判为"跳变"（滚太快），拒绝并提示，而不是拼出一张错位的图。

这是纯像素逻辑，没有任何 UI 依赖，所以测试很好写（`ScrollStitcherTests`）。

---

## 6. Swift 语法速查（对 Web/Android 开发者最省时间的部分）

### 声明与类型

```swift
let x = 1              // 常量（JavaScript const / Kotlin val）
var y = 2              // 变量（let / var）
func f(_ a: Int) -> String { "\(a)" }   // 参数名 _ 表示调用时不写标签
struct S { }           // 值类型（≈ Kotlin data class，但语义是拷贝）
final class C { }      // 引用类型
enum E { case a, b }   // 枚举，可以带关联值（≈ Kotlin sealed class）
protocol P { }         // 接口（两种角色：Swift 协议 ≈ Kotlin interface / TS interface）
extension P { }        // 给已有类型加方法（≈ Kotlin extension function）
```

`?` 是可选类型：`String?` ≈ `String | null`。`if let v = x { }` ≈ `if (x != null)`。
`??` ≈ `??`（Kotlin）/ `||`（JS）。

### 项目重度使用的三个属性包装器 / 宏

```swift
@MainActor        // ≈ 强制在主线程（Android 的 @MainThread / "必须在 UI 线程"，但由编译器检查）
@Observable       // ≈ 可观察状态（Android 的 StateFlow，但自动追踪字段访问）
@Query            // SwiftData 的响应式查询，View 里用
```

`@Observable` 的用法：任何 View 里读了 `model.someProperty`，该属性一变 View 就重绘。
**不需要你手动写 `observe` / `collect`**。这就是为什么项目里"没有 ViewModel 也能跑"——
`EditorModel` 自己被观察。

### async / await（≈ Kotlin coroutine / JS async）

```swift
func capture() async throws -> CGImage     // 声明异步 + 可抛错
let image = try await capture()            // 调用（await 标记挂起点，try 因为会抛）
Task { await coordinator.startRegionCapture() }   // 从同步上下文启动任务（≈ launch{}）
actor FileStore { }                        // 线程安全容器，跨它调用必须 await
@MainActor final class X { }               // 类所有成员都被约束到主线程
```

**陷阱**：项目**没开**严格并发检查。跨并发域传值类型时**必须**标 `Sendable`
（`DisplayFrame`、`SelectionResult`、`WindowDescriptor`、`LastRegion`、`CaptureError` 都标了）。
不标编译器不报错，运行时可能崩。这是项目文档自己承认的"最容易埋雷的地方"。

### SwiftUI 的两个"和 React 不一样"

1. **`@State` 是视图自己的状态**，`@Binding` 是传给子视图的可写引用。
   类比 React：`@State` ≈ `useState`，但改了直接赋值（`x = 1`），没有 `setX`。
2. **`body` 是每次渲染都会重新执行的计算属性**。所以 `body` 里不能有副作用，
   初始化要放 `init`，副作用放 `.task {}` / `.onAppear {}`。

### AppKit 里一定会碰到的

```swift
NSPanel                   一个浮层窗口（≈ Window/Overlay）
NSWindow                  普通窗口
NSWindowController        管理窗口生命周期
NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in ... }   // 抢在响应链前处理事件
NSCursor.crosshair.set()  设置光标
NSAlert                   系统弹窗
NSBitmapImageRep / CGContext / CIContext   位图与像素操作
```

---

## 7. 你动手改代码时的路径（三个实际任务）

### 任务 A：改一个标注工具的默认颜色

1. `Core/Persistence/ColorPalettePreferences.swift` —— 看默认色板怎么来的。
2. `Features/Editor/EditorAnnotation.swift` 里的 `EditorColor.builtInPaletteHex` —— 内置 8 色的十六进制。
3. 注意 `ui-guidelines.md` 的例外条款：**标注颜色是硬编码 RGB，故意的**。
   标注要烧进截图，不能随浅色/深色模式变。`defaultRed` / `readableDark` / `readableLight`
   属于"标注内容自身"，不是界面 chrome。**别顺手改成语义色**。

同时补测试：`IceShotTests/ColorPaletteTests.swift`。

### 任务 B：加一个菜单/菜单栏按钮

1. 如果已有对应逻辑 → 只改 `IceShotApp.swift`（菜单栏）和 `App/MenuBarView.swift`（面板）。
2. 如果需要新流程 → 在 `CaptureCoordinator` 加 `startXxx()`，复用 `prepareForCapture` /
   `restorePreviousApplication` / `state` 那套骨架。
3. 按钮 `.disabled(coordinator.isBusy)` 是标配，别漏。
4. 需要热键 → `Core/Hotkeys/GlobalHotkeyManager.swift` 的 `Hotkey` 枚举加一项，
   并补 `defaultBinding`。热键冲突检测已有现成实现。
5. 跑 `Scripts/gate.sh`。

### 任务 C：改一个界面元素的样式

先读 `docs/ui-guidelines.md`，然后记住三条硬规则：

- **材质交给系统**：用 `.glassSurface(.elevated)` / `.glassSurface(.standard)`，
  **不准** `.background(.ultraThinMaterial).opacity(0.7)` 这种手绘模糊+自调透明度。
- **颜色不准硬编码**：用 `Color(nsColor: .windowBackgroundColor)`、`.labelColor`、`.accentColor`。
- **正文用语义字号**：`.caption` / `.callout` / `.headline`，不写死 `12pt`。
  固定点数只允许在"压在截图上的标记" / "全屏 HUD 大数字" / "图标尺寸"三种场景。

---

## 8. 改完必须做的事

```bash
Scripts/gate.sh
```

这是**唯一判据**。它做三件事：

1. `xcodebuild build`（Debug）
2. `xcodebuild test` —— Swift Testing 单元测试 + XCTest UI 冒烟
3. 按 `文件:行:列: warning:` 逐条数警告，**1 条即失败**

没有 CI、没有 git hook、没有 pre-commit。**全靠你自己跑。**

文档里的硬约定（摘自 `AGENTS.md`）：

- **代码注释、UI 文案、提交信息一律简体中文**（类型/函数/API 名保持英文）。
- `IceShotTests` 用 **Swift Testing**（`import Testing` + `@Test` + `#expect`），
  **不要**新写 XCTest 单元测试。
- 测试只针对 `Core` 的纯逻辑，不启动 App、不真实截屏、不碰用户目录。
- 提交信息：Conventional Commits + 中文 scope，如 `fix(长截图): 确认选区后先归还前台再开始采集`。

### 绝对不要碰的（会变成安全事故或数据损坏）

1. 新增系统权限（当前只有屏幕录制）。
2. 新增网络端点（白名单只有 `api.github.com` 和 `objects.githubusercontent.com`）。
3. 改隐私承诺（README「隐私」节、roadmap「不变的底线」）。
4. 改签名与发布链路（`Signing.xcconfig`、`Scripts/package.sh`、`Scripts/gate.sh` 判据）。
5. 删路线图里的 ❌ 项。
6. 提交密钥/签名材料（`Signing.local.xcconfig`、`*.p12` 等）。
7. **改 SwiftData 模型 / schema**（会牵连用户已存的历史库）。

遇到这几项，停下来问，别自己决定。

---

## 9. 前端 / Android 经验会骗你的十个地方

| 你的直觉 | 实际情况 |
| --- | --- |
| "应用一定有主窗口" | 它是 `LSUIElement`，**默认不占 Dock**。Dock 图标由 `ActivationPolicyController` 在 `.regular` ⇄ `.accessory` 之间动态切换 |
| "UI 层就是整个应用" | UI 只是一半。真正的核心在 `NSPanel` + `NSEvent` 监视 + 系统抓屏 API |
| "应该有 ViewModel" | 项目**明确没有** ViewModel 层。`@Observable` 的 Model 直接被 View 读 |
| "改状态要 setState / notify" | `@Observable` 自动追踪，直接赋值即可 |
| "异步要小心别卡 UI" | 这个项目**默认靠纪律**：UI 标 `@MainActor`，磁盘 IO 走 actor，但编译器没开严格检查帮你兜底 |
| "有包管理器就该装库" | **零第三方依赖**。系统框架能做的就调系统框架 |
| "窗口坐标就是屏幕坐标" | 这里有**三套坐标**：AppKit 屏幕坐标（y 向上、跨屏全局）、显示器局部坐标（左上原点）、图像像素坐标。`Core/Interaction/OverlayCoordinates.swift` 是唯一换算来源，别自己算 |
| "hover / mousemove 会一直回调" | SwiftUI 的 `onContinuousHover` 由**视图内部追踪区**驱动，指针停在子视图或层次间的空隙时父层收不到。所以浮层用窗口级 `NSEvent` 监视器 |
| "Esc 就是关掉" | `NSPanel` 默认把 Esc 走 `performClose:`，会**静默丢掉整次截图且不落历史**。项目里重写了 `close` / `performClose` 统一转成取消语义 |
| "透明度 / 模糊自己调就行" | 材质必须交给系统（`GlassSurface`）。手绘模糊会被当作缺陷 |

---

## 10. 推荐阅读顺序（半天到一天）

| 顺序 | 文件 | 目的 |
| --- | --- | --- |
| 1 | `AGENTS.md` | 工作契约与禁忌（15 分钟） |
| 2 | `docs/architecture.md` | 三层结构、并发纪律（15 分钟） |
| 3 | `IceShot/IceShotApp.swift` | 有多少个入口（10 分钟） |
| 4 | `IceShot/App/AppDelegate.swift` | 依赖怎么装配（15 分钟） |
| 5 | `IceShot/Core/Capture/ScreenCapturing.swift` | **协议比实现重要**：看懂这个就知道抓屏能力的边界（10 分钟） |
| 6 | `IceShot/Features/Capture/CaptureCoordinator.swift` | 一次截图的完整生命周期（30 分钟，重点） |
| 7 | `IceShot/Features/Editor/EditorModel.swift` | 状态机 + 撤销 + 渲染（30 分钟） |
| 8 | `IceShot/Features/Editor/MarkupCanvas.swift` | 声明式 UI 下令牌式绘制（翻一遍，20 分钟） |
| 9 | `IceShot/Core/Persistence/ScreenshotRecord.swift` | 数据模型（10 分钟） |
| 10 | `docs/ui-guidelines.md` | 动 UI 前必读（15 分钟） |
| 11 | `Scripts/gate.sh` | 门禁到底在查什么（10 分钟） |

顺带看一眼测试，它们是最好的"接口文档"：`IceShotTests/SelectionGeometryTests.swift`、
`ScrollStitcherTests.swift`、`EditorModelTests.swift`。

---

## 11. 一页速查卡

```
跑起来       open IceShot.xcodeproj → ⌘R
            首次要屏幕录制权限 → 授权后重启 IceShot
            应用没有窗口，去菜单栏

门禁         Scripts/gate.sh            （唯一"做完"判据）
打包         Scripts/package.sh         （会先跑门禁）

入口         IceShot/IceShotApp.swift        Scene 声明
装配         App/AppDelegate.swift           所有服务的组合根
截图总控     Features/Capture/CaptureCoordinator.swift
编辑器状态   Features/Editor/EditorModel.swift
画布         Features/Editor/MarkupCanvas.swift
数据模型     Core/Persistence/ScreenshotRecord.swift

分层         Features → Core，App 依赖两边，Core 不得 import Features
UI           SwiftUI 布局 + AppKit 窗口/事件 + Core Graphics 像素
并发         @MainActor 管 UI，actor 管磁盘，跨域值类型必须 Sendable
风格         无第三方依赖 / 材质交系统 / 颜色用语义色 / 注释中文讲为什么

禁用         手改 project.pbxproj（文件系统同步分组，放进目录即可）
             裸 xcodebuild build 宣称完成（跑不了测试也不查警告）
             新增系统权限 / 网络端点 / 改 schema（先问）
```
