import Foundation

/// 文字识别的开关与读取入口。
///
/// 只在**本机**用系统 Vision 识别，不联网、不上传；默认开启，因为搜索历史时
/// 「按图片里的文字找」是最常用的入口之一。关闭后新截图不再自动识别，
/// 仍可在历史详情里手动点「识别文字」。
enum OCRPreferences {
    static let autoRecognizeKey = "ocrAutoRecognize"

    static var autoRecognizeEnabledByDefault: Bool { true }

    static var isAutoRecognizeEnabled: Bool {
        UserDefaults.standard.object(forKey: autoRecognizeKey) as? Bool
            ?? autoRecognizeEnabledByDefault
    }
}

/// 识别设置的读取抽象：历史库通过它判断要不要自动识别。
///
/// 单独抽一层是为了让单测能注入固定值，不必改全局 `UserDefaults`
/// （否则并行测试之间会互相影响开关状态）。
protocol OCRSettingsProviding: Sendable {
    var isAutoRecognizeEnabled: Bool { get }
}

/// 生产实现：读 `UserDefaults`，设置界面改开关立即生效。
struct UserDefaultsOCRSettings: OCRSettingsProviding {
    var isAutoRecognizeEnabled: Bool {
        OCRPreferences.isAutoRecognizeEnabled
    }
}
