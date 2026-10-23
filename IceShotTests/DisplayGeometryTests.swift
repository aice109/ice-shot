import CoreGraphics
import Testing
@testable import IceShot

/// 显示器坐标转换：AppKit 左下原点 ↔ CoreGraphics 左上原点，含多屏偏移。
@MainActor
struct DisplayGeometryTests {
    @Test func appKitRectConvertsToCGGlobal() {
        let appKit = CGRect(x: 100, y: 200, width: 300, height: 150)
        let cg = ScreenGeometry.cgRect(fromAppKit: appKit, primaryMaxY: 1000)
        #expect(cg == CGRect(x: 100, y: 650, width: 300, height: 150))
    }

    @Test func cgRectRoundTripsToAppKit() {
        let appKit = CGRect(x: -120, y: 40, width: 800, height: 600)
        let cg = ScreenGeometry.cgRect(fromAppKit: appKit, primaryMaxY: 1440)
        let roundTrip = ScreenGeometry.appKitRect(fromCG: cg, primaryMaxY: 1440)
        #expect(roundTrip == appKit)
    }

    @Test func displayLocalRectHandlesNegativeOrigin() {
        let display = DisplayDescriptor(
            id: 2,
            frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            appKitFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            scale: 2,
            localizedName: "Left"
        )
        let local = ScreenGeometry.displayLocalRect(
            fromCG: CGRect(x: -1870, y: 60, width: 200, height: 100),
            display: display
        )
        #expect(local == CGRect(x: 50, y: 60, width: 200, height: 100))
    }

    @Test func pixelRectUsesScaleAndRoundsEdges() {
        let rect = CGRect(x: 10.25, y: 20.75, width: 100.5, height: 50.25)
        let pixels = ScreenGeometry.pixelRect(fromDisplayLocal: rect, scale: 2)
        #expect(pixels == CGRect(x: 21, y: 42, width: 201, height: 100))
    }

    @Test func pixelRectKeepsOnePixelForSubPointSelection() {
        let pixels = ScreenGeometry.pixelRect(
            fromDisplayLocal: CGRect(x: 10, y: 10, width: 0.25, height: 0.25),
            scale: 2
        )
        #expect(pixels.width >= 1)
        #expect(pixels.height >= 1)
    }

    @Test func snapRectKeepsAtLeastOnePixel() {
        let rect = CGRect(x: 10.1, y: 10.1, width: 0.01, height: 0.01)
        let snapped = ScreenGeometry.snapRect(rect, scale: 2)
        #expect(snapped.width == 0.5)
        #expect(snapped.height == 0.5)
    }

    @Test func displayLocalPointRoundTripsToCGGlobal() {
        let display = DisplayDescriptor(
            id: 3,
            frame: CGRect(x: -1280, y: 0, width: 1280, height: 800),
            appKitFrame: CGRect(x: -1280, y: 280, width: 1280, height: 800),
            scale: 2,
            localizedName: "Left"
        )
        let cgPoint = ScreenGeometry.cgPoint(
            fromDisplayLocal: CGPoint(x: 120, y: 80),
            display: display
        )
        #expect(cgPoint == CGPoint(x: -1160, y: 80))
        #expect(
            ScreenGeometry.displayLocalPoint(fromCG: cgPoint, display: display)
                == CGPoint(x: 120, y: 80)
        )
    }

    @Test func normalizedRectHandlesReverseDrag() {
        let rect = ScreenGeometry.normalizedRect(
            from: CGPoint(x: 300, y: 400),
            to: CGPoint(x: 100, y: 50)
        )
        #expect(rect == CGRect(x: 100, y: 50, width: 200, height: 350))
    }
}
