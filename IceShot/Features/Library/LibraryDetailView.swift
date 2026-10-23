import AppKit
import SwiftUI

/// 单张截图的详情：原图预览 + 元数据 + 操作（编辑 / 复制 / 保存 / 收藏 / 删除）。
///
/// 预览在 `.task(id:)` 里异步读取，切换记录时旧任务自动取消；
/// 文件缺失时仍展示元数据并允许删除记录，避免留下无法清理的条目。
struct LibraryDetailView: View {
    let record: ScreenshotRecord
    let library: LibraryStore
    let editor: EditorOpening?
    let onDeleted: () -> Void

    @State private var preview: CGImage?
    @State private var isLoading = true
    @State private var isDeleting = false
    @State private var isConfirmingDelete = false
    @State private var actionMessage: String?
    @State private var errorMessage: String?
    @State private var isRecognizing = false
    /// 预览图上的 Live Text 分析缓存。
    @State private var liveTextStore = LiveTextStore()

    /// 复制 / 另存与列表右键菜单共用同一套实现，避免两处行为漂移。
    private var actions: LibraryRecordActions {
        LibraryRecordActions(library: library, pins: nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            previewArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)

            Divider()

            metadata
        }
        .navigationTitle("截图详情")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: openEditor) {
                    Label("编辑", systemImage: "pencil.tip")
                }
                .disabled(preview == nil || editor == nil)
                .help("在标注编辑器中打开")

                Button(action: copy) {
                    Label("复制", systemImage: "doc.on.doc")
                }
                .disabled(preview == nil)
                .help("复制到剪贴板")

                Button(action: save) {
                    Label("保存", systemImage: "square.and.arrow.down")
                }
                .disabled(preview == nil)
                .help("另存为 PNG")

                Button(action: toggleFavorite) {
                    Label(
                        record.isFavorite ? "取消收藏" : "收藏",
                        systemImage: record.isFavorite ? "heart.fill" : "heart"
                    )
                }
                .help(record.isFavorite ? "取消收藏；收藏不会自动清理" : "收藏；收藏不会自动清理")

                Button(role: .destructive) {
                    isConfirmingDelete = true
                } label: {
                    Label("删除", systemImage: "trash")
                }
                .disabled(isDeleting)
                .help("从历史库删除这张截图")
            }
        }
        .task(id: record.id) {
            isLoading = true
            preview = await library.image(for: record, thumbnail: false)
            isLoading = false
        }
        .confirmationDialog(
            "删除这张截图？",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                delete()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("原图与缩略图会从历史库删除，无法恢复。")
        }
        .alert(
            "操作失败",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var previewArea: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if let preview {
                GeometryReader { proxy in
                    let container = CGSize(
                        width: max(1, proxy.size.width - 48),
                        height: max(1, proxy.size.height - 48)
                    )
                    let rect = ImageDisplayGeometry.aspectFitRect(
                        imageSize: CGSize(width: preview.width, height: preview.height),
                        in: container
                    )
                    ZStack(alignment: .topLeading) {
                        Image(decorative: preview, scale: 1)
                            .resizable()
                            .scaledToFit()
                            .frame(width: container.width, height: container.height)
                        // 系统 Live Text：直接在预览上拖选文字 / 二维码内容复制。
                        LiveTextOverlay(image: preview, store: liveTextStore)
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                    }
                    .frame(width: container.width, height: container.height, alignment: .topLeading)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                }
            } else if isLoading {
                ProgressView("加载原图…")
            } else {
                ContentUnavailableView(
                    "原图不可用",
                    systemImage: "exclamationmark.triangle",
                    description: Text("截图文件可能已被移动或删除。记录仍可删除。")
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(record.source.displayName)
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    Text("来源").foregroundStyle(.secondary)
                    Label(record.source.displayName, systemImage: record.source.symbolName)
                }
                GridRow {
                    Text("时间").foregroundStyle(.secondary)
                    Text(record.createdAt.formatted(date: .long, time: .standard))
                }
                GridRow {
                    Text("尺寸").foregroundStyle(.secondary)
                    Text("\(record.pixelWidth) × \(record.pixelHeight) px")
                        .monospacedDigit()
                }
                GridRow {
                    Text("文件大小").foregroundStyle(.secondary)
                    Text(ByteCountFormatter.string(
                        fromByteCount: Int64(record.byteSize),
                        countStyle: .file
                    ))
                    .monospacedDigit()
                }
                if !record.tags.isEmpty {
                    GridRow {
                        Text("标签").foregroundStyle(.secondary)
                        Text(record.tags.joined(separator: "、"))
                    }
                }
            }

            Divider()

            ocrSection

            Text("预览图上的文字可直接拖选复制（系统 Live Text，本机识别）。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let actionMessage {
                Text(actionMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 识别文字：本机 Vision 的结果放在这里，可选中复制；空态可手动识别。
    private var ocrSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("识别文字").foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if isRecognizing {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("复制文字") {
                    copyOCRText()
                }
                .disabled((record.ocrText ?? "").isEmpty)
                Button(record.ocrText == nil ? "识别文字" : "重新识别") {
                    recognizeText()
                }
                .disabled(isRecognizing || !library.canRecognizeText)
                .help("用系统 Vision 在本机识别，不联网")
            }

            if let text = record.ocrText, !text.isEmpty {
                ScrollView {
                    Text(text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            } else {
                Text(isRecognizing ? "正在识别…" : "未识别到文字")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func copyOCRText() {
        guard let text = record.ocrText, !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        actionMessage = "已复制识别文字"
    }

    private func recognizeText() {
        guard !isRecognizing else { return }
        isRecognizing = true
        Task {
            let recognized = await library.recognizeText(for: record)
            isRecognizing = false
            actionMessage = recognized ? "识别完成" : "未识别到文字"
        }
    }

    private func openEditor() {
        guard let preview, let editor else { return }
        editor.open(image: preview, title: "编辑截图")
    }

    private func copy() {
        Task {
            do {
                try await actions.copyImage(record)
                actionMessage = "已复制到剪贴板"
            } catch {
                errorMessage = message(for: error)
            }
        }
    }

    private func save() {
        Task {
            do {
                if try await actions.saveAsPNG(record) {
                    actionMessage = "已保存"
                }
            } catch {
                errorMessage = message(for: error)
            }
        }
    }

    private func toggleFavorite() {
        do {
            try library.toggleFavorite(record)
            actionMessage = record.isFavorite ? "已收藏" : "已取消收藏"
        } catch {
            errorMessage = message(for: error)
        }
    }

    private func delete() {
        isDeleting = true
        Task {
            do {
                try await library.delete(record)
                onDeleted()
            } catch {
                errorMessage = message(for: error)
            }
            isDeleting = false
        }
    }

    private func message(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return "操作失败（错误码 \((error as NSError).code)）。"
    }
}
