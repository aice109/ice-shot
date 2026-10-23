import SwiftUI

/// 历史列表的单行：缩略图 + 来源 / 时间 / 尺寸。
///
/// 整行合并为一个无障碍元素，VoiceOver 一次读出完整信息，
/// 而不是把缩略图和几段文字拆成多个停靠点。
struct LibraryRow: View {
    let record: ScreenshotRecord
    let library: LibraryStore

    var body: some View {
        HStack(spacing: 10) {
            LibraryThumbnail(record: record, library: library)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Label(record.source.displayName, systemImage: record.source.symbolName)
                        .font(.callout)
                        .lineLimit(1)
                    if record.isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.caption)
                            .foregroundStyle(.pink)
                            .accessibilityLabel("已收藏")
                    }
                }
                Text(dateText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text("\(record.pixelWidth) × \(record.pixelHeight)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(record.source.displayName)，\(record.createdAt.formatted(date: .abbreviated, time: .shortened))，\(record.pixelWidth) 乘 \(record.pixelHeight) 像素\(record.isFavorite ? "，已收藏" : "")"
        )
    }

    private var dateText: String {
        if Calendar.current.isDateInToday(record.createdAt) {
            return record.createdAt.formatted(date: .omitted, time: .shortened)
        }
        return record.createdAt.formatted(date: .abbreviated, time: .omitted)
    }
}

/// 列表缩略图：异步读取 JPEG 缩略图，加载失败时显示占位图标而不是空白。
private struct LibraryThumbnail: View {
    let record: ScreenshotRecord
    let library: LibraryStore

    @State private var image: CGImage?
    @State private var isLoading = true

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.quaternary)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 72, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityHidden(true)
        .task(id: record.id) {
            isLoading = true
            image = await library.image(for: record, thumbnail: true)
            isLoading = false
        }
    }
}
