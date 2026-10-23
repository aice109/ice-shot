import CoreGraphics
import Foundation
import SwiftData

/// SwiftData 元数据 + 沙盒文件的历史库。所有记录操作都在 MainActor，磁盘 IO 在 FileStore actor。
@MainActor
final class LibraryStore: HistorySaving {
    let container: ModelContainer
    let fileStore: FileStore

    private var protectedRecordID: UUID?
    /// 后台识别队列；同一时间只跑一条，`save` 里会替换掉上一条。
    /// 暴露为 `private(set)` 便于测试等待识别结束。
    private(set) var ocrTask: Task<Void, Never>?

    private let recognizer: TextRecognizing?
    private let ocrSettings: OCRSettingsProviding

    private var context: ModelContext {
        container.mainContext
    }

    init(
        container: ModelContainer,
        fileStore: FileStore,
        recognizer: TextRecognizing? = nil,
        ocrSettings: OCRSettingsProviding? = nil
    ) {
        self.container = container
        self.fileStore = fileStore
        self.recognizer = recognizer
        // 默认值不写成参数默认表达式：`UserDefaultsOCRSettings` 是 MainActor 隔离类型，
        // 在默认参数（非隔离求值上下文）里构造会告警；放到 init 体内求值即可。
        self.ocrSettings = ocrSettings ?? UserDefaultsOCRSettings()
    }

    /// 是否配置了识别器（历史详情据此决定「识别文字」按钮是否可用）。
    var canRecognizeText: Bool {
        recognizer != nil
    }

    func save(
        _ images: [CGImage],
        source: ScreenshotSource,
        createdAt: Date = Date()
    ) async throws {
        guard !images.isEmpty else {
            return
        }

        var inserted: [ScreenshotRecord] = []
        var files: [StoredImageFiles] = []
        var pendingOCR: [(ScreenshotRecord, CGImage)] = []

        do {
            for image in images {
                let id = UUID()
                let stored = try await fileStore.writeScreenshot(image, id: id)
                let record = ScreenshotRecord(
                    id: id,
                    createdAt: createdAt,
                    pixelWidth: stored.pixelWidth,
                    pixelHeight: stored.pixelHeight,
                    byteSize: stored.byteSize,
                    source: source,
                    originalFileName: stored.originalFileName,
                    thumbnailFileName: stored.thumbnailFileName
                )
                context.insert(record)
                inserted.append(record)
                files.append(stored)
                pendingOCR.append((record, image))
            }
            try context.save()
        } catch {
            context.rollback()
            for stored in files {
                try? await fileStore.delete(
                    originalName: stored.originalFileName,
                    thumbnailName: stored.thumbnailFileName,
                    editName: nil
                )
            }
            if let libraryError = error as? LibraryError {
                throw libraryError
            }
            throw LibraryError.recordSaveFailed
        }

        await enforceRetention()
        scheduleOCR(for: pendingOCR)
    }

    // MARK: - 文字识别

    /// 保存后异步识别文字：不阻塞截图收尾，结果写回 `ocrText` 后列表 / 详情自动刷新。
    private func scheduleOCR(for pairs: [(ScreenshotRecord, CGImage)]) {
        guard let recognizer, ocrSettings.isAutoRecognizeEnabled else { return }
        ocrTask?.cancel()
        ocrTask = Task { [weak self] in
            for (record, image) in pairs {
                guard !Task.isCancelled, let self else { return }
                guard record.ocrText == nil else { continue }
                guard let text = await recognizer.recognizeText(in: image) else { continue }
                record.ocrText = text
                try? self.context.save()
            }
        }
    }

    /// 手动识别单条记录（自动识别关闭、旧记录或上次失败时用）。识别失败不覆盖已有文本。
    @discardableResult
    func recognizeText(for record: ScreenshotRecord) async -> Bool {
        guard let recognizer else { return false }
        guard let image = await fileStore.readOriginal(named: record.originalFileName) else {
            return false
        }
        guard let text = await recognizer.recognizeText(in: image) else { return false }
        record.ocrText = text
        do {
            try context.save()
            return true
        } catch {
            return false
        }
    }

    func image(
        for record: ScreenshotRecord,
        thumbnail: Bool
    ) async -> CGImage? {
        if thumbnail {
            if let image = await fileStore.readThumbnail(
                named: record.thumbnailFileName
            ) {
                return image
            }
            // 缩略图损坏 / 缺失时回退原图，列表仍可显示；不把原图当详情图。
            return await fileStore.readOriginal(named: record.originalFileName)
        }
        return await fileStore.readOriginal(named: record.originalFileName)
    }

    func delete(_ record: ScreenshotRecord) async throws {
        do {
            try await fileStore.delete(
                originalName: record.originalFileName,
                thumbnailName: record.thumbnailFileName,
                editName: record.editFileName
            )
        } catch let error as LibraryError {
            throw error
        } catch {
            throw LibraryError.fileDeleteFailed(code: (error as NSError).code)
        }

        context.delete(record)
        do {
            try context.save()
        } catch {
            context.rollback()
            throw LibraryError.recordSaveFailed
        }
    }

    func deleteAll() async throws {
        let records = try fetchRecords()
        for record in records {
            try await delete(record)
        }
    }

    func deleteNonFavorites() async throws {
        let records = try fetchRecords().filter { !$0.isFavorite }
        for record in records {
            try await delete(record)
        }
    }

    func toggleFavorite(_ record: ScreenshotRecord) throws {
        record.isFavorite.toggle()
        do {
            try context.save()
        } catch {
            context.rollback()
            throw LibraryError.recordSaveFailed
        }
    }

    func storageUsage() async -> Int64 {
        await fileStore.storageUsage()
    }

    /// 自动清理不删除用户正在查看的记录；显式删除 / 清空不受影响。
    func setProtectedRecord(_ id: UUID?) {
        protectedRecordID = id
    }

    func performMaintenance() async {
        do {
            let records = try fetchRecords()
            let knownNames = Set(
                records.flatMap { record in
                    [record.originalFileName, record.thumbnailFileName]
                        + [record.editFileName].compactMap { $0 }
                }
            )
            await fileStore.cleanupTemp()
            await fileStore.cleanupOrphans(knownFileNames: knownNames)
            await enforceRetention()
        } catch {
            return
        }
    }

    private func fetchRecords() throws -> [ScreenshotRecord] {
        let descriptor = FetchDescriptor<ScreenshotRecord>(
            sortBy: [SortDescriptor(\ScreenshotRecord.createdAt, order: .reverse)]
        )
        do {
            return try context.fetch(descriptor)
        } catch {
            throw LibraryError.storageUnavailable
        }
    }

    private func enforceRetention(now: Date = Date()) async {
        guard let records = try? fetchRecords() else {
            return
        }

        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -HistoryPreferences.retentionDays,
            to: now
        ) ?? now.addingTimeInterval(
            -TimeInterval(HistoryPreferences.retentionDays) * 24 * 60 * 60
        )

        var keptCount = 0
        var keptBytes: Int64 = 0
        var removedAny = false

        for record in records {
            guard !record.isFavorite,
                  record.id != protectedRecordID else {
                continue
            }

            let exceedsAge = record.createdAt < cutoff
            let exceedsCount = keptCount >= HistoryPreferences.maximumCount
            let exceedsBytes = keptBytes + Int64(record.byteSize)
                > HistoryPreferences.maximumByteSize

            guard exceedsAge || exceedsCount || exceedsBytes else {
                keptCount += 1
                keptBytes += Int64(record.byteSize)
                continue
            }

            do {
                try await fileStore.delete(
                    originalName: record.originalFileName,
                    thumbnailName: record.thumbnailFileName,
                    editName: record.editFileName
                )
                context.delete(record)
                removedAny = true
            } catch {
                // 文件删除失败时保留记录，下一次维护重试，避免记录消失但文件残留。
                continue
            }
        }

        guard removedAny else {
            return
        }
        do {
            try context.save()
        } catch {
            context.rollback()
        }
    }
}
