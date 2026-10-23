import CoreGraphics
import Foundation
import SwiftData
import Testing
@testable import IceShot

/// 历史库行为：保存 / 读取 / 收藏 / 删除 / 自动清理，全部跑在临时目录与内存容器里。
@MainActor
struct LibraryStoreTests {
    @Test func saveLoadAndDeleteRemovesFiles() async throws {
        let (runtime, baseURL) = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: baseURL) }

        let image = try makeImage(width: 1200, height: 800)
        try await runtime.store.save([image], source: .region)

        let records = try runtime.container.mainContext.fetch(
            FetchDescriptor<ScreenshotRecord>()
        )
        let record = try #require(records.first)
        #expect(records.count == 1)
        #expect(record.pixelWidth == 1200)
        #expect(record.pixelHeight == 800)
        #expect(record.source == .region)
        #expect(record.byteSize > 0)

        let originalURL = runtime.paths.screenshotsDirectory
            .appendingPathComponent(record.originalFileName)
        let thumbnailURL = runtime.paths.thumbnailsDirectory
            .appendingPathComponent(record.thumbnailFileName)
        #expect(FileManager.default.fileExists(atPath: originalURL.path))
        #expect(FileManager.default.fileExists(atPath: thumbnailURL.path))

        let loaded = await runtime.store.image(for: record, thumbnail: false)
        #expect(loaded?.width == 1200)
        let thumbnail = await runtime.store.image(for: record, thumbnail: true)
        #expect(thumbnail != nil)
        #expect((thumbnail?.width ?? 0) <= 512)

        try await runtime.store.delete(record)
        #expect(try runtime.container.mainContext.fetch(
            FetchDescriptor<ScreenshotRecord>()
        ).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: originalURL.path))
        #expect(!FileManager.default.fileExists(atPath: thumbnailURL.path))
    }

    @Test func favoriteCanBeToggledAndPersists() async throws {
        let (runtime, baseURL) = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: baseURL) }

        try await runtime.store.save(
            [try makeImage(width: 40, height: 30)],
            source: .window
        )
        let record = try #require(
            try runtime.container.mainContext.fetch(
                FetchDescriptor<ScreenshotRecord>()
            ).first
        )
        #expect(!record.isFavorite)

        try runtime.store.toggleFavorite(record)
        #expect(record.isFavorite)

        try runtime.store.toggleFavorite(record)
        #expect(!record.isFavorite)
    }

    @Test func maintenanceRemovesUnreferencedFiles() async throws {
        let (runtime, baseURL) = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: baseURL) }

        try await runtime.store.save(
            [try makeImage(width: 40, height: 30)],
            source: .display
        )

        let orphanURL = runtime.paths.screenshotsDirectory
            .appendingPathComponent("orphan.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: orphanURL)

        await runtime.store.performMaintenance()
        #expect(!FileManager.default.fileExists(atPath: orphanURL.path))
    }

    private func makeRuntime() throws -> (LibraryRuntime, URL) {
        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "IceShotLibraryTests-\(UUID().uuidString)",
            isDirectory: true
        )
        // 这批用例不关心文字识别：传 nil 避免真的跑 Vision，保持测试纯净与快速。
        let runtime = try LibraryRuntimeFactory.make(
            baseURL: baseURL,
            inMemory: true,
            recognizer: nil
        )
        return (runtime, baseURL)
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    @Test func deleteNonFavoritesKeepsFavorites() async throws {
        let (runtime, baseURL) = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: baseURL) }

        try await runtime.store.save(
            [try makeImage(width: 40, height: 30)],
            source: .region
        )
        let first = try #require(
            try runtime.container.mainContext.fetch(
                FetchDescriptor<ScreenshotRecord>()
            ).first
        )
        try runtime.store.toggleFavorite(first)

        try await runtime.store.save(
            [try makeImage(width: 50, height: 40)],
            source: .window
        )
        try await runtime.store.deleteNonFavorites()

        let remaining = try runtime.container.mainContext.fetch(
            FetchDescriptor<ScreenshotRecord>()
        )
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == first.id)
        #expect(remaining.first?.isFavorite == true)
    }

    @Test func oldNonFavoriteIsRemovedByRetention() async throws {
        let (runtime, baseURL) = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: baseURL) }

        let oldDate = Date().addingTimeInterval(-31 * 24 * 60 * 60)
        try await runtime.store.save(
            [try makeImage(width: 40, height: 30)],
            source: .display,
            createdAt: oldDate
        )

        let remaining = try runtime.container.mainContext.fetch(
            FetchDescriptor<ScreenshotRecord>()
        )
        #expect(remaining.isEmpty)
    }

    @Test func retentionProtectsRecordBeingViewed() async throws {
        let (runtime, baseURL) = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: baseURL) }

        try await runtime.store.save(
            [try makeImage(width: 40, height: 30)],
            source: .region
        )
        let record = try #require(
            try runtime.container.mainContext.fetch(
                FetchDescriptor<ScreenshotRecord>()
            ).first
        )
        record.createdAt = Date().addingTimeInterval(-31 * 24 * 60 * 60)
        try runtime.container.mainContext.save()

        runtime.store.setProtectedRecord(record.id)
        await runtime.store.performMaintenance()
        #expect(try runtime.container.mainContext.fetch(
            FetchDescriptor<ScreenshotRecord>()
        ).count == 1)

        runtime.store.setProtectedRecord(nil)
        await runtime.store.performMaintenance()
        #expect(try runtime.container.mainContext.fetch(
            FetchDescriptor<ScreenshotRecord>()
        ).isEmpty)
    }
}
