import Darwin
import Foundation
import OSLog

extension ISO8601DateFormatter {
    /// 取证用的时间戳格式：精确到毫秒，便于和系统日志对齐。
    static let iceShotFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

/// 卡死取证：把关键路径的时间戳与主线程栈**先落盘**，卡死之后再来取。
///
/// 背景：截图浮层是 `.screenSaver` 层级的全屏面板，一旦卡死用户既打不开终端、
/// 也无法切窗口，任何「卡死时手动抓 `sample`」的建议都是废话。
/// 所以这里改变取证方向——**平时就写**，出事之后再去读：
///
/// - 每个标记点同步追加一行到 `<临时目录>/IceShotDiag/trace.log`；
/// - 启动一个后台线程守护：主线程超过 `stallThreshold` 没有心跳，就抓一次主线程栈
///   写进同一个目录。抓栈用的是 `thread_get_state`，**不经过被卡住的那条线程**，
///   因此卡在多深都能出结果。
///
/// 隐私：只记录**阶段名与耗时**，绝不写截图内容、窗口标题、其他用户数据。
///
/// ## 开关
///
/// 整个模块受编译条件 `ICESHOT_HANG_TRACE` 控制，**默认关闭**：
///
/// - 关闭时：本文件里的所有实现与守护线程都不编译，`isEnabled` 是字面量 `false`，
///   调用点（`HangTrace.mark(...)`）被优化器整条消除，**零运行时开销、零文件写入**；
/// - 打开时：`HangTrace` 真正落盘并启动 watchdog。
///
/// 打开方式（临时排查用，别提交开关状态）：
///
/// ```bash
/// # 命令行：追加编译条件
/// ICESHOT_HANG_TRACE=1 Scripts/gate.sh
/// # 或在 Xcode：Target → Build Settings → Swift Compiler → Other Swift Flags 加 -DICESHOT_HANG_TRACE
/// ```
///
/// `gate.sh` 已支持通过环境变量透传（见脚本里的 `ICESHOT_HANG_TRACE`）。
enum HangTrace {
    /// 编译期开关：只有定义了 `ICESHOT_HANG_TRACE` 才为真。
    ///
    /// 用 `#if` 而不是读环境变量：环境变量是运行时的，会让「关闭」仍然带着
    /// 全部的字符串拼接与调用开销，也就谈不上“关掉”。
    static let isEnabled: Bool = {
        #if ICESHOT_HANG_TRACE
        return true
        #else
        return false
        #endif
    }()

    /// 主线程多久没心跳算「卡住」。定时器 1 s 一跳，3 s 容错抖动。
    static let stallThreshold: TimeInterval = 4

    /// 采样间隔：1 s 一跳，开销可忽略。
    static let heartbeatInterval: TimeInterval = 1

    /// 保留最近多少条标记点，避免长期运行把文件写大。
    static let maxLineCount = 4000

    /// 取证目录（App 自己的沙盒容器内）。
    ///
    /// 沙盒 App 的 `temporaryDirectory` / `libraryDirectory` 都被重定向进容器，
    /// 所以这里写什么都落在容器里。**容器本身对终端是 TCC 保护的**（`ls` 会得到
    /// `Operation not permitted`），因此光写文件不够——必须配合 `copyDiagnostics(to:)`
    /// 这条「App 自己把文件拷到你选的位置」的通道。
    static var directory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("IceShotDiag", isDirectory: true)
    }

    static var traceFile: URL {
        directory.appendingPathComponent("trace.log")
    }

    /// 卡死时抓下来的主线程栈。
    static var stackFile: URL {
        directory.appendingPathComponent("stall-stack.txt")
    }

    #if ICESHOT_HANG_TRACE
    private static let logger = Logger(
        subsystem: "com.aice109.IceShot.bundle",
        category: "hang"
    )
    #endif

    /// 记一个阶段标记。`detail` 里**不要**放截图内容或用户数据。
    static func mark(_ stage: String, _ detail: @autoclosure () -> String = "") {
        guard isEnabled else { return }
        let detailText = detail()
        let line = detailText.isEmpty
            ? "\(timestamp()) \(stage)"
            : "\(timestamp()) \(stage) | \(detailText)"
        append(line)
        #if ICESHOT_HANG_TRACE
        logger.debug("[\(stage, privacy: .public)] \(detailText, privacy: .public)")
        #endif
    }

    /// 记录一次「卡住了多久」的耗时点，便于事后看是哪一步慢。
    ///
    /// - Parameter startedAt: `ProcessInfo.processInfo.systemUptime`。
    static func markDuration(_ stage: String, from startedAt: TimeInterval) {
        guard isEnabled else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        mark(stage, String(format: "耗时 %.1f ms", elapsed * 1000))
    }

    /// 启动后台守护。重复调用安全（内部去重）。
    ///
    /// 必须在主线程调用一次（`AppDelegate` 启动时）。
    @MainActor
    static func startWatchdog() {
        #if ICESHOT_HANG_TRACE
        HangWatchdog.shared.start()
        mark("watchdog.started", "trace=\(traceFile.path)")
        #endif
    }

    // MARK: - 写入

    /// 追加一行并顺带裁剪文件。
    ///
    /// 用 `append` 而不是「读-改-写」：卡死时最不能做的就是让取证自己变慢。
    static func append(_ line: String) {
        guard isEnabled else { return }
        guard let data = (line + "\n").data(using: .utf8) else { return }

        let manager = FileManager.default
        let url = traceFile
        if !manager.fileExists(atPath: url.path) {
            try? manager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            manager.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            // 写不进去必须留痕：否则「取证文件不存在」会被误判成「程序没跑起来」。
            #if ICESHOT_HANG_TRACE
            logger.error("trace 打不开：\(url.path, privacy: .public)")
            #endif
            return
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            #if ICESHOT_HANG_TRACE
            logger.error("trace 写入失败：\(error.localizedDescription, privacy: .public)")
            #endif
            return
        }
        trimIfNeeded(manager: manager, url: url)
    }

    /// 文件超过上限就只留尾部：取证文件不该无限增长。
    ///
    /// **按真实行数判定，不按"平均行长"估算**。之前用 `字节数 > maxLineCount * 40`
    /// 估行数，遇上行很短的标记（`mark("a")` 只有几个字节）就永远达不到阈值，
    /// 文件会无界增长——取证工具自己失控是不可接受的。
    /// 字节数只作为第二道闸：行数数不动（超大单行）时仍然会裁。
    private static func trimIfNeeded(manager: FileManager, url: URL) {
        let attributes = try? manager.attributesOfItem(atPath: url.path)
        guard let byteCount = attributes?[.size] as? Int else { return }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)

        let exceedsLines = lines.count > maxLineCount
        // 兜底：单行特别长时，字节数也能触发裁剪（一个标记不该有几十 KB）。
        let exceedsBytes = byteCount > maxLineCount * 64
        guard exceedsLines || exceedsBytes else { return }

        let kept = lines.suffix(maxLineCount / 2).joined(separator: "\n")
        try? kept.write(to: url, atomically: true, encoding: .utf8)
    }

    /// 覆盖写主线程栈（只留最近一次卡死的那份）。
    static func writeStallReport(_ text: String) {
        guard isEnabled else { return }
        let manager = FileManager.default
        try? manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try? text.write(to: stackFile, atomically: true, encoding: .utf8)
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter.iceShotFormatter.string(from: Date())
    }
}

#if ICESHOT_HANG_TRACE

/// 后台守护线程：主线程超时没心跳就抓栈。
///
/// 刻意**不用** `DispatchSourceTimer` / `Timer`：它们都跑在主队列上，
/// 主线程一旦卡住它们就跟着停，正好在需要取证的时候失灵。
/// 这里用一条裸 `Thread` + `usleep` 轮询，与被卡住的主线程完全解耦。
private final class HangWatchdog {
    static let shared = HangWatchdog()

    private let lock = NSLock()
    private var started = false
    /// 守护线程必须被**强引用**住。
    ///
    /// `Thread` 只被局部变量持有的情况下一旦线程体仍在跑，Foundation 通常还会保活它，
    /// 但这依赖实现细节；显式持有是零成本的正确做法。
    private var watchdogThread: Thread?
    /// 主线程最后一次心跳的 `systemUptime`；主线程写、守护线程读。
    private var lastHeartbeat: TimeInterval = 0
    /// 本次卡死是否已经抓过栈，避免每秒刷一次。
    private var didCapture = false

    func start() {
        lock.lock()
        let alreadyStarted = started
        started = true
        lock.unlock()
        guard !alreadyStarted else { return }

        lastHeartbeat = ProcessInfo.processInfo.systemUptime

        // 不用 `[weak self]`：`shared` 是单例，线程本身也不需要它被释放；
        // 弱引用会让「线程因 self 为 nil 而静默退出」成为另一个静默失败点。
        let thread = Thread {
            HangWatchdog.shared.run()
        }
        thread.name = "IceShot.HangWatchdog"
        thread.qualityOfService = .utility
        thread.start()
        watchdogThread = thread

        // 主线程侧的心跳：用主队列上的重复任务。主线程卡住它就自然停跳，
        // 正好成为「卡住了」的判据。
        scheduleHeartbeat()
    }

    private func scheduleHeartbeat() {
        DispatchQueue.main.asyncAfter(deadline: .now() + HangTrace.heartbeatInterval) {
            self.beat()
            self.scheduleHeartbeat()
        }
    }

    private func beat() {
        lock.lock()
        lastHeartbeat = ProcessInfo.processInfo.systemUptime
        didCapture = false
        lock.unlock()
    }

    private func run() {
        while true {
            Thread.sleep(forTimeInterval: HangTrace.heartbeatInterval)

            lock.lock()
            let last = lastHeartbeat
            let alreadyCaptured = didCapture
            lock.unlock()

            let stalledFor = ProcessInfo.processInfo.systemUptime - last
            guard stalledFor >= HangTrace.stallThreshold, !alreadyCaptured else { continue }

            lock.lock()
            didCapture = true
            lock.unlock()

            let report = MainThreadSampler.sample(
                stalledFor: stalledFor,
                traceTail: HangTrace.lastTraceLines(limit: 40)
            )
            HangTrace.writeStallReport(report)
            HangTrace.mark("watchdog.captured", "stalledFor=\(Int(stalledFor))s")
        }
    }
}

#endif

#if ICESHOT_HANG_TRACE

/// 主线程栈采样：从**当前线程**去看主线程的寄存器与回溯。
///
/// 只能用 `thread_get_state` + 帧指针回溯，不能用 `backtrace()`（它采的是调用线程自己）。
/// 现代 macOS 上 ARM64 帧指针默认保留，回溯足够定位「卡在哪一层系统调用」。
enum MainThreadSampler {
    /// 主线程的 `mach` 端口。
    ///
    /// **不能**在这里调 `mach_thread_self()`：那返回的是**调用者自己**的端口。
    /// 采样器跑在守护线程上，用它去 `thread_get_state` 只会采到守护线程的栈，
    /// 采出来的是「watchdog 自己在睡觉」——最无用的结果。
    /// 成员初始值在进程启动（主线程）时求值，那时拿到的才是主线程。
    private static let mainThreadPort: thread_t = mach_thread_self()

    static func sample(stalledFor: TimeInterval, traceTail: [String]) -> String {
        var lines: [String] = []
        lines.append("IceShot 主线程卡死报告")
        lines.append("时间：\(ISO8601DateFormatter.iceShotFormatter.string(from: Date()))")
        lines.append(String(format: "主线程已阻塞：%.1f 秒", stalledFor))
        lines.append("")
        lines.append("== 主线程栈（由帧指针回溯，可能不完整）==")
        lines.append(contentsOf: frames())
        lines.append("")
        lines.append("== 卡死前的最后阶段标记 ==")
        lines.append(contentsOf: traceTail)
        lines.append("")
        lines.append("== 怎么处理 ==")
        lines.append("把整个文件发给我即可；它在：\(HangTrace.stackFile.path)")
        return lines.joined(separator: "\n")
    }

    /// 从主线程寄存器出发沿帧指针回溯，把每层 PC 符号化成 `镜像名 + 偏移`。
    ///
    /// 寄存器布局按架构分支：`arm_thread_state64_t` / `x86_thread_state64_t` 同名不同构。
    /// 这里只取 pc / fp / sp 三个值，回溯逻辑共用。
    private static func frames() -> [String] {
        guard let registers = readMainThreadRegisters() else {
            return ["（无法读取主线程寄存器）"]
        }
        let pc = registers.pc
        var fp = registers.fp
        let sp = registers.sp
        var addresses: [UInt64] = [pc]

        // 帧指针回溯：fp 指向 [上一帧 fp, 返回地址]。
        var currentPC = pc
        for _ in 0..<96 {
            guard fp >= sp, fp != 0, fp % 8 == 0, fp < 0x0000_7FFF_FFFF_FFFF else { break }
            guard let header = UnsafeRawPointer(bitPattern: UInt(fp)) else { break }
            let nextFP = header.load(as: UInt64.self)
            let returnAddress = header.load(fromByteOffset: 8, as: UInt64.self)
            guard returnAddress != 0 else { break }
            if returnAddress != currentPC {
                addresses.append(returnAddress)
                currentPC = returnAddress
            }
            guard nextFP > fp else { break }
            fp = nextFP
        }

        return addresses.enumerated().map { index, address in
            "[\(index)] \(symbolize(address))"
        }
    }

    /// 主线程的关键寄存器。
    private struct Registers {
        let pc: UInt64
        let fp: UInt64
        let sp: UInt64
    }

    #if arch(arm64)
    private static func readMainThreadRegisters() -> Registers? {
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &state) { pointer in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { rebound in
                thread_get_state(
                    mainThreadPort,
                    thread_state_flavor_t(ARM_THREAD_STATE64),
                    rebound,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Registers(
            pc: UInt64(state.__pc),
            fp: UInt64(state.__fp),
            sp: UInt64(state.__sp)
        )
    }
    #elseif arch(x86_64)
    private static func readMainThreadRegisters() -> Registers? {
        var state = x86_thread_state64_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<x86_thread_state64_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &state) { pointer in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { rebound in
                thread_get_state(
                    mainThreadPort,
                    thread_state_flavor_t(x86_THREAD_STATE64),
                    rebound,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Registers(
            pc: UInt64(state.__rip),
            fp: UInt64(state.__rbp),
            sp: UInt64(state.__rsp)
        )
    }
    #else
    private static func readMainThreadRegisters() -> Registers? {
        nil
    }
    #endif

    /// 用 `dladdr` 把地址翻译成「镜像名 + 偏移」；符号化失败就只给地址。
    private static func symbolize(_ address: UInt64) -> String {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: UInt(address)), &info) != 0 else {
            return String(format: "0x%llx", address)
        }
        let library = info.dli_fname.map { URL(fileURLWithPath: String(cString: $0)).lastPathComponent }
            ?? "?"
        let offset = address - UInt64(UInt(bitPattern: info.dli_fbase))
        if let symbol = info.dli_sname {
            let base = UInt64(UInt(bitPattern: info.dli_saddr))
            return String(
                format: "%@  %@ + %llu  (镜像 %@ + %llu)",
                String(format: "0x%llx", address),
                String(cString: symbol),
                address - base,
                library,
                offset
            )
        }
        return String(format: "0x%llx  (%@ + %llu)", address, library, offset)
    }
}

#endif

#if ICESHOT_HANG_TRACE

extension HangTrace {
    /// 把取证文件拷到用户选定的目录，返回写出的文件名。
    ///
    /// 为什么需要它：沙盒容器的 `Data/` 受 TCC 保护，`ls` / `cat` 都是
    /// `Operation not permitted`——文件就在那里，但用户拿不出来。
    /// 用户通过 `NSOpenPanel` 亲手选一个目录，App 就有了写它的授权，
    /// 这是**唯一**不要求用户操作终端、也不要求任何系统权限的取回方式。
    ///
    /// 只拷取证文件（阶段标记 + 主线程栈），不含截图内容。
    @MainActor
    static func export(to directory: URL) throws -> [String] {
        let manager = FileManager.default
        var written: [String] = []
        for source in [traceFile, stackFile] where manager.fileExists(atPath: source.path) {
            let destination = directory.appendingPathComponent(source.lastPathComponent)
            try? manager.removeItem(at: destination)
            try manager.copyItem(at: source, to: destination)
            written.append(source.lastPathComponent)
        }
        return written
    }

    /// 取证目录是否存在、有没有内容——排查时先问这个。
    static var hasDiagnostics: Bool {
        let manager = FileManager.default
        return manager.fileExists(atPath: traceFile.path)
            || manager.fileExists(atPath: stackFile.path)
    }

    /// 读出文件末尾若干行，附在卡死报告里，形成「卡在哪一步 + 当时在做什么」的完整证据链。
    static func lastTraceLines(limit: Int) -> [String] {
        guard isEnabled,
              let content = try? String(contentsOf: traceFile, encoding: .utf8) else {
            return ["（没有标记点）"]
        }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else { return ["（没有标记点）"] }
        return lines.suffix(limit).map(String.init)
    }
}

#else

// 开关关闭时的空实现：调用点（菜单栏的导出入口等）无需包 `#if`。
extension HangTrace {
    /// 没有取证文件，导出入口自然也不会出现。
    static var hasDiagnostics: Bool { false }

    /// 开关关闭时没有可导出的内容；返回空数组让调用方给出「无可导出」提示。
    @MainActor
    static func export(to directory: URL) throws -> [String] {
        []
    }

    static func lastTraceLines(limit: Int) -> [String] {
        []
    }
}

#endif
