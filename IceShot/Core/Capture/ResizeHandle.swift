import CoreGraphics

/// 选区 8 个缩放手柄；位置以显示器局部坐标表示。
enum ResizeHandle: CaseIterable, Identifiable {
    case topLeft
    case top
    case topRight
    case right
    case bottomRight
    case bottom
    case bottomLeft
    case left

    var id: Self { self }

    /// 光标提示用的统一方向。
    var axis: ResizeAxis {
        switch self {
        case .topLeft: return .topLeading
        case .top: return .top
        case .topRight: return .topTrailing
        case .right: return .trailing
        case .bottomRight: return .bottomTrailing
        case .bottom: return .bottom
        case .bottomLeft: return .bottomLeading
        case .left: return .leading
        }
    }

    /// 手柄中心点在给定选区中的位置（左上原点，y 向下）。
    func position(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft:
            return CGPoint(x: rect.minX, y: rect.minY)
        case .top:
            return CGPoint(x: rect.midX, y: rect.minY)
        case .topRight:
            return CGPoint(x: rect.maxX, y: rect.minY)
        case .right:
            return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight:
            return CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom:
            return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft:
            return CGPoint(x: rect.minX, y: rect.maxY)
        case .left:
            return CGPoint(x: rect.minX, y: rect.midY)
        }
    }
}
