# 工程规范

写代码、提交、发版时遵守的规则。机械可执行的硬门禁见 [AGENTS.md](../AGENTS.md)，这里不重复。

---

## 构建与工程配置

- 单一 Xcode target，`PRODUCT_MODULE_NAME = IceShot`。
- `MACOSX_DEPLOYMENT_TARGET = 15.0`。不要用需要更高系统版本才有的 API，除非有版本分支。
- `SWIFT_VERSION = 5.0`，未开严格并发。并发纪律靠手工，见 [architecture](architecture.md) 的并发一节。
- **文件系统同步分组**（`PBXFileSystemSynchronizedRootGroup`）：新增 Swift 文件直接放进目录即可
  自动纳入编译，**不要手工编辑 `project.pbxproj`**。
- 仓���没有 CI、没有 git hook、没有 Makefile。质量门禁只能靠手动跑 `Scripts/gate.sh`。

---

## 分层与依赖

```
Features ──→ Core
    ↑          ↑
    └── App ───┘   （App 是装配层，可依赖两者）
```

- `Core` **不得** import `Features`。
- `Core` 不含 SwiftUI / AppKit 视图代码。唯一例外是 `Core/DesignSystem`（材质封装）与
  `Core/AppInfo/UpdateProgressPanel`（进度面板），它们需要 SwiftUI 类型。
- 业务对象只在 `App/AppDelegate` 创建。Scene 与 View 不 `init` 服务。

---

## 命名

- 类型 `UpperCamelCase`，方法/属性 `lowerCamelCase`，与 Swift API Design Guidelines 一致。
- 文件名 = 主类型名。一个文件一个主类型。
- 协议用能力名（`ScreenCapturing`、`HistorySaving`），实现用具体名（`ScreenCaptureService`）。
- 测试文件 = 被测类型 + `Tests`（`SelectionGeometryTests.swift`）。
- **不用英文缩写造词**。`VC`、`Mgr`、`Hdlr` 这类缩写不收。

### 后缀的取舍

后缀不是分类学，是**说清楚这个类型在架构里站哪一格**。按现有代码的实际用法：

| 后缀 | 用在 | 例 |
| --- | --- | --- |
| `Coordinator` | 编排一次跨多个对象的用户流程，持有生命周期 | `CaptureCoordinator`、`EditorCoordinator` |
| `Controller` | 拥有窗口 / 浮层（`NSWindowController` 或持有窗口的类） | `EditorWindowController`、`CountdownHUDController`、`SelectionOverlayController` |
| `Store` | 持有可变集合并对外提供读写 | `LibraryStore`、`LiveTextStore`、`LastRegionStore` |
| `Service` | 无状态或单例式的系统能力封装，调外部的 | `ScreenCaptureService`、`LaunchAtLoginService` |
| `Manager` | **尽量别新增**。已有 `GlobalHotkeyManager` 保留不改，但这是历史包袱，新代码优先考虑 `Service` | |
| `Presenter` | 专门的展示触发逻辑，无状态用 `enum` 命名空间 | `SettingsWindowPresenter`、`AlertUpdatePresenter` |
| `Board` | 贴图看板的领域容器 | `PinBoard` |

判断标准：**能说出"它编排谁 / 它拥有什么 / 它调用谁"三者中的一个，就有对应后缀。三者都说不清，说明这个类型职责没想清楚。**

### View / Model 的取舍

- `View` 后缀只给 SwiftUI 视图。`MarkupCanvas`、`MarkupToolbar` 这类直接当视图用的不加后缀——名字已经是名词。
- `Model` 后缀给**状态机或数据模型**，不给视图模型。本仓库没有 ViewModel 层。

### `Manager` 类：存量保留，不再新增

`GlobalHotkeyManager` 是唯一一个 `Manager`。**不再新增 `*Manager`**，按上表选 `Service`
（无状态能力封装）或 `Coordinator`（编排流程）。

不要求为改名而改名——`GlobalHotkeyManager` 可以留着，直到它有天自然被动到时
再改名。但新增类型不许跟着这个模式走。

---

## 注释

- **代码注释一律简体中文。** 类型、函数、API 名保持英文原样。
- 注释解释**为什么**，不复述**做了什么**。`// 设置宽度` 是噪音；`// 玻璃强度交给系统设置，应用不加染色` 有价值。
- 有非显然取舍时，把被否决的方案也写一句——防止后人重走一遍。
  范例见 `Core/DesignSystem/GlassSurface.swift` 的 `GlassContrast` 注释。
- 公共类型与方法用 `///` 文档注释。

---

## 错误处理

- 领域错误用具体 `enum` 遵守 `LocalizedError`（如 `CaptureError`、`LibraryError`），
  不抛裸 `NSError`，不用字符串错误。
- 错误信息面向用户时是中文，且不泄露路径、窗口标题等敏感信息。
- 不用 `try!` / `as!`。确实不可能失败的地方用 `preconditionFailure` 并写清前提。

---

## 测试

- `IceShotTests` 用 **Swift Testing**：`import Testing`、`@Test` 函数、`#expect(...)`。
  **不要**新写 XCTest 单元测试。
- 测试对象是 `Core` 的纯逻辑。不启动 App、不真实截屏、不读写真实用户目录。
- 磁盘相关逻辑用 `FileStore` 一类的协议注入临时目录。
- `IceShotUITests` 只放极少量冒烟用例，不要扩张成回归测试套件。
- 断言失败先判断是**实现错了**还是**测试错了**，不要为了绿灯放宽断言。

---

## 本地化

代码里的 UI 文案一律写**中文原文**，中文就是开发语言（`developmentRegion = zh-Hans`）。
英文走 `IceShot/en.lproj/Localizable.strings`，中文不需要 `.strings`（字面量即原文）。

**两种写法，别弄混：**

| 上下文 | 写法 | 为什么 |
| --- | --- | --- |
| SwiftUI 控件 | `Text("保存")` | 字面量本就是 `LocalizedStringKey`，自动本地化 |
| 返回 `String` / 赋值 | `String(localized: "保存")` | 裸字面量不参与本地化，必须显式包 |

**新增文案时一定要同步 `en.lproj/Localizable.strings`**——
`LocalizationTests` 会把漏翻、译文残留中文、占位符数量不一致三类回归当失败。

插值字符串（`"已旋转 \(angle)°"`）目前不做本地化：
`String(localized:)` 收的是 `LocalizationValue`，内嵌表达式和引号很容易写坏。
真要本地化就先拆成 `%@` 占位 + `String(format:)`。

---

## 提交与 CHANGELOG

### 提交信息

Conventional Commits + 中文 scope。**scope 可选**——改动横跨多模块时省掉。

```
feat(编辑器): 支持在编辑器内删除历史截图
fix(长截图): 确认选区后先归还前台再开始采集
fix(scripts): 打包输出不再声称无联网权限
chore(release): 0.3.4
feat: 应用内更新提示
```

- 类型：`feat` / `fix` / `chore` / `refactor` / `test` / `docs`。
- scope：中文功能名（`编辑器`、`长截图`、`更新`），或目录名（`scripts`）。
- 描述部分简体中文，说清**用户可感知的变化**，不说"改了点代码"。

### CHANGELOG

- 面向**用户**，不是 commit log 的拷贝。`## <版本号> — <日期> · <通道>` 逐版本分组，最新在上。
- 记录"实现与最初设想的差异"——这是本仓库的既有做法，见 `roadmap.md` 的更新检查条目。

小版本（增量发布）用 **Keep a Changelog 式分组**：

```markdown
## 0.3.4 — 2026-10-23 · 预览版（Beta）

### 新增
### 修复
### 变更
```

首个大版本 / 需要展示全貌时，用**功能模块分组**：

```markdown
## 0.3.1 — 2026-10-23 · 首个公开版本

### 截取
### 标注
### 结果
### 系统集成
### 隐私
```

两种都在用，按场景选：日常发版用前者，开篇式发布用后者。不要为统一而重写历史条目。

---

## 发版

版本号与通道是两件独立的事：

- **通道不进版本号**。`beta` 只体现在 `ReleaseChannel` 与 DMG 文件名后缀。
- 版本号在 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`，与 `Core/AppInfo/AppVersion.swift` 保持一致。
- tag 形如 `v<版本号>-beta.N`。

流程：

```bash
Scripts/gate.sh                  # 必须先绿
Scripts/package.sh               # 出 DMG + SHA-256，写在仓库根目录（已忽略）
```

发版提交用 `chore(release): <版本号>`。

### 发版前检查清单

1. `Scripts/gate.sh` 绿。
2. `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` 已改，与 `AppVersion.swift` 一致。
3. `CHANGELOG.md` 已加对应版本条目，分组按上一节选。
4. **`docs/roadmap.md` 已同步**——新完成的能力从「🔜 待办」移到「✅ 已完成」，取消的项移到「❌ 已取消」并留档，优先级列顺手复核。
5. `docs/roadmap.md` 若有「测试数量」一类易腐烂数字，同日核对（或改为指向 `gate.sh`）。
6. 打 tag：`v<版本号>-beta.N`。

---

## 禁止事项

- 引入第三方依赖解决系统框架能解决的事。
- 把截图内容、文件路径、窗口标题写进日志。
- 提交 `Signing.local.xcconfig`、`*.p12`、`*.cer`、`.env`。
- 在文档里写会腐烂的数字（测试数、行数）。要数字就指向 `Scripts/gate.sh` 的输出。
