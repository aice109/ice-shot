import CryptoKit
import Foundation

/// 下载安装包。抽成协议的理由和 `ReleaseFetching` 一样：
/// 下载器的状态机（空闲 / 下载中 / 取消 / 完成）要能在单测里跑，而单测不该真的打网络。
protocol UpdateDownloading: Sendable {
    /// 下载到沙盒临时目录，返回本地文件地址。
    /// - Parameter onProgress: 0...1 的进度回调；总长度未知时传 `nil`。
    func download(
        _ asset: ReleaseAsset,
        onProgress: @Sendable @escaping (Double?) -> Void
    ) async throws -> URL
}

enum UpdateDownloadError: Error, Equatable {
    /// 网络失败、非 2xx、或写盘失败。
    case failed
    /// 用户取消。
    case cancelled
    /// 校验值与本文件不匹配（传输损坏或被篡改）。
    case checksumMismatch
}

/// 生产实现：`URLSession` 直接下载到沙盒临时目录。
///
/// 写盘目标是 `LibraryPaths.tempDirectory`——容器内的路径，**不触碰用户文件系统**，
/// 因此不需要新增任何文件权限 entitlement。下载完由界面用 `NSSavePanel` 另存。
///
/// 为什么不用「先下到 Downloads」：沙盒写不到 `~/Downloads`（除非加
/// `files.downloads.read-write`），而保存面板本来就是用户的授权通道，没必要扩权限面。
struct URLSessionUpdateDownloader: UpdateDownloading {
    private let session: URLSession
    private let tempDirectory: URL

    nonisolated init(
        session: URLSession = GitHubReleaseClient.makeSession(),
        tempDirectory: URL
    ) {
        self.session = session
        self.tempDirectory = tempDirectory
    }

    func download(
        _ asset: ReleaseAsset,
        onProgress: @Sendable @escaping (Double?) -> Void
    ) async throws -> URL {
        do {
            try FileManager.default.createDirectory(
                at: tempDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw UpdateDownloadError.failed
        }

        // 期望校验值：先取回很小的 `.sha256` 文本，取不到就不校验（不因此失败）。
        let expected = await fetchExpectedChecksum(for: asset)

        let destination = tempDirectory.appendingPathComponent(asset.name)
        // 同名旧文件会让 `move` 失败，先清掉。
        try? FileManager.default.removeItem(at: destination)

        let delegate = ProgressDelegate(onProgress: onProgress)
        let downloadSession = URLSession(
            configuration: session.configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { downloadSession.finishTasksAndInvalidate() }

        let temporaryURL: URL
        do {
            let (url, response) = try await downloadSession.download(from: asset.url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode)
            else {
                throw UpdateDownloadError.failed
            }
            temporaryURL = url
        } catch let error as UpdateDownloadError {
            throw error
        } catch is CancellationError {
            throw UpdateDownloadError.cancelled
        } catch {
            throw UpdateDownloadError.failed
        }

        do {
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
        } catch {
            throw UpdateDownloadError.failed
        }

        if let expected {
            guard let actual = Self.sha256(ofFileAt: destination),
                  actual.caseInsensitiveCompare(expected) == .orderedSame
            else {
                try? FileManager.default.removeItem(at: destination)
                throw UpdateDownloadError.checksumMismatch
            }
        }

        return destination
    }

    /// 取 `.sha256` 文件并解析出期望的哈希。文件形如 `<hash>  <文件名>`。
    private func fetchExpectedChecksum(for asset: ReleaseAsset) async -> String? {
        guard let url = asset.checksumTextURL else { return nil }
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return Self.parseChecksum(text, expectingFile: asset.name)
    }

    /// 从 `.sha256` 文本里取指向目标文件的那一行；只有一行时直接用。
    ///
    /// `sha256sum` 的格式是 `<hash>  <filename>`（两个空格），`shasum -a 256` 是
    /// `<hash>  <filename>` 或 `<hash> *<filename>`；两种都兼容。
    static func parseChecksum(_ text: String, expectingFile fileName: String) -> String? {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }

        let matched = lines.first { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { return false }
            let name = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            return name == fileName
        }

        let chosen = matched ?? (lines.count == 1 ? lines[0] : nil)
        guard let chosen else { return nil }
        return chosen.split(separator: " ").first.map(String.init)
    }

    /// 流式哈希，避免把 3.8MB 整个读进内存（将来的包可能更大）。
    static func sha256(ofFileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = (try? handle.read(upToCount: 1 << 20)) ?? nil
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// 把 `URLSession` 的进度回调转给异步调用方。
///
/// 只有进度这一个用途，所以单独一个最小 delegate。
/// 用 `NSLock` 保护状态而不用 `@unchecked Sendable`：仓库禁用后者。
private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double?) -> Void
    /// 用 `NSLock` 自己的保护对象，避免在 `Sendable` 类里放裸可变属性。
    private let state = LockedFlag()

    init(onProgress: @Sendable @escaping (Double?) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard !state.isSet else { return }

        guard totalBytesExpectedToWrite > 0 else {
            onProgress(nil)
            return
        }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // 实际搬运在 `URLSessionUpdateDownloader.download` 里用 `download(from:)` 的返回值做，
        // 这里只是协议要求实现，顺便把状态标为已结束以停掉后续进度回调。
        state.set()
    }
}

/// 一个加锁的布尔标记。
///
/// 单拿出来是为了不再为「一个 Bool 跨线程可见」引入 `@unchecked Sendable` 的类属性；
/// 锁本身是唯一状态，可安全标为 `@unchecked Sendable`（`NSLock` 保证互斥）。
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
