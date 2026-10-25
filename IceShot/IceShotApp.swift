import SwiftUI

/// App 入口：以菜单栏为主界面。
///
/// 历史记录与设置是独立窗口，按需打开；依赖（协调器 / 快捷键 / 历史库）
/// 由 `AppDelegate` 统一装配，Scene 只做组装，不在这里创建业务对象。
@main
struct IceShotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

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
            CommandMenu("截图") {
                Button("区域截图") {
                    Task {
                        await coordinator.startRegionCapture(delay: .milliseconds(250))
                    }
                }
                .menuHotkey(HotkeyMenuShortcut(hotkeys.binding(for: .region)))
                .disabled(coordinator.isBusy)

                Button("重复上次区域") {
                    Task {
                        await coordinator.startRepeatLastRegion(delay: .milliseconds(250))
                    }
                }
                .menuHotkey(HotkeyMenuShortcut(hotkeys.binding(for: .repeatRegion)))
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

                Menu("延时截图") {
                    Button("区域 · 3 秒") {
                        Task {
                            await coordinator.startRegionCapture(
                                delay: .milliseconds(250),
                                countdownSeconds: 3
                            )
                        }
                    }
                    Button("区域 · 5 秒") {
                        Task {
                            await coordinator.startRegionCapture(
                                delay: .milliseconds(250),
                                countdownSeconds: 5
                            )
                        }
                    }
                    Button("区域 · 10 秒") {
                        Task {
                            await coordinator.startRegionCapture(
                                delay: .milliseconds(250),
                                countdownSeconds: 10
                            )
                        }
                    }

                    Divider()

                    Button("全屏 · 3 秒") {
                        Task {
                            await coordinator.startFullScreenCapture(
                                delay: .milliseconds(250),
                                countdownSeconds: 3
                            )
                        }
                    }
                    Button("全屏 · 5 秒") {
                        Task {
                            await coordinator.startFullScreenCapture(
                                delay: .milliseconds(250),
                                countdownSeconds: 5
                            )
                        }
                    }
                    Button("全屏 · 10 秒") {
                        Task {
                            await coordinator.startFullScreenCapture(
                                delay: .milliseconds(250),
                                countdownSeconds: 10
                            )
                        }
                    }

                    Divider()

                    Button("窗口 · 3 秒") {
                        Task {
                            await coordinator.startWindowCapture(
                                delay: .milliseconds(250),
                                countdownSeconds: 3
                            )
                        }
                    }
                    Button("窗口 · 5 秒") {
                        Task {
                            await coordinator.startWindowCapture(
                                delay: .milliseconds(250),
                                countdownSeconds: 5
                            )
                        }
                    }
                    Button("窗口 · 10 秒") {
                        Task {
                            await coordinator.startWindowCapture(
                                delay: .milliseconds(250),
                                countdownSeconds: 10
                            )
                        }
                    }

                    Divider()

                    Button("全部显示器 · 3 秒") {
                        Task {
                            await coordinator.startAllDisplaysCapture(
                                delay: .milliseconds(250),
                                countdownSeconds: 3
                            )
                        }
                    }
                    Button("全部显示器 · 5 秒") {
                        Task {
                            await coordinator.startAllDisplaysCapture(
                                delay: .milliseconds(250),
                                countdownSeconds: 5
                            )
                        }
                    }
                    Button("全部显示器 · 10 秒") {
                        Task {
                            await coordinator.startAllDisplaysCapture(
                                delay: .milliseconds(250),
                                countdownSeconds: 10
                            )
                        }
                    }
                }
                .disabled(coordinator.isBusy)

                Divider()

                Button("取消当前截图") {
                    coordinator.cancelCurrentSelection()
                }
                .disabled(!coordinator.isSelecting)
            }

            CommandGroup(after: .newItem) {
                Button("打开历史记录") {
                    openWindow(id: "library")
                    NSApplication.shared.activate()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }

        // `.suppressed`：启动时不主动弹历史窗口；用户从菜单打开时才创建。
        Window("历史记录", id: "library") {
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
