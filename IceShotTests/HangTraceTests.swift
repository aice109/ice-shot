import Foundation
import Testing
@testable import IceShot

/// 卡死取证自身的可靠性：它是排查工具，不能反倒成为问题来源。
///
/// 这里只测**不依赖主线程卡死**的部分（写入、裁剪、行读取）——
/// 真正的抓栈需要主线程真被占住，无法在单测里构造。
///
/// 为什么测的是 `TraceWorkspace` 而不是直接调 `HangTrace`：`HangTrace` 写的是**进程级共享**
/// 的一个路径，而 Swift Testing 默认并行跑用例——几个用例交错写同一份文件，
/// 断言必然互相踩（实测如此）。校验逻辑抽到可注入目录的类型里，各测各的。
struct HangTraceTests {
    @Test("开关的两种状态都自洽：关闭时不落盘，打开时落盘")
    func switchMatchesContract() {
        #if ICESHOT_HANG_TRACE
        // 打开：真实实现必须写文件，否则「打开了却没有日志」会被误判成没卡死。
        #expect(HangTrace.isEnabled)
        HangTrace.mark("switch.test")
        #expect(
            FileManager.default.fileExists(atPath: HangTrace.traceFile.path),
            "开关打开时应写出 trace.log"
        )
        #else
        // 关闭：不建目录、不写文件，调用点完全无副作用。
        #expect(!HangTrace.isEnabled)
        #expect(!HangTrace.hasDiagnostics)
        #expect(HangTrace.lastTraceLines(limit: 5).isEmpty)
        #endif
    }

    @Test("标记会落盘，并且能按顺序读回")
    func markWritesAndReadsBack() {
        let workspace = makeWorkspace()

        workspace.trace.mark("alpha", "value=1")
        workspace.trace.mark("beta")

        let lines = workspace.trace.lastLines(limit: 10)
        #expect(lines.count == 2)
        #expect(lines[0].contains("alpha"))
        #expect(lines[0].contains("value=1"))
        #expect(lines[1].contains("beta"))
    }

    @Test("最后 N 行只取末尾，超出部分丢弃")
    func lastLinesKeepsTailOnly() {
        let workspace = makeWorkspace()

        for index in 0..<20 {
            workspace.trace.mark("line\(index)")
        }

        let lines = workspace.trace.lastLines(limit: 5)
        #expect(lines.count == 5)
        #expect(lines.last?.contains("line19") == true)
        #expect(lines.contains { $0.contains("line15") })
        // 更早的不该出现在窗口里。
        #expect(!lines.contains { $0.contains("line14") })
    }

    @Test("卡死报告覆盖写：只保留最近一次")
    func stallReportOverwrites() {
        let workspace = makeWorkspace()

        workspace.trace.writeStallReport("第一份")
        workspace.trace.writeStallReport("第二份")

        let content = try? String(contentsOf: workspace.trace.stackFile, encoding: .utf8)
        #expect(content == "第二份")
    }

    @Test("耗时标记不会抛错，且确实写入了一行")
    func durationMark() {
        let workspace = makeWorkspace()

        let started = ProcessInfo.processInfo.systemUptime
        workspace.trace.markDuration("duration", from: started)

        let lines = workspace.trace.lastLines(limit: 5)
        #expect(lines.count == 1)
        #expect(lines[0].contains("duration"))
        #expect(lines[0].contains("耗时"))
    }

    @Test("文件超过上限会被裁剪，不会无限增长")
    func traceFileIsTrimmed() {
        let workspace = makeWorkspace()

        // 写超过上限的条数，触发裁剪路径。
        for index in 0..<(TraceWorkspace.maxLineCount + 200) {
            workspace.trace.mark("bulk\(index)")
        }

        let content = try? String(
            contentsOf: workspace.trace.traceFile,
            encoding: .utf8
        )
        let count = content?.split(separator: "\n").count ?? 0
        #expect(count > 0)
        #expect(count <= TraceWorkspace.maxLineCount)
        // 裁剪保留的是尾部，最新的那条必须在。
        #expect(content?.contains("bulk\(TraceWorkspace.maxLineCount + 199)") == true)
    }

    @Test("导出：把诊断文件复制到用户选的目录")
    func exportCopiesFiles() throws {
        let workspace = makeWorkspace()
        let manager = FileManager.default
        try manager.createDirectory(at: workspace.directory, withIntermediateDirectories: true)

        let source = workspace.directory.appendingPathComponent("trace.log")
        try "标记\n".write(to: source, atomically: true, encoding: .utf8)
        let stack = workspace.directory.appendingPathComponent("stall-stack.txt")
        try "栈\n".write(to: stack, atomically: true, encoding: .utf8)

        let destination = workspace.directory.appendingPathComponent("exported", isDirectory: true)
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)

        let written = try workspace.trace.export(to: destination)

        #expect(Set(written) == ["trace.log", "stall-stack.txt"])
        let copied = try String(
            contentsOf: destination.appendingPathComponent("trace.log"),
            encoding: .utf8
        )
        #expect(copied == "标记\n")
    }

    @Test("导出：没有诊断文件时返回空，不抛错")
    func exportWithoutFiles() throws {
        let workspace = makeWorkspace()
        let manager = FileManager.default
        try manager.createDirectory(at: workspace.directory, withIntermediateDirectories: true)
        let destination = workspace.directory.appendingPathComponent("empty", isDirectory: true)
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)

        let written = try workspace.trace.export(to: destination)
        #expect(written.isEmpty)
    }

    /// 每个用例独占一个临时目录：并行执行时不会互相污染，也不碰 App 的真实取证文件。
    private func makeWorkspace() -> TraceWorkspace {
        TraceWorkspace(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("HangTraceTests-\(UUID().uuidString)", isDirectory: true)
        )
    }
}

/// 一份可注入目录的取证文件读写器：与 `HangTrace` 同名同语义，只是目录可控。
struct TraceWorkspace {
    static let maxLineCount = HangTrace.maxLineCount

    let directory: URL

    var trace: TraceFiles {
        TraceFiles(directory: directory)
    }
}

/// 指定目录下的 `trace.log` / `stall-stack.txt` 读写。
struct TraceFiles {
    let directory: URL

    var traceFile: URL { directory.appendingPathComponent("trace.log") }
    var stackFile: URL { directory.appendingPathComponent("stall-stack.txt") }

    func mark(_ stage: String, _ detail: String = "") {
        let line = detail.isEmpty ? stage : "\(stage) | \(detail)"
        try? ensureDirectory()
        let url = existingOrCreated(traceFile)
        if let handle = try? FileHandle(forUpdating: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((line + "\n").utf8))
        }
        trimIfNeeded()
    }

    /// 超过行数上限就只留尾部——与 `HangTrace` 的裁剪策略一致。
    private func trimIfNeeded() {
        let attributes = try? FileManager.default.attributesOfItem(atPath: traceFile.path)
        let byteCount = attributes?[.size] as? Int ?? 0
        // 与产品代码同一条判据：按**真实行数**，不按平均行长估算。
        guard let content = try? String(contentsOf: traceFile, encoding: .utf8) else { return }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        let exceedsLines = lines.count > TraceWorkspace.maxLineCount
        let exceedsBytes = byteCount > TraceWorkspace.maxLineCount * 64
        guard exceedsLines || exceedsBytes else { return }
        let kept = lines.suffix(TraceWorkspace.maxLineCount / 2).joined(separator: "\n")
        try? kept.write(to: traceFile, atomically: true, encoding: .utf8)
    }

    func markDuration(_ stage: String, from startedAt: TimeInterval) {
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        mark(stage, String(format: "耗时 %.1f ms", elapsed * 1000))
    }

    func lastLines(limit: Int) -> [String] {
        guard let content = try? String(contentsOf: traceFile, encoding: .utf8) else {
            return []
        }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else { return [] }
        return lines.suffix(limit).map(String.init)
    }

    /// 与 `HangTrace.export` 同语义：只拷存在的取证文件，返回文件名。
    func export(to destination: URL) throws -> [String] {
        let manager = FileManager.default
        var written: [String] = []
        for source in [traceFile, stackFile] where manager.fileExists(atPath: source.path) {
            let target = destination.appendingPathComponent(source.lastPathComponent)
            try? manager.removeItem(at: target)
            try manager.copyItem(at: source, to: target)
            written.append(source.lastPathComponent)
        }
        return written
    }

    func writeStallReport(_ text: String) {
        try? ensureDirectory()
        try? text.write(to: stackFile, atomically: true, encoding: .utf8)
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    private func existingOrCreated(_ url: URL) -> URL {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        return url
    }
}
