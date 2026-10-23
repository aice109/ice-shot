import CoreGraphics
import Foundation

/// 上次区域选区的持久化描述；只存显示器 ID、显示器局部矩形与 scale，不存截图内容。
struct LastRegion: Codable, Equatable, Sendable {
    let displayID: UInt32
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let scale: Double

    init(displayID: CGDirectDisplayID, rect: CGRect, scale: CGFloat) {
        self.displayID = displayID
        self.x = rect.origin.x
        self.y = rect.origin.y
        self.width = rect.width
        self.height = rect.height
        self.scale = scale
    }

    var rect: CGRect {
        CGRect(
            x: CGFloat(x),
            y: CGFloat(y),
            width: CGFloat(width),
            height: CGFloat(height)
        )
    }

    func isValid(for display: DisplayDescriptor) -> Bool {
        let minimum = Double(1 / display.scale)
        guard display.id == displayID,
              abs(Double(display.scale) - scale) < 0.001,
              width > 0,
              height > 0,
              width >= minimum,
              height >= minimum else {
            return false
        }
        let bounds = CGRect(origin: .zero, size: display.pointSize)
        let tolerance: CGFloat = 0.5
        return rect.minX >= -tolerance
            && rect.minY >= -tolerance
            && rect.maxX <= bounds.maxX + tolerance
            && rect.maxY <= bounds.maxY + tolerance
    }
}

/// 「重复上次区域」的存取抽象，便于用内存实现做测试。
@MainActor
protocol LastRegionStoring {
    func load() -> LastRegion?
    func save(_ region: LastRegion)
    func clear()
}

/// 基于 `UserDefaults` 的持久化实现；只存几何，不存截图内容。
@MainActor
final class LastRegionStore: LastRegionStoring {
    private let key = "lastRegion"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> LastRegion? {
        guard let data = defaults.data(forKey: key) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(LastRegion.self, from: data)
        } catch {
            return nil
        }
    }

    func save(_ region: LastRegion) {
        guard let data = try? JSONEncoder().encode(region) else {
            return
        }
        defaults.set(data, forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}
