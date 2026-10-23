import CoreGraphics
import Foundation
import Testing
@testable import IceShot

/// 「重复上次区域」的校验：显示器 ID / scale / 边界任一变化都应判为失效。
@MainActor
struct LastRegionTests {
    private func display(scale: CGFloat = 2) -> DisplayDescriptor {
        DisplayDescriptor(
            id: 7,
            frame: CGRect(x: 0, y: 0, width: 960, height: 540),
            appKitFrame: CGRect(x: 0, y: 0, width: 960, height: 540),
            scale: scale,
            localizedName: "Main"
        )
    }

    @Test func validRegionMatchesDisplayAndScale() {
        let region = LastRegion(
            displayID: 7,
            rect: CGRect(x: 100, y: 80, width: 200, height: 120),
            scale: 2
        )
        #expect(region.isValid(for: display(scale: 2)))
        #expect(region.rect == CGRect(x: 100, y: 80, width: 200, height: 120))
    }

    @Test func scaleOrDisplayMismatchIsInvalid() {
        let region = LastRegion(
            displayID: 7,
            rect: CGRect(x: 100, y: 80, width: 200, height: 120),
            scale: 2
        )
        #expect(!region.isValid(for: display(scale: 1)))

        let otherDisplay = DisplayDescriptor(
            id: 8,
            frame: CGRect(x: 0, y: 0, width: 960, height: 540),
            appKitFrame: CGRect(x: 0, y: 0, width: 960, height: 540),
            scale: 2,
            localizedName: "Other"
        )
        #expect(!region.isValid(for: otherDisplay))
    }

    @Test func outOfBoundsRegionIsInvalid() {
        let region = LastRegion(
            displayID: 7,
            rect: CGRect(x: 900, y: 80, width: 200, height: 120),
            scale: 2
        )
        #expect(!region.isValid(for: display(scale: 2)))
    }

    @Test func storeRoundTripsAndClears() throws {
        let suiteName = "IceShotTests.LastRegion.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = LastRegionStore(defaults: defaults)
        #expect(store.load() == nil)

        let region = LastRegion(
            displayID: 7,
            rect: CGRect(x: 10, y: 20, width: 300, height: 200),
            scale: 2
        )
        store.save(region)
        #expect(store.load() == region)

        store.clear()
        #expect(store.load() == nil)
    }
}
