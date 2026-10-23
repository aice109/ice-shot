import CoreGraphics
import Foundation
import Vision

/// 文字识别入口。抽象成协议是为了让历史库的识别流程可以用假实现在单测里跑，
/// 不依赖真实屏幕内容或 Vision 的识别结果。
nonisolated protocol TextRecognizing: Sendable {
    /// 识别图片里的文字；没有文字时返回 `nil`（调用方据此判断「未识别到」）。
    func recognizeText(in image: CGImage) async -> String?
}

/// 系统 Vision 实现：全部在本机完成，不联网、不落日志内容。
///
/// 识别在 `Task.detached(priority: .utility)` 的后台线程执行，不占用主线程；
/// 单张截图通常几十到几百毫秒，失败（模型不可用 / 图像异常）返回 `nil`，
/// 由历史库保持「未识别」状态，详情页可以手动重试。
struct VisionTextRecognizer: TextRecognizing {
    /// 优先中英混排；系统不支持的语言会被自动过滤掉。
    static let preferredLanguages = ["zh-Hans", "en-US"]

    func recognizeText(in image: CGImage) async -> String? {
        await Task.detached(priority: .utility) {
            Self.recognizeTextSynchronously(image)
        }.value
    }

    private static func recognizeTextSynchronously(_ image: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        if let languages = supportedLanguages(for: request) {
            request.recognitionLanguages = languages
        }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observations = request.results, !observations.isEmpty else {
            return nil
        }

        // Vision 已按阅读顺序返回；这里只清理首尾空白并去掉空行。
        let lines = observations
            .compactMap { $0.topCandidates(1).first?.string }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }

    /// 过滤出系统实际支持的语言，避免在不支持的环境里抛错。
    private static func supportedLanguages(for request: VNRecognizeTextRequest) -> [String]? {
        guard let supported = try? request.supportedRecognitionLanguages() else {
            return nil
        }
        let available = preferredLanguages.filter { supported.contains($0) }
        return available.isEmpty ? nil : available
    }
}
