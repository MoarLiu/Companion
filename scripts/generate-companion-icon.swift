#!/usr/bin/env swift
import AppKit
import Foundation

private let fileManager = FileManager.default
private let root = URL(fileURLWithPath: fileManager.currentDirectoryPath)
private let assets = root.appendingPathComponent("assets", isDirectory: true)
private let iconset = assets.appendingPathComponent("Companion.iconset", isDirectory: true)

private let appLogoSource = assets.appendingPathComponent("Companion APP-LOGO.png")
private let menuBarSource = assets.appendingPathComponent("菜单栏-icon.png")
private let preview = assets.appendingPathComponent("companion-icon-1024.png")
private let icns = assets.appendingPathComponent("companion-icon.icns")
private let menuBarTemplate = assets.appendingPathComponent("companion-menubar-template.png")

private enum AssetError: LocalizedError {
    case missingImage(URL)
    case bitmapCreationFailed(String)
    case pngEncodingFailed(String)
    case iconutilFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .missingImage(let url):
            return "Missing image: \(url.path)"
        case .bitmapCreationFailed(let name):
            return "Could not create bitmap for \(name)"
        case .pngEncodingFailed(let name):
            return "Could not encode PNG for \(name)"
        case .iconutilFailed(let status):
            return "iconutil failed with status \(status)"
        }
    }
}

private struct PixelCrop {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
}

private struct PixelBounds {
    var minX: Int
    var minY: Int
    var maxX: Int
    var maxY: Int

    var width: Int { maxX - minX + 1 }
    var height: Int { maxY - minY + 1 }
    var centerX: CGFloat { CGFloat(minX + maxX) / 2 }
    var centerY: CGFloat { CGFloat(minY + maxY) / 2 }
}

private struct PixelMask {
    let width: Int
    let height: Int
    let values: [Bool]

    func contains(x: Int, y: Int) -> Bool {
        values[y * width + x]
    }
}

private enum RenderMode {
    case color(backgroundMask: PixelMask?)
    case lightTemplate
}

private func loadBitmap(_ url: URL) throws -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(data: try Data(contentsOf: url)) else {
        throw AssetError.missingImage(url)
    }
    return rep
}

private func luminance(_ color: NSColor) -> CGFloat {
    color.redComponent * 0.2126 + color.greenComponent * 0.7152 + color.blueComponent * 0.0722
}

private func whiteDistance(_ color: NSColor) -> CGFloat {
    max(
        abs(color.redComponent - 1),
        abs(color.greenComponent - 1),
        abs(color.blueComponent - 1)
    )
}

private func clamped(_ value: CGFloat, lower: CGFloat = 0, upper: CGFloat = 1) -> CGFloat {
    max(lower, min(upper, value))
}

private func pngData(from source: NSBitmapImageRep, crop: PixelCrop, outputWidth: Int, outputHeight: Int, mode: RenderMode, name: String) throws -> Data {
    guard let outputRep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: outputWidth,
        pixelsHigh: outputHeight,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: [],
        bytesPerRow: 0,
        bitsPerPixel: 0
    ),
    let output = outputRep.bitmapData
    else {
        throw AssetError.bitmapCreationFailed(name)
    }

    for y in 0..<outputHeight {
        for x in 0..<outputWidth {
            let sourceX = min(source.pixelsWide - 1, max(0, Int(crop.x + CGFloat(x) * crop.width / CGFloat(outputWidth))))
            let sourceY = min(source.pixelsHigh - 1, max(0, Int(crop.y + CGFloat(y) * crop.height / CGFloat(outputHeight))))
            let color = source.colorAt(x: sourceX, y: sourceY)?.usingColorSpace(.deviceRGB) ?? .clear
            let offset = y * outputRep.bytesPerRow + x * 4
            switch mode {
            case .lightTemplate:
                let alpha = clamped((luminance(color) - 0.42) / 0.26) * color.alphaComponent
                output[offset] = 0
                output[offset + 1] = 0
                output[offset + 2] = 0
                output[offset + 3] = UInt8(alpha * 255)
            case .color(let backgroundMask):
                if backgroundMask?.contains(x: sourceX, y: sourceY) == true {
                    output[offset] = 0
                    output[offset + 1] = 0
                    output[offset + 2] = 0
                    output[offset + 3] = 0
                    continue
                }

                output[offset] = UInt8(color.redComponent * 255)
                output[offset + 1] = UInt8(color.greenComponent * 255)
                output[offset + 2] = UInt8(color.blueComponent * 255)
                output[offset + 3] = UInt8(color.alphaComponent * 255)
            }
        }
    }

    guard let data = outputRep.representation(using: .png, properties: [:]) else {
        throw AssetError.pngEncodingFailed(name)
    }
    return data
}

private func bounds(in source: NSBitmapImageRep, matching predicate: (NSColor) -> Bool) -> PixelBounds? {
    var minX = source.pixelsWide
    var minY = source.pixelsHigh
    var maxX = 0
    var maxY = 0

    for y in 0..<source.pixelsHigh {
        for x in 0..<source.pixelsWide {
            guard let color = source.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                continue
            }

            guard predicate(color) else {
                continue
            }

            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }
    }

    guard minX <= maxX, minY <= maxY else {
        return nil
    }

    return PixelBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
}

private func centeredRect(source: NSBitmapImageRep, centerX: CGFloat, centerY: CGFloat, width: CGFloat, height: CGFloat) -> PixelCrop {
    PixelCrop(
        x: max(0, min(CGFloat(source.pixelsWide) - width, centerX - width / 2)),
        y: max(0, min(CGFloat(source.pixelsHigh) - height, centerY - height / 2)),
        width: width,
        height: height
    )
}

private func appIconCrop(for source: NSBitmapImageRep) -> PixelCrop {
    guard let bounds = bounds(in: source, matching: { color in
        whiteDistance(color) > 0.035 && color.alphaComponent > 0.01
    }) else {
        let side = CGFloat(min(source.pixelsWide, source.pixelsHigh))
        return PixelCrop(
            x: (CGFloat(source.pixelsWide) - side) / 2,
            y: (CGFloat(source.pixelsHigh) - side) / 2,
            width: side,
            height: side
        )
    }

    let width = CGFloat(bounds.width)
    let height = CGFloat(bounds.height)
    let side = min(
        CGFloat(min(source.pixelsWide, source.pixelsHigh)),
        max(width, height) * 1.025
    )
    return centeredRect(source: source, centerX: bounds.centerX, centerY: bounds.centerY, width: side, height: side)
}

private func menuBarCrop(for source: NSBitmapImageRep, aspectRatio: CGFloat) -> PixelCrop {
    guard let bounds = bounds(in: source, matching: { color in
        luminance(color) > 0.52 && color.alphaComponent > 0.01
    }) else {
        return PixelCrop(x: 0, y: 0, width: CGFloat(source.pixelsWide), height: CGFloat(source.pixelsHigh))
    }

    let paddedWidth = CGFloat(bounds.width) * 1.13
    let paddedHeight = CGFloat(bounds.height) * 1.16
    let width: CGFloat
    let height: CGFloat
    if paddedWidth / paddedHeight < aspectRatio {
        height = paddedHeight
        width = paddedHeight * aspectRatio
    } else {
        width = paddedWidth
        height = paddedWidth / aspectRatio
    }

    return centeredRect(
        source: source,
        centerX: bounds.centerX,
        centerY: bounds.centerY,
        width: min(width, CGFloat(source.pixelsWide)),
        height: min(height, CGFloat(source.pixelsHigh))
    )
}

private func appIconBackgroundMask(for source: NSBitmapImageRep) -> PixelMask {
    let width = source.pixelsWide
    let height = source.pixelsHigh
    var visited = Array(repeating: false, count: width * height)
    var queue: [(Int, Int)] = []

    func isEdgeBackground(x: Int, y: Int) -> Bool {
        guard let color = source.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
            return false
        }
        return color.alphaComponent < 0.01 || whiteDistance(color) <= 0.018
    }

    func enqueue(_ x: Int, _ y: Int) {
        guard x >= 0, x < width, y >= 0, y < height else {
            return
        }
        let index = y * width + x
        guard !visited[index], isEdgeBackground(x: x, y: y) else {
            return
        }
        visited[index] = true
        queue.append((x, y))
    }

    for x in 0..<width {
        enqueue(x, 0)
        enqueue(x, height - 1)
    }
    for y in 0..<height {
        enqueue(0, y)
        enqueue(width - 1, y)
    }

    var cursor = 0
    while cursor < queue.count {
        let (x, y) = queue[cursor]
        cursor += 1
        enqueue(x + 1, y)
        enqueue(x - 1, y)
        enqueue(x, y + 1)
        enqueue(x, y - 1)
    }

    return PixelMask(width: width, height: height, values: visited)
}

private func writeAppIconAssets() throws {
    let source = try loadBitmap(appLogoSource)
    let crop = appIconCrop(for: source)
    let backgroundMask = appIconBackgroundMask(for: source)
    let iconFiles: [(String, Int)] = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024)
    ]

    try? fileManager.removeItem(at: iconset)
    try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
    for (name, size) in iconFiles {
        let data = try pngData(
            from: source,
            crop: crop,
            outputWidth: size,
            outputHeight: size,
            mode: .color(backgroundMask: backgroundMask),
            name: name
        )
        try data.write(to: iconset.appendingPathComponent(name), options: .atomic)
        if size == 1024 {
            try data.write(to: preview, options: .atomic)
        }
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", "-o", icns.path, iconset.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw AssetError.iconutilFailed(process.terminationStatus)
    }
    try? fileManager.removeItem(at: iconset)
}

private func writeMenuBarTemplate() throws {
    let source = try loadBitmap(menuBarSource)
    let outputWidth = 768
    let outputHeight = 512
    let crop = menuBarCrop(for: source, aspectRatio: CGFloat(outputWidth) / CGFloat(outputHeight))
    let data = try pngData(
        from: source,
        crop: crop,
        outputWidth: outputWidth,
        outputHeight: outputHeight,
        mode: .lightTemplate,
        name: "menu bar template"
    )
    try data.write(to: menuBarTemplate, options: .atomic)
}

try fileManager.createDirectory(at: assets, withIntermediateDirectories: true)
try writeAppIconAssets()
try writeMenuBarTemplate()

print("Generated: \(preview.path)")
print("Generated: \(icns.path)")
print("Generated: \(menuBarTemplate.path)")
