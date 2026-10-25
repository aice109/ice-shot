import Carbon
import Foundation
import Testing
@testable import IceShot

@MainActor
struct HotkeyBindingTests {
    private let suiteName = "IceShotTests.HotkeyBindings"

    private func makeDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeManager(defaults: UserDefaults) -> GlobalHotkeyManager {
        GlobalHotkeyManager(coordinator: CaptureCoordinator(history: nil), defaults: defaults)
    }

    @Test func defaultBindingsUseCommandShift() {
        let manager = makeManager(defaults: makeDefaults())
        defer { manager.unregisterAll() }

        #expect(manager.label(for: .region) == "⇧⌘X")
        #expect(manager.label(for: .window) == "⇧⌘K")
        #expect(manager.label(for: .fullScreen) == "⇧⌘F")
        #expect(manager.label(for: .repeatRegion) == "⇧⌘R")
    }

    @Test func modifierSymbolUsesSystemOrder() {
        let binding = HotkeyBinding(
            keyCode: UInt32(HotkeyKey.codeW),
            modifiers: [.command, .shift, .control, .option]
        )
        #expect(binding.modifiers.symbol == "⌃⌥⇧⌘")
        #expect(binding.displayString == "⌃⌥⇧⌘W")
    }

    @Test func systemConflictsAreReported() {
        let windowConflict = HotkeyBinding(
            keyCode: UInt32(HotkeyKey.codeW),
            modifiers: [.command, .shift]
        )
        #expect(windowConflict.systemConflict != nil)

        let safe = HotkeyBinding(
            keyCode: UInt32(HotkeyKey.codeW),
            modifiers: [.command, .option]
        )
        #expect(safe.systemConflict == nil)
    }

    @Test func modifiersRequireCommandControlOrOption() {
        #expect(!HotkeyModifiers([.shift]).isValidForGlobalHotkey)
        #expect(!HotkeyModifiers([]).isValidForGlobalHotkey)
        #expect(HotkeyModifiers([.command, .shift]).isValidForGlobalHotkey)
        #expect(HotkeyModifiers([.option]).isValidForGlobalHotkey)
    }

    @Test func duplicateBindingIsRejected() {
        let manager = makeManager(defaults: makeDefaults())
        defer { manager.unregisterAll() }

        let duplicate = HotkeyBinding(
            keyCode: UInt32(kVK_ANSI_K),
            modifiers: [.command, .shift]
        )
        #expect(manager.setBinding(duplicate, for: .region) == .rejectedDuplicate(.window))
        // 被拒绝后原组合保持不变。
        #expect(manager.label(for: .region) == "⇧⌘X")
    }

    @Test func bindingWithoutModifiersIsRejected() {
        let manager = makeManager(defaults: makeDefaults())
        defer { manager.unregisterAll() }

        let plain = HotkeyBinding(keyCode: UInt32(HotkeyKey.codeW), modifiers: [.shift])
        #expect(manager.setBinding(plain, for: .region) == .rejectedInvalid)
        #expect(manager.label(for: .region) == "⇧⌘X")
    }

    @Test func clearedAndCustomBindingsPersist() {
        let defaults = makeDefaults()

        let manager = makeManager(defaults: defaults)
        manager.unregisterAll()
        manager.setBinding(nil, for: .region)
        let custom = HotkeyBinding(keyCode: UInt32(HotkeyKey.codeQ), modifiers: [.control, .option])
        #expect(manager.setBinding(custom, for: .repeatRegion) == .applied)
        manager.unregisterAll()

        let restored = makeManager(defaults: defaults)
        defer { restored.unregisterAll() }
        #expect(restored.bindings[.region] == nil)
        #expect(restored.label(for: .region) == String(localized: "未设置"))
        #expect(restored.bindings[.repeatRegion] == custom)
        // 未改动的动作仍取默认值。
        #expect(restored.label(for: .fullScreen) == "⇧⌘F")
    }

    @Test func occupiedCombinationRollsBackToPreviousBinding() {
        let occupied = HotkeyBinding(
            keyCode: UInt32(kVK_ANSI_9),
            modifiers: [.control, .option, .shift]
        )

        // 同进程内先占用这个组合，另一个管理器再注册同一组合必然失败。
        let first = makeManager(defaults: makeDefaults())
        first.unregisterAll()
        #expect(first.setBinding(occupied, for: .region) == .applied)
        defer { first.unregisterAll() }

        let second = makeManager(defaults: makeDefaults())
        second.unregisterAll()
        let previous = second.binding(for: .repeatRegion)
        #expect(previous != nil)

        #expect(second.setBinding(occupied, for: .repeatRegion) == .rejectedRegistrationFailure)
        #expect(second.binding(for: .repeatRegion) == previous)
        second.unregisterAll()
    }

    @Test func resetAllRestoresDefaults() {
        let defaults = makeDefaults()
        let manager = makeManager(defaults: defaults)
        manager.unregisterAll()

        manager.setBinding(nil, for: .fullScreen)
        manager.resetAllBindings()
        #expect(manager.label(for: .fullScreen) == "⇧⌘F")
        manager.unregisterAll()
    }
}
