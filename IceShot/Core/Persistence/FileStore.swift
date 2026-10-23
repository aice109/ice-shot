import CoreGraphics
import Foundation
import ImageIO

/// 一次写入产生的文件信息；只含相对文件名与统计值，不含绝对路径。
struct StoredImageFiles: Sendable {
    let originalFileName: String
    let thumbnailFileName: String
    let byteSize: Int
    let pixelWidth: Int
    let pixelHeight: Int
}

/// 所有磁盘 IO 在 actor 中执行；只接受 / 返回相对文件名。
actor FileStore {
    /// 目录布局不可变，标记 `nonisolated` 方便 UI 侧只读访问。
    nonisolated let paths: LibraryPaths

    init(paths: LibraryPaths) {
        self.paths = paths
    }

    /// 写入原图 PNG 与缩略图 JPEG；任何一步失败都会清理已写文件，避免半套数据。
    func writeScreenshot(_ image: CGImage, id: UUID) throws -> StoredImageFiles {
        let pngData: Data
        do {
            pngData = try ImageEncoder.pngData(from: image)
        } catch {
            throw LibraryError.fileWriteFailed(code: (error as NSError).code)
        }

        let thumbnailData: Data
        do {
            thumbnailData = try ThumbnailGenerator.jpegData(fromPNG: pngData)
        } catch {
            throw LibraryError.thumbnailFailed
        }

        let originalName = "\(id.uuidString).png"
        let thumbnailName = "\(id.uuidString).jpg"
        let originalURL = paths.screenshotsDirectory.appendingPathComponent(originalName)
        let thumbnailURL = paths.thumbnailsDirectory.appendingPathComponent(thumbnailName)

        do {
            try pngData.write(to: originalURL, options: .atomic)
            try thumbnailData.write(to: thumbnailURL, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: originalURL)
            try? FileManager.default.removeItem(at: thumbnailURL)
            throw LibraryError.fileWriteFailed(code: (error as NSError).code)
        }

        return StoredImageFiles(
            originalFileName: originalName,
            thumbnailFileName: thumbnailName,
            byteSize: pngData.count,
            pixelWidth: image.width,
            pixelHeight: image.height
        )
    }

    /// 读取原图；文件名必须来自数据库，不接受路径分隔符。
    func readOriginal(named fileName: String) -> CGImage? {
        readImage(in: paths.screenshotsDirectory, fileName: fileName)
    }

    /// 读取缩略图；失败返回 nil，由 UI 降级为占位图。
    func readThumbnail(named fileName: String) -> CGImage? {
        readImage(in: paths.thumbnailsDirectory, fileName: fileName)
    }

    /// 原图绝对路径（同步、只读）：右键「在 Finder 中显示」与拖出导出都要在不进 actor 的
    /// 同步上下文里拿到 URL，而 `paths` 本身就是 `nonisolated` 的，这里不需要跨 actor。
    nonisolated func originalURL(named fileName: String) -> URL? {
        url(in: paths.screenshotsDirectory, fileName: fileName)
    }

    /// 删除一张截图关联的全部文件（原图 / 缩略图 / 编辑工程）。
    func delete(
        originalName: String,
        thumbnailName: String,
        editName: String?
    ) throws {
        do {
            try removeIfExists(
                in: paths.screenshotsDirectory,
                fileName: originalName
            )
            try removeIfExists(
                in: paths.thumbnailsDirectory,
                fileName: thumbnailName
            )
            if let editName {
                try removeIfExists(
                    in: paths.editsDirectory,
                    fileName: editName
                )
            }
        } catch {
            throw LibraryError.fileDeleteFailed(code: (error as NSError).code)
        }
    }

    /// 清理超过指定时间的临时文件（默认为 1 天），用于下载安装包等一次性产物。
    func cleanupTemp(olderThan age: TimeInterval = 24 * 60 * 60) {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: paths.tempDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let cutoff = Date().addingTimeInterval(-age)
        for url in contents {
            let modified = (try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? .distantPast
            if modified < cutoff {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    /// 删除数据库中不存在的文件；只处理三个受控目录，不触碰数据库与其它文件。
    func cleanupOrphans(knownFileNames: Set<String>) {
        let fileManager = FileManager.default
        for directory in [
            paths.screenshotsDirectory,
            paths.thumbnailsDirectory,
            paths.editsDirectory
        ] {
            guard let contents = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for url in contents where !knownFileNames.contains(url.lastPathComponent) {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    /// 统计历史库占用的字节数（原图 / 缩略图 / 编辑 / 贴图），供容量清理判断。
    func storageUsage() -> Int64 {
        let fileManager = FileManager.default
        var total: Int64 = 0
        for directory in [
            paths.screenshotsDirectory,
            paths.thumbnailsDirectory,
            paths.editsDirectory,
            paths.pinsDirectory
        ] {
            guard let contents = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for url in contents {
                let size = (try? url.resourceValues(
                    forKeys: [.fileSizeKey]
                ).fileSize) ?? 0
                total += Int64(size)
            }
        }
        return total
    }

    private func readImage(in directory: URL, fileName: String) -> CGImage? {
        guard let url = url(in: directory, fileName: fileName),
              FileManager.default.fileExists(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func removeIfExists(in directory: URL, fileName: String) throws {
        guard let url = url(in: directory, fileName: fileName),
              FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        try FileManager.default.removeItem(at: url)
    }

    /// 只接受纯文件名，拒绝 `../` 与路径分隔符，避免越出受控目录。
    private nonisolated func url(in directory: URL, fileName: String) -> URL? {
        guard !fileName.isEmpty,
              !fileName.contains("/"),
              !fileName.contains("\\"),
              URL(fileURLWithPath: fileName).lastPathComponent == fileName else {
            return nil
        }
        return directory.appendingPathComponent(fileName)
    }
}
