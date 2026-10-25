import AppKit
import CoreGraphics
import UniformTypeIdentifiers

/// 保存面板：单张「另存为 PNG」与多张「选择文件夹逐张写入」。
///
/// 文件名固定为 `IceShot-yyyy-MM-dd-HHmmss[-序号].png`；
/// 多图写入失败时会回滚已写文件，不留下半套结果。
@MainActor
enum SavePanel {
    /// 返回 false 表示用户取消；抛错表示编码或写入失败。
    static func savePNG(_ image: CGImage) throws -> Bool {
        let panel = NSSavePanel()
        panel.title = String(localized: "保存截图")
        panel.prompt = String(localized: "保存")
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = suggestedFileName()

        NSApplication.shared.activate()
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else {
            return false
        }

        let data = try ImageEncoder.pngData(from: image)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw CaptureError.saveFailed(code: (error as NSError).code)
        }
        return true
    }

    /// 选择文件夹后逐张写入 PNG；返回写入数量，0 表示用户取消。
    static func savePNGs(_ images: [CGImage]) throws -> Int {
        guard !images.isEmpty else {
            return 0
        }

        let panel = NSOpenPanel()
        panel.title = String(localized: "保存全部截图")
        panel.message = "将保存 \(images.count) 张 PNG 到所选文件夹"
        panel.prompt = String(localized: "保存")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        NSApplication.shared.activate()
        guard panel.runModal() == .OK, let directory = panel.url else {
            return 0
        }

        let baseName = suggestedBaseName()
        var written: [URL] = []

        do {
            for (index, image) in images.enumerated() {
                let url = try uniqueURL(
                    in: directory,
                    baseName: baseName,
                    index: index,
                    total: images.count
                )
                let data = try ImageEncoder.pngData(from: image)
                try data.write(to: url, options: .atomic)
                written.append(url)
            }
        } catch {
            for url in written {
                try? FileManager.default.removeItem(at: url)
            }
            throw CaptureError.saveFailed(code: (error as NSError).code)
        }

        return written.count
    }

    private static func uniqueURL(
        in directory: URL,
        baseName: String,
        index: Int,
        total: Int
    ) throws -> URL {
        let suffix = total > 1 ? "-\(index + 1)" : ""
        var candidate = directory.appendingPathComponent("\(baseName)\(suffix).png")
        var counter = 2

        while FileManager.default.fileExists(atPath: candidate.path) {
            guard counter <= 9999 else {
                throw CaptureError.saveFailed(code: 1)
            }
            candidate = directory.appendingPathComponent(
                "\(baseName)\(suffix)-\(counter).png"
            )
            counter += 1
        }
        return candidate
    }

    private static func suggestedFileName() -> String {
        "\(suggestedBaseName()).png"
    }

    private static func suggestedBaseName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "IceShot-\(formatter.string(from: Date()))"
    }
}
