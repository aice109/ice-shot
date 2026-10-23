import CoreGraphics
import Foundation
import Vision

/// 识别到的二维码 / 条码。
///
/// 系统 Live Text 不把条码内容交给文字层（实测 `ImageAnalyzer` 的 transcript 为空），
/// 所以条码必须单独用 Vision 检测，再在图上画可点区域。
struct DetectedBarcode: Identifiable, Equatable, Sendable {
    let id = UUID()
    let payload: String
    /// 归一化矩形（0…1），**左上原点**，直接乘以显示尺寸即可定位。
    let normalizedRect: CGRect
    /// 符号类型，例如 `VNBarcodeSymbology.qr.rawValue`。
    let symbology: String?

    var isQRCode: Bool {
        symbology?.contains("QR") == true
    }

    var kindLabel: String {
        guard let symbology else { return "条码" }
        return symbology.contains("QR") ? "二维码" : "条码"
    }
}

/// 条码检测：全部在本机用 Vision 完成，不联网。
nonisolated enum BarcodeDetector {
    /// 检测图中的二维码 / 条码；没有内容时返回空数组。
    static func detect(in image: CGImage) async -> [DetectedBarcode] {
        await Task.detached(priority: .utility) {
            detectSynchronously(in: image)
        }.value
    }

    private static func detectSynchronously(in image: CGImage) -> [DetectedBarcode] {
        let request = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        return (request.results ?? []).compactMap { observation in
            guard let payload = observation.payloadStringValue,
                  !payload.isEmpty else {
                return nil
            }
            // Vision 的 boundingBox 是左下原点，这里换成左上原点给 SwiftUI 用。
            let box = observation.boundingBox
            let rect = CGRect(
                x: box.minX,
                y: 1 - box.maxY,
                width: box.width,
                height: box.height
            )
            return DetectedBarcode(
                payload: payload,
                normalizedRect: rect,
                symbology: observation.symbology.rawValue
            )
        }
    }
}
