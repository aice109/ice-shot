import CoreGraphics
import Foundation
import SwiftData
import Testing
@testable import IceShot

/// 文字识别流程：写库 / 开关 / 失败不写 / 手动重试 / 搜索命中。
/// 用假识别器验证链路，不依赖 Vision 的真实识别结果。
@MainActor
struct OCRPipelineTests {
    @Test func saveStoresRecognizedText() async throws {
        let (runtime, baseURL) = try makeRuntime(text: "发票号码 12345")
        defer { try? FileManager.default.removeItem(at: baseURL) }

        try await runtime.store.save([try makeImage()], source: .region)
        await runtime.store.ocrTask?.value

        let record = try #require(try records(in: runtime.container).first)
        #expect(record.ocrText == String(localized: "发票号码 12345"))
    }

    @Test func noTextKeepsRecordEmpty() async throws {
        let (runtime, baseURL) = try makeRuntime(text: nil)
        defer { try? FileManager.default.removeItem(at: baseURL) }

        try await runtime.store.save([try makeImage()], source: .region)
        await runtime.store.ocrTask?.value

        let record = try #require(try records(in: runtime.container).first)
        #expect(record.ocrText == nil)
    }

    @Test func disabledPreferenceSkipsAutomaticOCR() async throws {
        // 注入固定设置，避免与并行运行的其它用例互相影响全局 UserDefaults。
        let (runtime, baseURL) = try makeRuntime(text: "不该写入", autoRecognize: false)
        defer { try? FileManager.default.removeItem(at: baseURL) }

        try await runtime.store.save([try makeImage()], source: .region)
        await runtime.store.ocrTask?.value

        let record = try #require(try records(in: runtime.container).first)
        #expect(record.ocrText == nil)
    }

    @Test func manualRecognitionFillsTextLater() async throws {
        let (runtime, baseURL) = try makeRuntime(text: "手动识别结果", automatic: false)
        defer { try? FileManager.default.removeItem(at: baseURL) }

        let manual = LibraryStore(
            container: runtime.container,
            fileStore: runtime.store.fileStore,
            recognizer: FakeRecognizer(text: "手动识别结果"),
            ocrSettings: FixedOCRSettings(isAutoRecognizeEnabled: false)
        )
        try await runtime.store.save([try makeImage()], source: .region)
        await runtime.store.ocrTask?.value

        let record = try #require(try records(in: runtime.container).first)
        #expect(record.ocrText == nil)
        #expect(manual.canRecognizeText)

        #expect(await manual.recognizeText(for: record))
        #expect(record.ocrText == String(localized: "手动识别结果"))
    }

    @Test func manualRecognitionWithoutRecognizerFails() async throws {
        let (runtime, baseURL) = try makeRuntime(text: "x", automatic: false)
        defer { try? FileManager.default.removeItem(at: baseURL) }

        try await runtime.store.save([try makeImage()], source: .region)
        let record = try #require(try records(in: runtime.container).first)
        #expect(!runtime.store.canRecognizeText)
        #expect(!(await runtime.store.recognizeText(for: record)))
        #expect(record.ocrText == nil)
    }

    // MARK: - 搜索

    @Test func searchMatchesTagsSourceAndOCRText() {
        #expect(HistorySearch.matches(
            tags: ["发票"],
            sourceName: "区域",
            ocrText: "Total: 42.00",
            query: ""
        ))
        #expect(HistorySearch.matches(
            tags: ["发票"],
            sourceName: "区域",
            ocrText: nil,
            query: "发票"
        ))
        #expect(HistorySearch.matches(
            tags: [],
            sourceName: "窗口",
            ocrText: nil,
            query: "窗口"
        ))
        // OCR 文本忽略大小写
        #expect(HistorySearch.matches(
            tags: [],
            sourceName: "区域",
            ocrText: "Total: 42.00",
            query: "total"
        ))
        #expect(!HistorySearch.matches(
            tags: [],
            sourceName: "区域",
            ocrText: "Total: 42.00",
            query: "42.01"
        ))
    }

    // MARK: - 辅助

    private func makeRuntime(
        text: String?,
        automatic: Bool = true,
        autoRecognize: Bool = true
    ) throws -> (LibraryRuntime, URL) {
        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "IceShotOCRTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let runtime = try LibraryRuntimeFactory.make(
            baseURL: baseURL,
            inMemory: true,
            recognizer: automatic ? FakeRecognizer(text: text) : nil,
            ocrSettings: FixedOCRSettings(isAutoRecognizeEnabled: autoRecognize)
        )
        return (runtime, baseURL)
    }

    private func records(in container: ModelContainer) throws -> [ScreenshotRecord] {
        try container.mainContext.fetch(FetchDescriptor<ScreenshotRecord>())
    }

    private func makeImage() throws -> CGImage {
        let width = 40
        let height = 20
        guard let provider = CGDataProvider(
            data: Data(count: width * height * 4) as CFData
        ) else {
            throw CaptureError.encodingFailed
        }
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw CaptureError.encodingFailed
        }
        return image
    }
}

private struct FixedOCRSettings: OCRSettingsProviding {
    let isAutoRecognizeEnabled: Bool
}

private struct FakeRecognizer: TextRecognizing {
    let text: String?

    func recognizeText(in image: CGImage) async -> String? {
        text
    }
}
