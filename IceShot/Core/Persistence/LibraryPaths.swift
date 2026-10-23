import Foundation

/// 历史库的沙盒目录；数据库与截图文件都只使用相对文件名 / 固定布局。
nonisolated struct LibraryPaths: Sendable {
    let baseURL: URL

    /// 原图（PNG）。
    var screenshotsDirectory: URL {
        baseURL.appendingPathComponent("Screenshots", isDirectory: true)
    }

    /// 列表缩略图（JPEG），与历史记录生命周期一致。
    var thumbnailsDirectory: URL {
        baseURL.appendingPathComponent("Thumbnails", isDirectory: true)
    }

    /// 编辑器保存的工程文件。
    var editsDirectory: URL {
        baseURL.appendingPathComponent("Edits", isDirectory: true)
    }

    /// 贴图（后续功能）使用的文件目录，先预留。
    var pinsDirectory: URL {
        baseURL.appendingPathComponent("Pins", isDirectory: true)
    }

    /// 一次性临时文件（如更新下载），启动与维护时清理。
    var tempDirectory: URL {
        baseURL.appendingPathComponent("Temp", isDirectory: true)
    }

    /// SwiftData 数据库文件。
    var databaseURL: URL {
        baseURL.appendingPathComponent("Library.store")
    }

    static func applicationSupport() throws -> LibraryPaths {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw LibraryError.storageUnavailable
        }
        return LibraryPaths(
            baseURL: support.appendingPathComponent("IceShot", isDirectory: true)
        )
    }

    /// 测试宿主与单元测试使用独立临时目录，避免污染用户历史。
    static func temporary() -> LibraryPaths {
        LibraryPaths(
            baseURL: FileManager.default.temporaryDirectory.appendingPathComponent(
                "IceShotLibrary-\(UUID().uuidString)",
                isDirectory: true
            )
        )
    }

    func createDirectories() throws {
        let fileManager = FileManager.default
        for directory in [
            baseURL,
            screenshotsDirectory,
            thumbnailsDirectory,
            editsDirectory,
            pinsDirectory,
            tempDirectory
        ] {
            do {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
            } catch {
                throw LibraryError.storageUnavailable
            }
        }
    }
}
