import SwiftUI

/// App 入口：以菜单栏为主界面。
///
/// 历史记录与设置是独立窗口，按需打开；依赖（协调器 / 快捷键 / 历史库）
/// 由 `AppDelegate` 统一装配，Scene 只做组装，不在这里创建业务对象。
@main
struct IceShotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    /// 延时截图的秒数：菜单只留一个入口，具体秒数在设置里配。
    @AppStorage(CapturePreferences.countdownSecondsKey)
    private var countdownSeconds = CapturePreferences.defaultCountdownSeconds

    private var coordinator: CaptureCoordinator {
        appDelegate.coordinator
    }

    private var hotkeys: GlobalHotkeyManager {
        appDelegate.hotkeys
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                coordinator: coordinator,
                hotkeys: appDelegate.hotkeys,
                library: appDelegate.library,
                pins: appDelegate.pins
            )
        } label: {
            Image("MenuBarIcon")
                .renderingMode(.template)
                .accessibilityLabel("IceShot")
        }
        // `.window` 样式：面板内可以用原生控件排版，而不是只有菜单项。
        .menuBarExtraStyle(.window)
        .commands {
            // 菜单标题与条目用 `LocalizedStringKey` 字面量，中英文案在
            // `zh-Hans.lproj` / `en.lproj` 的 `Localizable.strings` 里给出。
            // 这里的字面量是**中文原文**（开发语言），英文由本地化表覆盖。
            CommandMenu("截图") {
                // 第一组：最常用的三种截取方式。
                Button("区域截图") {
                    Task {
                        await coordinator.startRegionCapture(delay: .milliseconds(250))
                    }
                }
                .menuHotkey(HotkeyMenuShortcut(hotkeys.binding(for: .region)))
                .disabled(coordinator.isBusy)

                Button("窗口截图") {
                    Task {
                        await coordinator.startWindowCapture(delay: .milliseconds(250))
                    }
                }
                .menuHotkey(HotkeyMenuShortcut(hotkeys.binding(for: .window)))
                .disabled(coordinator.isBusy)

                Button("全屏截图（当前显示器）") {
                    Task {
                        await coordinator.startFullScreenCapture(delay: .milliseconds(250))
                    }
                }
                .menuHotkey(HotkeyMenuShortcut(hotkeys.binding(for: .fullScreen)))
                .disabled(coordinator.isBusy)

                Divider()

                // 第二组：进阶与重复上一次。
                Button("长截图") {
                    Task {
                        await coordinator.startScrollCapture(delay: .milliseconds(250))
                    }
                }
                .menuHotkey(HotkeyMenuShortcut(hotkeys.binding(for: .scroll)))
                .disabled(coordinator.isBusy)

                Button("全屏截图（全部显示器）") {
                    Task {
                        await coordinator.startAllDisplaysCapture(delay: .milliseconds(250))
                    }
                }
                .disabled(coordinator.isBusy)

                Button("重复上次区域") {
                    Task {
                        await coordinator.startRepeatLastRegion(delay: .milliseconds(250))
                    }
                }
                .menuHotkey(HotkeyMenuShortcut(hotkeys.binding(for: .repeatRegion)))
                .disabled(coordinator.isBusy)

                Divider()

                // 延时截图：原来 4 模式 × 3 秒数 = 12 项，菜单里最长的一段噪音。
                // 现在只留一个入口，秒数在设置里配一次。
                Button("延时截图") {
                    Task {
                        await coordinator.startRegionCapture(
                            delay: .milliseconds(250),
                            countdownSeconds: countdownSeconds
                        )
                    }
                }
                .disabled(coordinator.isBusy)

                Divider()

                Button("取消当前截图") {
                    coordinator.cancelCurrentSelection()
                }
                .disabled(!coordinator.isSelecting)
            }

            // 文件菜单：只保留「打开历史记录」与「关闭」，去掉无意义的 `新建`。
            CommandGroup(replacing: .newItem) {
                Button("打开历史记录") {
                    openWindow(id: "library")
                    NSApplication.shared.activate()
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            // `视图` 菜单对截图工具没有意义（没有缩放、侧边栏、隐藏状栏），整个移除。
            CommandGroup(replacing: .toolbar) {}
            CommandGroup(replacing: .sidebar) {}

            // `帮助` 里原来是一条指向不存在的帮助书的条目，换成真正的入口。
            CommandGroup(replacing: .help) {
                Button("IceShot 在 GitHub 上开源") {
                    NSWorkspace.shared.open(ProjectLinks.repository)
                }
            }
        }

        // `.suppressed`：启动时不主动弹历史窗口；用户从菜单打开时才创建。
        Window(String(localized: "历史记录"), id: "library") {
            LibraryWindowView(
                library: appDelegate.library,
                container: appDelegate.modelContainer,
                editor: appDelegate.editor,
                pins: appDelegate.pins,
                feedback: appDelegate.feedback,
                startupError: appDelegate.startupError
            )
        }
        .defaultSize(width: 980, height: 660)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView(
                coordinator: coordinator,
                hotkeys: appDelegate.hotkeys,
                library: appDelegate.library
            )
        }
        .restorationBehavior(.disabled)
    }
}
