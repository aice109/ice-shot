import AppKit
import CoreGraphics
import SwiftUI
import VisionKit

/// Live Text 分析结果的持有者（按图像对象缓存）。
///
/// 系统分析一次要几百毫秒，取字模式频繁进出时不该重复分析；图像被裁剪 / 旋转后
/// 是新对象，缓存自动失效。分析全部在本机完成，不联网。
@MainActor
final class LiveTextStore {
    private var cachedKey: ObjectIdentifier?
    private var cachedAnalysis: ImageAnalysis?

    func analysis(for image: CGImage) async -> ImageAnalysis? {
        let key = ObjectIdentifier(image)
        if cachedKey == key, let cachedAnalysis {
            return cachedAnalysis
        }
        let analyzer = ImageAnalyzer()
        // 只做文字：条码内容 Live Text 不返回（实测 transcript 为空），走 BarcodeDetector。
        let configuration = ImageAnalyzer.Configuration([.text])
        guard let analysis = try? await analyzer.analyze(
            image,
            orientation: .up,
            configuration: configuration
        ) else {
            return nil
        }
        cachedKey = key
        cachedAnalysis = analysis
        return analysis
    }
}

/// 覆盖在图像显示区域上的取字层：
/// - 文字：系统 Live Text，直接拖选、`⌘C` 复制（选中样式与菜单由系统提供）；
/// - 二维码 / 条码：Live Text 不提供条码内容，这里用 Vision 单独检测并画可点区域，
///   点一下即复制内容。
struct LiveTextOverlay: View {
    let image: CGImage
    let store: LiveTextStore

    /// 复制反馈统一走应用级 HUD：不与系统 Live Text 的 AppKit 图层抢层级。
    @Environment(\.feedbackHUD) private var feedback

    @State private var analysis: ImageAnalysis?
    @State private var barcodes: [DetectedBarcode] = []
    @State private var isLoading = true

    var body: some View {
        ZStack {
            if let analysis {
                LiveTextAnalysisView(analysis: analysis)
            }

            barcodeHotspots

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glassSurface(.clear, contrast: .none, in: Capsule())
                    .allowsHitTesting(false)
            }
        }
        .task(id: ObjectIdentifier(image)) {
            isLoading = true
            // 文字与条码并行：Live Text 只负责文字，条码走 Vision。
            async let textAnalysis = store.analysis(for: image)
            async let detected = BarcodeDetector.detect(in: image)
            analysis = await textAnalysis
            barcodes = await detected
            isLoading = false
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("图片中的文字，可选取复制")
    }
}

extension LiveTextOverlay {
    /// 二维码 / 条码可点区域：描一圈强调色边框，点按复制内容。
    @ViewBuilder
    var barcodeHotspots: some View {
        GeometryReader { proxy in
            ForEach(barcodes) { barcode in
                let rect = displayRect(for: barcode, in: proxy.size)
                Button {
                    copyBarcode(barcode)
                } label: {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .background(
                            Color.accentColor.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 4)
                        )
                        .overlay(alignment: .topLeading) {
                            Text(barcode.kindLabel)
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.accentColor, in: Capsule())
                                .foregroundStyle(.white)
                                .offset(y: -10)
                                .fixedSize()
                        }
                }
                .buttonStyle(.plain)
                .frame(width: max(8, rect.width), height: max(8, rect.height))
                .position(x: rect.midX, y: rect.midY)
                .help("点按复制\(barcode.kindLabel)内容")
                .accessibilityLabel("\(barcode.kindLabel)，点按复制内容")
            }
        }
    }

    private func displayRect(for barcode: DetectedBarcode, in size: CGSize) -> CGRect {
        let normalized = barcode.normalizedRect
        return CGRect(
            x: normalized.minX * size.width,
            y: normalized.minY * size.height,
            width: normalized.width * size.width,
            height: normalized.height * size.height
        )
    }

    private func copyBarcode(_ barcode: DetectedBarcode) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(barcode.payload, forType: .string)
        feedback.show("已复制\(barcode.kindLabel)内容")
    }
}

private struct LiveTextAnalysisView: NSViewRepresentable {
    let analysis: ImageAnalysis

    func makeNSView(context: Context) -> ImageAnalysisOverlayView {
        let view = ImageAnalysisOverlayView()
        view.preferredInteractionTypes = .textSelection
        view.analysis = analysis
        return view
    }

    func updateNSView(_ view: ImageAnalysisOverlayView, context: Context) {
        if view.analysis !== analysis {
            view.analysis = analysis
        }
    }
}

enum ImageDisplayGeometry {
    /// `scaledToFit` 之后图像在容器里的实际矩形（用于把 Live Text 层对齐到图像上）。
    static func aspectFitRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              container.width > 0, container.height > 0 else {
            return .zero
        }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}
