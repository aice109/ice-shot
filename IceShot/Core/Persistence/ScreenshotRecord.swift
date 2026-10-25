import Foundation
import SwiftData

/// 截图来源分类，用于历史列表的图标与搜索过滤。
/// 以字符串存库（`sourceRaw`），避免模型里直接存枚举带来的迁移限制。
enum ScreenshotSource: String, CaseIterable, Sendable {
    case region
    case window
    case display
    case allDisplays
    /// 滚动长截图（多帧拼接后的单张长图）。
    case scroll

    var displayName: String {
        switch self {
        case .region: return String(localized: "区域")
        case .window: return String(localized: "窗口")
        case .display: return String(localized: "全屏")
        case .allDisplays: return String(localized: "全部显示器")
        case .scroll: return String(localized: "长截图")
        }
    }

    var symbolName: String {
        switch self {
        case .region: return "rectangle.dashed"
        case .window: return "macwindow"
        case .display: return "rectangle.inset.filled"
        case .allDisplays: return "rectangle.on.rectangle"
        case .scroll: return "scroll"
        }
    }
}

/// SwiftData 只保存元数据；原图、缩略图与编辑工程以相对文件名存放在沙盒文件中。
///
/// 不把图像二进制塞进数据库：列表查询只读元数据，图片按需从磁盘加载，
/// 既控制数据库体积，也避免删除记录时遗漏大文件。
@Model
final class ScreenshotRecord {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var pixelWidth: Int
    var pixelHeight: Int
    var byteSize: Int
    var sourceRaw: String
    var originalFileName: String
    var thumbnailFileName: String
    var editFileName: String?
    var ocrText: String?
    var tags: [String]
    var isFavorite: Bool

    init(
        id: UUID,
        createdAt: Date,
        pixelWidth: Int,
        pixelHeight: Int,
        byteSize: Int,
        source: ScreenshotSource,
        originalFileName: String,
        thumbnailFileName: String,
        editFileName: String? = nil,
        ocrText: String? = nil,
        tags: [String] = [],
        isFavorite: Bool = false
    ) {
        self.id = id
        self.createdAt = createdAt
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.byteSize = byteSize
        self.sourceRaw = source.rawValue
        self.originalFileName = originalFileName
        self.thumbnailFileName = thumbnailFileName
        self.editFileName = editFileName
        self.ocrText = ocrText
        self.tags = tags
        self.isFavorite = isFavorite
    }

    var source: ScreenshotSource {
        ScreenshotSource(rawValue: sourceRaw) ?? .region
    }
}

/// 历史库 schema V1。后续字段变更必须新增 VersionedSchema 并补迁移阶段。
enum IceShotSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version {
        Schema.Version(1, 0, 0)
    }

    static var models: [any PersistentModel.Type] {
        [ScreenshotRecord.self]
    }
}

/// 当前的迁移计划：只有 V1，因此 `stages` 为空；新增版本时在这里追加阶段。
enum IceShotMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [IceShotSchemaV1.self]
    }

    static var stages: [MigrationStage] {
        []
    }
}
