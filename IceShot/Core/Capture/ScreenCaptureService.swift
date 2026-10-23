import CoreGraphics
import Foundation
import ScreenCaptureKit

/// ScreenCaptureKit 实现：整屏 / 单显示器 / 单窗口截图，以及窗口目录。
///
/// 只在用户主动触发时调用，不做后台连续采集；截图不写入磁盘，
/// 需要持久化时由 `LibraryStore` 显式保存。
@MainActor
final class ScreenCaptureService: ScreenCapturing, WindowCatalogProviding {
    /// 可共享内容（显示器 / 窗口快照）的复用窗口。
    private static let contentCacheLifetime: TimeInterval = 1.5
    private var cachedContent: (content: SCShareableContent, date: Date)?

    /// 同时截取全部显示器，返回顺序与系统显示器顺序一致。
    /// 任意一块屏不可用就整体失败，避免「全部显示器」静默少图。
    func captureDisplayFrames() async throws -> [DisplayFrame] {
        let descriptors = ScreenGeometry.makeDescriptors()
        guard !descriptors.isEmpty else {
            throw CaptureError.noDisplays
        }

        let content = try await shareableContent()
        var frames: [DisplayFrame] = []
        frames.reserveCapacity(descriptors.count)

        for descriptor in descriptors {
            guard let display = content.displays.first(where: { $0.displayID == descriptor.id }) else {
                throw CaptureError.displayUnavailable
            }
            let image = try await captureImage(display: display, descriptor: descriptor)
            frames.append(DisplayFrame(display: descriptor, image: image))
        }

        return frames
    }

    /// 截取指定显示器；用于全屏截图与窗口截图后的回退路径。
    func captureDisplay(_ displayID: CGDirectDisplayID) async throws -> CGImage {
        guard let descriptor = ScreenGeometry.makeDescriptors().first(where: { $0.id == displayID }) else {
            throw CaptureError.displayUnavailable
        }
        let content = try await shareableContent()
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayUnavailable
        }
        let image = try await captureImage(display: display, descriptor: descriptor)
        return image
    }

    /// 截取单个窗口；`includeShadow` 为 false 时使用 SCK 的去阴影选项。
    /// 包含子窗口（菜单 / 弹层），否则下拉菜单等会缺失。
    func captureWindow(_ windowID: CGWindowID, includeShadow: Bool) async throws -> CGImage {
        let content = try await shareableContent()
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.windowUnavailable
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = windowPixelScale(filter: filter, window: window)
        let contentSize = filter.contentRect.width > 0 && filter.contentRect.height > 0
            ? filter.contentRect.size
            : window.frame.size

        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((contentSize.width * scale).rounded()))
        configuration.height = max(1, Int((contentSize.height * scale).rounded()))
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.scalesToFit = false
        configuration.preservesAspectRatio = true
        configuration.ignoreShadowsSingleWindow = !includeShadow
        configuration.includeChildWindows = true

        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            // 抓到的是「只有一小块不透明、其余全透明」的图，说明这扇窗没有独立的可截内容
            // （通知横幅这类系统 overlay 就是这种形态）。当作成功返回只会产出空白图。
            guard !BlankFrameDetector.isBlank(image) else {
                throw CaptureError.captureBlank
            }
            return image
        } catch {
            throw Self.map(error)
        }
    }

    /// 可截取窗口目录，已按「前台 → 后台」排序，供窗口选择浮层命中测试。
    func windowCatalog() async throws -> [WindowDescriptor] {
        let displays = ScreenGeometry.makeDescriptors()
        guard !displays.isEmpty else {
            throw CaptureError.noDisplays
        }

        let content = try await shareableContent()
        let descriptors = content.windows.compactMap { window -> WindowDescriptor? in
            guard let application = window.owningApplication else {
                return nil
            }
            return WindowDescriptor(
                id: window.windowID,
                frame: window.frame,
                ownerPID: application.processID,
                ownerName: application.applicationName,
                ownerBundleID: application.bundleIdentifier,
                title: window.title,
                layer: window.windowLayer,
                isOnScreen: window.isOnScreen,
                isActive: window.isActive
            )
        }

        let selectable = WindowFilter.selectable(
            windows: descriptors,
            displayFrames: displays.map(\.frame)
        )
        let ordered = WindowOrdering.sorted(
            selectable,
            frontToBackIDs: Self.frontToBackWindowIDs()
        )
        guard !ordered.isEmpty else {
            throw CaptureError.noWindows
        }
        return ordered
    }

    func captureRegion(
        displayID: CGDirectDisplayID,
        rect: CGRect
    ) async throws -> CGImage {
        guard let descriptor = ScreenGeometry.makeDescriptors().first(where: {
            $0.id == displayID
        }) else {
            throw CaptureError.displayUnavailable
        }
        guard rect.width >= 1, rect.height >= 1 else {
            throw CaptureError.invalidSelection
        }
        let content = try await shareableContent()
        guard let display = content.displays.first(where: {
            $0.displayID == displayID
        }) else {
            throw CaptureError.displayUnavailable
        }

        // 长截图在浮层可见时反复抓取：必须排除 IceShot 自己的窗口（选区框、HUD）。
        let ownApplications = content.applications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: ownApplications,
            exceptingWindows: []
        )

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = rect
        configuration.width = Int((rect.width * descriptor.scale).rounded())
        configuration.height = Int((rect.height * descriptor.scale).rounded())
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.scalesToFit = false

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        return image
    }

    private func captureImage(
        display: SCDisplay,
        descriptor: DisplayDescriptor
    ) async throws -> CGImage {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = Int(descriptor.pixelSize.width)
        configuration.height = Int(descriptor.pixelSize.height)
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.scalesToFit = false
        configuration.preservesAspectRatio = true

        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            return image
        } catch {
            throw Self.map(error)
        }
    }

    private func shareableContent() async throws -> SCShareableContent {
        // 一次截图流程里会连续要窗口目录与截图（先抓帧、再拿窗口列表、再抓选中窗口），
        // 每次都重新枚举是一次多余的系统往返（几十毫秒）。缓存 1.5 秒既省掉重复，
        // 又足够短：点击窗口时用的仍是流程开始时的窗口快照。
        if let cached = cachedContent,
           Date().timeIntervalSince(cached.date) < Self.contentCacheLifetime {
            return cached.content
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            cachedContent = (content: content, date: Date())
            return content
        } catch {
            throw Self.map(error)
        }
    }

    /// 优先用 SCK 给出的 point→pixel 比例；极少数窗口拿不到时再按所在显示器推断。
    private func windowPixelScale(filter: SCContentFilter, window: SCWindow) -> CGFloat {
        let scale = CGFloat(filter.pointPixelScale)
        guard scale > 0 else {
            return fallbackScale(for: window)
        }
        return scale
    }

    private func fallbackScale(for window: SCWindow) -> CGFloat {
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        return ScreenGeometry.makeDescriptors().first { $0.frame.contains(center) }?.scale ?? 1
    }

    /// CGWindowList 的 on-screen 列表按前到后排列，用来给 SCK 窗口目录补上 z-order。
    private static func frontToBackWindowIDs() -> [CGWindowID] {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }
        return info.compactMap { entry in
            (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
    }

    /// 把 SCK 的私有错误码映射成可行动的错误：
    /// -3801 = 无权限；-3813 / -3814 = 显示器不可用。
    private static func map(_ error: Error) -> CaptureError {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain {
            if nsError.code == -3801 {
                return .permissionDenied
            }
            if nsError.code == -3813 || nsError.code == -3814 {
                return .displayUnavailable
            }
        }
        return .captureFailed(code: nsError.code)
    }
}
