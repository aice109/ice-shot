# AGENTS.md

给在本仓库工作的 AI agent 的工作契约。人类贡献者请先读 [README](README.md) 的「从源码构建」小节。

`AGENTS.md` 是**入口**，不承载全部细节。按下面的路由表跳到对应的子文档精读，不要一次加载全部。

---

## 项目是什么

IceShot：原生 macOS 截图工具。菜单栏常驻、默认不占 Dock，全程本地处理。

截取 → 标注 → 复制 / 保存 / 历史。功能全貌见 [docs/roadmap.md](docs/roadmap.md)。

技术底座：Swift + SwiftUI + AppKit（`SWIFT_VERSION = 5.0`，未开严格并发检查），单一 Xcode
target（单 module），SwiftData 持久化，系统 Vision 做 OCR。macOS 15+，Xcode 27+。

**不变的底线**（继承自路线图，不得违反）：
本地处理 · 只在用户主动触发时截取 · 不静默上传。

---

## 常用命令

```bash
# 完整门禁：构建 + 全部测试 + 零警告。这是「做完」的唯一判据。
Scripts/gate.sh

# Release 构建（跳过测试，只保证编得过、无警告）
Scripts/gate.sh Release

# 打包 DMG（会先跑门禁）
Scripts/package.sh
ICESHOT_CHANNEL=beta Scripts/package.sh

# 首次在本机配置签名
cp Signing.local.xcconfig.example Signing.local.xcconfig   # 然后填 DEVELOPMENT_TEAM
```

`Scripts/gate.sh` 用独立 DerivedData（`build/GateDerivedData`），日志落在 `build/logs/`。
两者都已忽略，不入库。

新增 Swift 文件**不需要**改 `project.pbxproj`——工程使用文件系统同步分组，
直接放进 `IceShot/` 下即可自动纳入编译。

---

## 硬门禁

机械可执行，非绿不提交。**「完成」= `Scripts/gate.sh` 退出码 0。**

1. **构建必须成功。**
2. **全部测试必须通过。** Swift Testing（`IceShotTests`）+ XCTest UI 冒烟（`IceShotUITests`）。
3. **零警告。** `gate.sh` 按 `文件:行:列: warning:` 逐条计数，1 条即失败。没有「以前就有」的豁免。

**禁止**用裸 `xcodebuild build` 成功来宣称任务完成。它跑不了测试，也不查警告。
若 `gate.sh` 报 `code object is not signed at all`，先 `rm -rf build/GateDerivedData` 再重跑。

仓库没有 CI、没有 git hook。门禁全靠你手动执行——不要假设别人会替你跑。

---

## 动手前必须先问

下面这些改动做错了不是"扣分"，是**安全事故**或**不可逆数据损坏**。
遇到即停下来问，不要自行决定。

1. **新增系统权限** —— 辅助功能、输入监控、完全磁盘访问、自动化等。当前只用屏幕录制。
2. **新增联网能力** —— App 当前**完全不联网**，entitlements 里没有 `com.apple.security.network.client`。
   任何网络请求（端点、白名单、权限）都要先停下来问。
3. **修改隐私承诺** —— README「隐私」节、路线图「不变的底线」。
4. **修改签名与发布链路** —— `Signing.xcconfig`、`Scripts/package.sh`、`Scripts/gate.sh` 的判据。
5. **删除路线图的 ❌ 项** —— 已取消的能力必须留档，以免重复讨论。
6. **提交密钥或签名材料** —— `Signing.local.xcconfig`、`*.p12`、`*.cer`、`.env` 等。
7. **修改 SwiftData 模型 / schema** —— 会牵连用户已存的历史库，迁移失败可能丢数据。

组合根重构、模块拆分这类正常工程活动**不在**此列，该改就改。

---

## 软约定

风格偏好，别硬套。判断优先于规则；与硬门禁冲突时以硬门禁为准。

### 语言

代码注释、UI 文案、日志、`echo` 输出、提交信息、文档正文——**一律简体中文**。
类型名、函数名、API 名保持英文原样，不要把 `closure` 写成 `闭包` 这种翻译。

### 分层

- `IceShot/App` —— 应用外壳与依赖装配。`AppDelegate` 是唯一组合根，业务对象都在那里创建。
- `IceShot/Core/*` —— 无 UI 的业务与领域逻辑，按能力分目录。
- `IceShot/Features/*` —— SwiftUI 界面层，可以依赖 Core，Core 不得反向依赖 Features。

Scene 只做组装，不在 Scene 里创建业务对象。

### 提交信息

Conventional Commits + 中文 scope。scope 可选——改动横跨多个模块时省掉。

```
feat(编辑器): 支持在编辑器内删除历史截图
fix(长截图): 确认选区后先归还前台再开始采集
fix(scripts): 打包输出不再声称无联网权限
chore(release): 0.3.4
feat: 设置窗口支持侧边栏导航
```

类型用 `feat` / `fix` / `chore` / `refactor` / `test` / `docs`。
scope 用中文功能名（`编辑器`、`长截图`、`设置`），或脚本目录名（`scripts`）。

### 测试

`IceShotTests` 用 Swift Testing（`import Testing`，`@Test` 函数），不是 XCTest。
测试针对 Core 层的纯逻辑，不启动 App、不截图。
`IceShotUITests` 只放极少量冒烟用例。

### 数字与失修

**不要在文档里写会腐烂的数字**（测试数量、代码行数、版本号快照）。
要数字就说"跑 `Scripts/gate.sh` 看输出"。

改动测试数量或门禁行为时，顺手检查 `docs/roadmap.md` 的「测试」一行，同日更新。

---

## 路由表

按任务找该读哪个文档。**只读需要的那一节**，不要全文加载。

| 你要做的事 | 先读 |
| --- | --- |
| 第一次接触本仓库，或从 Web / Android 背景转过来 | [docs/onboarding-for-app-devs.md](docs/onboarding-for-app-devs.md) |
| 搞清楚项目能做什么 / 下一步规划 / 哪些明确不做 | [docs/roadmap.md](docs/roadmap.md) |
| 找某个功能在哪个目录、谁依赖谁、组合根在哪 | [docs/architecture.md](docs/architecture.md) |
| 写代码前确认工程规则：分层、命名、并发、错误处理 | [docs/engineering.md](docs/engineering.md) |
| 做任何界面、浮层、材质、颜色、动效、图标 | [docs/ui-guidelines.md](docs/ui-guidelines.md) |
| 改光标行为、查某个光标长什么样 | [docs/cursors.md](docs/cursors.md) |
| 改截取 / 标注 / 历史 / 贴图 / OCR 行为 | [docs/architecture.md](docs/architecture.md) 对应章节 |
| 改截图带壳（窗口壳） | [docs/screenshot-frame.md](docs/screenshot-frame.md) |
| 改设备壳（MacBook 外框） | [docs/screenshot-device-frame.md](docs/screenshot-device-frame.md) |
| 发版、改版本号、写 CHANGELOG | [docs/engineering.md](docs/engineering.md) 的发布一节 |

---

## 别做的事

- 别引入第三方依赖来解决系统框架能解决的事。
- 别手绘模糊或叠加自调透明度来伪造材质——材质交给系统（见 `GlassSurface`）。
- 别把截图内容、文件路径、窗口标题写进日志。
- 别为通过测试而放宽断言；先确认是实现错了还是测试错了。
