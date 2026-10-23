import Foundation
import SwiftData

/// 历史库的运行时装配：SwiftData 容器、文件存储与目录布局。
///
/// 装配一次后由 AppDelegate 持有；测试可以传入临时目录或内存容器，
/// 不会触碰用户的真实历史库。
struct LibraryRuntime {
    let container: ModelContainer
    let store: LibraryStore
    let paths: LibraryPaths
}

/// 按运行环境创建 `LibraryRuntime`。
///
/// 注意：生产环境固定使用 Application Support 下的 `IceShot` 目录，
/// 并使用 `cloudKitDatabase: .none`——历史记录只留在本机。
enum LibraryRuntimeFactory {
    static func make(
        baseURL: URL? = nil,
        inMemory: Bool = false,
        recognizer: TextRecognizing? = VisionTextRecognizer(),
        ocrSettings: OCRSettingsProviding = UserDefaultsOCRSettings()
    ) throws -> LibraryRuntime {
        let paths: LibraryPaths
        if let baseURL {
            paths = LibraryPaths(baseURL: baseURL)
        } else if inMemory {
            paths = .temporary()
        } else {
            paths = try .applicationSupport()
        }

        do {
            try paths.createDirectories()
        } catch {
            throw LibraryError.storageUnavailable
        }

        // 当前只有 V1 schema；后续迁移必须新增 VersionedSchema 并补 migration stage，
        // 不能直接改旧模型字段。
        let schema = Schema(versionedSchema: IceShotSchemaV1.self)
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(
                "IceShotTests",
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
        } else {
            configuration = ModelConfiguration(
                "IceShot",
                schema: schema,
                url: paths.databaseURL,
                cloudKitDatabase: .none
            )
        }

        let container: ModelContainer
        do {
            container = try ModelContainer(
                for: schema,
                migrationPlan: IceShotMigrationPlan.self,
                configurations: configuration
            )
        } catch {
            throw LibraryError.storageUnavailable
        }

        let fileStore = FileStore(paths: paths)
        let store = LibraryStore(
            container: container,
            fileStore: fileStore,
            recognizer: recognizer,
            ocrSettings: ocrSettings
        )
        return LibraryRuntime(container: container, store: store, paths: paths)
    }
}
