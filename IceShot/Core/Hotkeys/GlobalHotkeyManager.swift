import Carbon
import Observation

/// 全局快捷键注册与自定义（Carbon `RegisterEventHotKey`，无需辅助功能权限）。
///
/// 职责边界：
/// - 保存用户配置（虚拟键码 + 修饰键，存 `UserDefaults`，不存字符串描述）；
/// - 冲突检测：同 App 内重复、系统 / 常见 App 已占用、注册失败；
/// - 修改时立即尝试注册，失败回滚到旧组合，不静默失败。
@MainActor
@Observable
final class GlobalHotkeyManager {
    enum Hotkey: UInt32, CaseIterable, Identifiable {
        case region = 1
        case window = 2
        case fullScreen = 3
        case repeatRegion = 4
        case scroll = 5

        var id: UInt32 { rawValue }

        var displayName: String {
            switch self {
            case .region: return "区域截图"
            case .window: return "窗口截图"
            case .fullScreen: return "全屏截图"
            case .repeatRegion: return "重复上次区域"
            case .scroll: return "长截图"
            }
        }

        /// 默认组合（2026-10-19 起由 ⌃⌥ 改为 ⌘⇧；2026-10-21 窗口截图由 ⇧⌘2 改为 ⇧⌘K）。
        /// 区域 X、窗口 K、全屏 F、重复 R、长截 L：统一成字母，避开系统截图 ⇧⌘3/4/5/6、
        /// 各 App 的 ⇧⌘W「关闭窗口」与 ⇧⌘Q「退出登录」。
        var defaultBinding: HotkeyBinding {
            switch self {
            case .region:
                return HotkeyBinding(keyCode: UInt32(kVK_ANSI_X), modifiers: [.command, .shift])
            case .window:
                return HotkeyBinding(keyCode: UInt32(kVK_ANSI_K), modifiers: [.command, .shift])
            case .fullScreen:
                return HotkeyBinding(keyCode: UInt32(kVK_ANSI_F), modifiers: [.command, .shift])
            case .repeatRegion:
                return HotkeyBinding(keyCode: UInt32(kVK_ANSI_R), modifiers: [.command, .shift])
            case .scroll:
                return HotkeyBinding(keyCode: UInt32(kVK_ANSI_L), modifiers: [.command, .shift])
            }
        }
    }

    /// 修改快捷键的结果；调用方负责把拒绝原因展示给用户。
    enum UpdateResult: Equatable {
        case applied
        case rejectedDuplicate(Hotkey)
        case rejectedInvalid
        case rejectedRegistrationFailure
    }

    private struct StoredBindings: Codable {
        var bindings: [String: HotkeyBinding]
        var cleared: [UInt32]

        init(bindings: [String: HotkeyBinding] = [:], cleared: [UInt32] = []) {
            self.bindings = bindings
            self.cleared = cleared
        }
    }

    private static let storageKey = "globalHotkeyBindings.v1"
    private static let signature: OSType = 0x49435348 // "ICSH"

    private let coordinator: CaptureCoordinator
    private let defaults: UserDefaults

    private var eventHandler: EventHandlerRef?
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]

    /// 当前生效的组合；`nil` 表示该动作没有全局快捷键。
    private(set) var bindings: [Hotkey: HotkeyBinding] = [:]
    /// 注册失败（被其它 App 占用 / 系统拒绝）的动作。
    private(set) var registrationFailures: Set<Hotkey> = []
    /// 录制期间挂起注册，避免全局热键把录制按键抢走。
    private(set) var isSuspended = false
    /// 事件处理器安装失败的提示。
    private(set) var handlerError: String?

    init(coordinator: CaptureCoordinator, defaults: UserDefaults = .standard) {
        self.coordinator = coordinator
        self.defaults = defaults
        loadBindings()
    }

    // MARK: - 查询

    func binding(for hotkey: Hotkey) -> HotkeyBinding? {
        bindings[hotkey]
    }

    func label(for hotkey: Hotkey) -> String {
        bindings[hotkey]?.displayString ?? "未设置"
    }

    /// 当前组合的冲突提示；空数组表示没有问题。
    func warnings(for hotkey: Hotkey) -> [String] {
        var messages: [String] = []

        if registrationFailures.contains(hotkey) {
            let label = bindings[hotkey]?.displayString ?? ""
            messages.append("\(label) 注册失败，已被其它应用或系统占用；可换一个组合或清除。")
        }

        guard let binding = bindings[hotkey] else { return messages }

        if let other = duplicateOwner(of: binding, excluding: hotkey) {
            messages.append("与「\(other.displayName)」重复，同一组合只能绑定一个动作。")
        }

        if let conflict = binding.systemConflict {
            messages.append(conflict)
        }

        return messages
    }

    /// 注册失败的汇总提示（菜单栏 / 设置页顶部展示）。
    var registrationError: String? {
        if let handlerError {
            return handlerError
        }
        guard !registrationFailures.isEmpty else { return nil }
        let names = Hotkey.allCases
            .filter { registrationFailures.contains($0) }
            .map { "\($0.displayName) \(label(for: $0))" }
        return "全局快捷键 \(names.joined(separator: "、")) 注册失败，可能被其他应用占用。"
    }

    // MARK: - 生命周期

    func registerConfiguredHotkeys() {
        handlerError = nil
        guard installEventHandler() else {
            return
        }
        prepareActions()
        applyRegistrations()
    }

    func unregisterAll() {
        unregisterHotkeyRefs()
        if let eventHandler {
            _ = RemoveEventHandler(eventHandler)
        }
        eventHandler = nil
        actions.removeAll()
    }

    /// 录制期间挂起：先注销全部热键，按键才能到达设置窗口。
    func beginRecording() {
        guard !isSuspended else { return }
        isSuspended = true
        unregisterHotkeyRefs()
        registrationFailures.removeAll()
    }

    func endRecording() {
        guard isSuspended else { return }
        isSuspended = false
        applyRegistrations()
    }

    // MARK: - 修改

    @discardableResult
    func setBinding(_ binding: HotkeyBinding?, for hotkey: Hotkey) -> UpdateResult {
        // 修改配置必须走真实注册才能验证冲突；录制流程已先调用 `endRecording()`。
        endRecording()

        if let binding {
            guard binding.modifiers.isValidForGlobalHotkey
                || HotkeyKey.isFunctionKey(binding.keyCode) else {
                return .rejectedInvalid
            }
            if let other = duplicateOwner(of: binding, excluding: hotkey) {
                return .rejectedDuplicate(other)
            }
        }

        let previous = bindings[hotkey]
        bindings[hotkey] = binding
        persist()
        applyRegistrations()

        if binding != nil, registrationFailures.contains(hotkey) {
            bindings[hotkey] = previous
            persist()
            applyRegistrations()
            // 回滚后重新注册仍失败时，失败集合已由 applyRegistrations 刷新。
            return .rejectedRegistrationFailure
        }
        return .applied
    }

    @discardableResult
    func resetBinding(for hotkey: Hotkey) -> UpdateResult {
        setBinding(hotkey.defaultBinding, for: hotkey)
    }

    func resetAllBindings() {
        bindings = Dictionary(
            uniqueKeysWithValues: Hotkey.allCases.map { ($0, $0.defaultBinding) }
        )
        persist()
        applyRegistrations()
    }

    // MARK: - 内部

    private func duplicateOwner(of binding: HotkeyBinding, excluding hotkey: Hotkey) -> Hotkey? {
        Hotkey.allCases.first { $0 != hotkey && bindings[$0] == binding }
    }

    private func prepareActions() {
        actions[Hotkey.region.rawValue] = { [weak self] in
            guard let self else { return }
            Task {
                await self.coordinator.startRegionCapture(delay: .milliseconds(250))
            }
        }
        actions[Hotkey.window.rawValue] = { [weak self] in
            guard let self else { return }
            Task {
                await self.coordinator.startWindowCapture(delay: .milliseconds(250))
            }
        }
        actions[Hotkey.fullScreen.rawValue] = { [weak self] in
            guard let self else { return }
            Task {
                await self.coordinator.startFullScreenCapture(delay: .milliseconds(250))
            }
        }
        actions[Hotkey.repeatRegion.rawValue] = { [weak self] in
            guard let self else { return }
            Task {
                await self.coordinator.startRepeatLastRegion(delay: .milliseconds(250))
            }
        }
        actions[Hotkey.scroll.rawValue] = { [weak self] in
            guard let self else { return }
            Task {
                await self.coordinator.startScrollCapture(delay: .milliseconds(250))
            }
        }
    }

    /// 按当前配置整体重建热键注册，并刷新失败集合。
    private func applyRegistrations() {
        guard !isSuspended else { return }
        unregisterHotkeyRefs()
        registrationFailures.removeAll()

        for hotkey in Hotkey.allCases {
            guard let binding = bindings[hotkey] else { continue }
            guard register(hotkey, binding: binding) else {
                registrationFailures.insert(hotkey)
                continue
            }
        }
    }

    private func register(_ hotkey: Hotkey, binding: HotkeyBinding) -> Bool {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            binding.keyCode,
            Self.carbonFlags(for: binding.modifiers),
            EventHotKeyID(signature: Self.signature, id: hotkey.rawValue),
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &ref
        )
        guard status == noErr, let ref else {
            return false
        }
        hotKeyRefs.append(ref)
        return true
    }

    private func unregisterHotkeyRefs() {
        for ref in hotKeyRefs {
            _ = UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
    }

    private static func carbonFlags(for modifiers: HotkeyModifiers) -> UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains(.command) { flags |= UInt32(cmdKey) }
        if modifiers.contains(.option) { flags |= UInt32(optionKey) }
        if modifiers.contains(.control) { flags |= UInt32(controlKey) }
        if modifiers.contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
    }

    fileprivate func handle(hotKeyID: UInt32) {
        actions[hotKeyID]?()
    }

    private func installEventHandler() -> Bool {
        if eventHandler != nil {
            return true
        }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            iceShotHotKeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard status == noErr else {
            handlerError = "无法监听全局快捷键（错误码 \(status)）。"
            return false
        }
        return true
    }

    // MARK: - 持久化

    private func loadBindings() {
        var restored: [Hotkey: HotkeyBinding] = [:]
        let stored = loadStoredBindings()

        for hotkey in Hotkey.allCases {
            if let binding = stored.bindings[String(hotkey.rawValue)] {
                restored[hotkey] = binding
            } else if stored.cleared.contains(hotkey.rawValue) {
                restored[hotkey] = nil
            } else {
                restored[hotkey] = hotkey.defaultBinding
            }
        }
        bindings = restored
    }

    private func loadStoredBindings() -> StoredBindings {
        guard let data = defaults.data(forKey: Self.storageKey) else {
            return StoredBindings()
        }
        return (try? JSONDecoder().decode(StoredBindings.self, from: data)) ?? StoredBindings()
    }

    private func persist() {
        var stored = StoredBindings()
        for hotkey in Hotkey.allCases {
            guard let binding = bindings[hotkey] else {
                stored.cleared.append(hotkey.rawValue)
                continue
            }
            guard binding != hotkey.defaultBinding else { continue }
            stored.bindings[String(hotkey.rawValue)] = binding
        }

        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

private nonisolated func iceShotHotKeyHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else {
        return noErr
    }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else {
        return status
    }

    let manager = Unmanaged<GlobalHotkeyManager>
        .fromOpaque(userData)
        .takeUnretainedValue()
    let id = hotKeyID.id
    Task { @MainActor in
        manager.handle(hotKeyID: id)
    }
    return noErr
}
