import AppKit
import Foundation
import ImageIO

private let cellWidth = 192
private let cellHeight = 208
private let columns = 8
private let coreRows = 13
private let totalRows = 16
private let sourceIdleFrames = 6

guard CommandLine.arguments.count == 3 else {
    fputs("usage: swift scripts/generate-edge-sprites.swift <source-spritesheet.png> <output-spritesheet.png>\n", stderr)
    exit(2)
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fputs("could not read source spritesheet: \(sourceURL.path)\n", stderr)
    exit(1)
}

guard sheet.width == cellWidth * columns,
      sheet.height % cellHeight == 0,
      sheet.height >= coreRows * cellHeight else {
    fputs("unexpected spritesheet geometry: \(sheet.width)x\(sheet.height)\n", stderr)
    exit(1)
}

let coreHeight = coreRows * cellHeight
guard let coreSheet = sheet.cropping(to: CGRect(x: 0, y: 0, width: sheet.width, height: coreHeight)) else {
    fputs("could not crop core spritesheet rows\n", stderr)
    exit(1)
}

let colorSpace = CGColorSpaceCreateDeviceRGB()
let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

guard let context = CGContext(
    data: nil,
    width: sheet.width,
    height: totalRows * cellHeight,
    bitsPerComponent: 8,
    bytesPerRow: sheet.width * 4,
    space: colorSpace,
    bitmapInfo: bitmapInfo
) else {
    fputs("could not create output context\n", stderr)
    exit(1)
}

context.clear(CGRect(x: 0, y: 0, width: sheet.width, height: totalRows * cellHeight))
context.interpolationQuality = .high
let coreYOffset = CGFloat((totalRows - coreRows) * cellHeight)
context.draw(coreSheet, in: CGRect(
    x: 0,
    y: coreYOffset,
    width: CGFloat(sheet.width),
    height: CGFloat(coreHeight)
))

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

func cellY(row: Int) -> CGFloat {
    CGFloat(totalRows - row - 1) * CGFloat(cellHeight)
}

func point(_ x: CGFloat, _ y: CGFloat, cellX: CGFloat, cellY: CGFloat) -> CGPoint {
    CGPoint(x: cellX + x, y: cellY + y)
}

func drawTopBar(cellX: CGFloat, cellY: CGFloat, phase: CGFloat) {
    let shimmer = (sin(phase) + 1) * 0.08
    let railY: CGFloat = 194
    context.setStrokeColor(color(255, 230, 168, 0.72 + shimmer))
    context.setLineWidth(7)
    context.setLineCap(.round)
    context.move(to: point(18, railY, cellX: cellX, cellY: cellY))
    context.addLine(to: point(174, railY, cellX: cellX, cellY: cellY))
    context.strokePath()

    context.setStrokeColor(color(196, 125, 107, 0.8))
    context.setLineWidth(2)
    context.move(to: point(20, railY - 4, cellX: cellX, cellY: cellY))
    context.addLine(to: point(172, railY - 4, cellX: cellX, cellY: cellY))
    context.strokePath()
}

func drawParachuteFrame(index: Int) {
    let rowY = cellY(row: 13)
    let phase = (CGFloat(index) / CGFloat(columns)) * CGFloat.pi * 2
    let sway = sin(phase) * 8
    let bob = sin(phase + CGFloat.pi / 4) * 4
    let tilt = sin(phase) * 3
    let cellX = CGFloat(index * cellWidth)

    guard let petFrame = sheet.cropping(to: CGRect(
        x: (index % sourceIdleFrames) * cellWidth,
        y: 0,
        width: cellWidth,
        height: cellHeight
    )) else {
        return
    }

    context.saveGState()

    let canopyCenterX: CGFloat = 96 + sway * 0.35
    let canopyBottomY: CGFloat = 152 + bob * 0.25
    let canopyTopY: CGFloat = 205 + bob * 0.15
    let canopyLeftX: CGFloat = 34 + sway * 0.2
    let canopyRightX: CGFloat = 158 + sway * 0.2

    let canopy = CGMutablePath()
    canopy.move(to: point(canopyLeftX, canopyBottomY, cellX: cellX, cellY: rowY))
    canopy.addCurve(
        to: point(canopyCenterX, canopyTopY, cellX: cellX, cellY: rowY),
        control1: point(canopyLeftX + 8 + tilt, canopyBottomY + 34, cellX: cellX, cellY: rowY),
        control2: point(canopyCenterX - 36 + tilt, canopyTopY + 4, cellX: cellX, cellY: rowY)
    )
    canopy.addCurve(
        to: point(canopyRightX, canopyBottomY, cellX: cellX, cellY: rowY),
        control1: point(canopyCenterX + 36 + tilt, canopyTopY + 4, cellX: cellX, cellY: rowY),
        control2: point(canopyRightX - 8 + tilt, canopyBottomY + 34, cellX: cellX, cellY: rowY)
    )
    canopy.addCurve(
        to: point(canopyCenterX + 32, canopyBottomY - 5, cellX: cellX, cellY: rowY),
        control1: point(canopyRightX - 10, canopyBottomY - 8, cellX: cellX, cellY: rowY),
        control2: point(canopyCenterX + 48, canopyBottomY - 8, cellX: cellX, cellY: rowY)
    )
    canopy.addCurve(
        to: point(canopyCenterX, canopyBottomY - 2, cellX: cellX, cellY: rowY),
        control1: point(canopyCenterX + 20, canopyBottomY + 2, cellX: cellX, cellY: rowY),
        control2: point(canopyCenterX + 12, canopyBottomY + 2, cellX: cellX, cellY: rowY)
    )
    canopy.addCurve(
        to: point(canopyCenterX - 32, canopyBottomY - 5, cellX: cellX, cellY: rowY),
        control1: point(canopyCenterX - 12, canopyBottomY + 2, cellX: cellX, cellY: rowY),
        control2: point(canopyCenterX - 20, canopyBottomY + 2, cellX: cellX, cellY: rowY)
    )
    canopy.addCurve(
        to: point(canopyLeftX, canopyBottomY, cellX: cellX, cellY: rowY),
        control1: point(canopyCenterX - 48, canopyBottomY - 8, cellX: cellX, cellY: rowY),
        control2: point(canopyLeftX + 10, canopyBottomY - 8, cellX: cellX, cellY: rowY)
    )
    canopy.closeSubpath()

    context.addPath(canopy)
    context.setFillColor(color(255, 225, 151, 0.96))
    context.fillPath()

    context.addPath(canopy)
    context.setStrokeColor(color(232, 139, 128, 0.95))
    context.setLineWidth(3)
    context.setLineJoin(.round)
    context.strokePath()

    context.setStrokeColor(color(246, 174, 148, 0.75))
    context.setLineWidth(1.5)
    for rib in [-0.55, -0.28, 0.0, 0.28, 0.55] as [CGFloat] {
        context.move(to: point(canopyCenterX, canopyBottomY - 1, cellX: cellX, cellY: rowY))
        context.addLine(to: point(canopyCenterX + rib * 72, canopyBottomY + 33 - abs(rib) * 10, cellX: cellX, cellY: rowY))
        context.strokePath()
    }

    let anchorY: CGFloat = 78 + bob
    let anchorLeftX: CGFloat = 75 + sway
    let anchorRightX: CGFloat = 117 + sway
    context.setStrokeColor(color(130, 88, 72, 0.72))
    context.setLineWidth(1.7)
    for startX in [canopyLeftX + 16, canopyCenterX - 20, canopyCenterX + 20, canopyRightX - 16] {
        let endX = startX < canopyCenterX ? anchorLeftX : anchorRightX
        context.move(to: point(startX, canopyBottomY - 1, cellX: cellX, cellY: rowY))
        context.addLine(to: point(endX, anchorY, cellX: cellX, cellY: rowY))
        context.strokePath()
    }

    let scale: CGFloat = 0.72
    let petWidth = CGFloat(cellWidth) * scale
    let petHeight = CGFloat(cellHeight) * scale
    let petRect = CGRect(
        x: cellX + (CGFloat(cellWidth) - petWidth) / 2 + sway,
        y: rowY + 2 + bob,
        width: petWidth,
        height: petHeight
    )
    context.draw(petFrame, in: petRect)

    context.setStrokeColor(color(122, 76, 66, 0.78))
    context.setLineWidth(2)
    context.setLineCap(.round)
    context.move(to: point(77 + sway, 93 + bob, cellX: cellX, cellY: rowY))
    context.addLine(to: point(97 + sway, 71 + bob, cellX: cellX, cellY: rowY))
    context.addLine(to: point(117 + sway, 93 + bob, cellX: cellX, cellY: rowY))
    context.strokePath()

    context.setFillColor(color(255, 246, 213, 0.9))
    context.fillEllipse(in: CGRect(x: cellX + 90 + sway, y: rowY + 65 + bob, width: 14, height: 8))

    context.restoreGState()
}

func drawBarWalkFrame(index: Int, row: Int, sourceRow: Int, direction: CGFloat) {
    let rowY = cellY(row: row)
    let phase = (CGFloat(index) / CGFloat(columns)) * CGFloat.pi * 2
    let bob = sin(phase) * 3
    let sway = sin(phase + CGFloat.pi / 2) * 4
    let cellX = CGFloat(index * cellWidth)

    guard let petFrame = sheet.cropping(to: CGRect(
        x: index * cellWidth,
        y: sourceRow * cellHeight,
        width: cellWidth,
        height: cellHeight
    )) else {
        return
    }

    context.saveGState()
    drawTopBar(cellX: cellX, cellY: rowY, phase: phase)

    context.setStrokeColor(color(128, 84, 69, 0.66))
    context.setLineWidth(1.8)
    context.setLineCap(.round)
    let handOffset = direction > 0 ? 12 + sway * 0.25 : -12 + sway * 0.25
    context.move(to: point(96 + handOffset, 190, cellX: cellX, cellY: rowY))
    context.addLine(to: point(96 + handOffset * 0.55, 159 + bob, cellX: cellX, cellY: rowY))
    context.strokePath()

    let scale: CGFloat = 0.72
    let petWidth = CGFloat(cellWidth) * scale
    let petHeight = CGFloat(cellHeight) * scale
    let petRect = CGRect(
        x: cellX + (CGFloat(cellWidth) - petWidth) / 2 + sway,
        y: rowY + 14 + bob,
        width: petWidth,
        height: petHeight
    )
    context.draw(petFrame, in: petRect)

    context.setFillColor(color(255, 239, 186, 0.88))
    context.fillEllipse(in: CGRect(x: cellX + 89 + handOffset * 0.45, y: rowY + 153 + bob, width: 12, height: 8))

    context.restoreGState()
}

for index in 0..<columns {
    drawParachuteFrame(index: index)
    drawBarWalkFrame(index: index, row: 14, sourceRow: 1, direction: 1)
    drawBarWalkFrame(index: index, row: 15, sourceRow: 2, direction: -1)
}

guard let outputImage = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, "public.png" as CFString, 1, nil) else {
    fputs("could not create output image\n", stderr)
    exit(1)
}

CGImageDestinationAddImage(destination, outputImage, nil)
guard CGImageDestinationFinalize(destination) else {
    fputs("could not write output image: \(outputURL.path)\n", stderr)
    exit(1)
}
