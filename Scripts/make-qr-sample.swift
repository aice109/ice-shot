#!/usr/bin/env swift
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// 生成一张用于手工验收「取字 / 二维码」的样图。
///
/// 用法：`swift Scripts/make-qr-sample.swift /tmp/iceshot-qr.png`
/// 输出：白底图上有一个二维码（内容为 URL）+ 一行中文和一行英文，便于同时验证
/// 「拖选文字复制」与「点按二维码复制」。
let arguments = CommandLine.arguments
let outputPath = arguments.count > 1 ? arguments[1] : "/tmp/iceshot-qr-sample.png"
let payload = arguments.count > 2 ? arguments[2] : "https://example.com/iceshot?code=42"

let size = CGSize(width: 720, height: 560)
let image = NSImage(size: size)
image.lockFocus()
NSColor.white.setFill()
NSRect(origin: .zero, size: size).fill()

// 二维码居中偏上
let filter = CIFilter.qrCodeGenerator()
filter.message = Data(payload.utf8)
filter.correctionLevel = "H"
if let codeImage = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
   let cgImage = CIContext().createCGImage(codeImage, from: codeImage.extent) {
    let rect = NSRect(x: (size.width - 360) / 2, y: 160, width: 360, height: 360)
    NSGraphicsContext.current?.cgContext.draw(cgImage, in: rect)
}

let text = "示例文字：发票号码 12345\nSample text: Total 42.00 USD"
(text as NSString).draw(
    in: NSRect(x: 40, y: 40, width: size.width - 80, height: 90),
    withAttributes: [
        .font: NSFont.systemFont(ofSize: 22, weight: .medium),
        .foregroundColor: NSColor.black,
    ]
)
image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("生成失败\n".utf8))
    exit(1)
}
do {
    try png.write(to: URL(fileURLWithPath: outputPath))
    print("已生成：\(outputPath)")
    print("二维码内容：\(payload)")
} catch {
    FileHandle.standardError.write(Data("写入失败：\(error.localizedDescription)\n".utf8))
    exit(1)
}
