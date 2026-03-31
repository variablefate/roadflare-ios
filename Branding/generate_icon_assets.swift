import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct RGBA {
    var r: UInt8
    var g: UInt8
    var b: UInt8
    var a: UInt8
}

struct IntPoint: Hashable {
    let x: Int
    let y: Int
}

struct ColorAccumulator {
    var r: Double = 0
    var g: Double = 0
    var b: Double = 0
    var count: Double = 0

    mutating func add(r: UInt8, g: UInt8, b: UInt8, weight: Double = 1) {
        self.r += Double(r) * weight
        self.g += Double(g) * weight
        self.b += Double(b) * weight
        count += weight
    }

    func color(fallback: RGBA) -> RGBA {
        guard count > 0 else { return fallback }
        return RGBA(
            r: UInt8(max(0, min(255, Int(r / count)))),
            g: UInt8(max(0, min(255, Int(g / count)))),
            b: UInt8(max(0, min(255, Int(b / count)))),
            a: 255
        )
    }
}

enum AssetError: Error {
    case usage
    case imageLoadFailed(String)
    case imageWriteFailed(String)
    case contextCreationFailed
}

func clamp(_ value: Double, _ minValue: Double, _ maxValue: Double) -> Double {
    min(max(value, minValue), maxValue)
}

func writePNG(buffer: [UInt8], width: Int, height: Int, to path: String) throws {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let data = CFDataCreate(nil, buffer, buffer.count)!
    let provider = CGDataProvider(data: data)!
    guard let image = CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: true,
        intent: .defaultIntent
    ) else {
        throw AssetError.imageWriteFailed(path)
    }

    let url = URL(fileURLWithPath: path)
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw AssetError.imageWriteFailed(path)
    }

    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw AssetError.imageWriteFailed(path)
    }
}

func signedArea(of points: [IntPoint]) -> Double {
    guard points.count > 2 else { return 0 }
    var area = 0.0
    for index in points.indices {
        let next = points[(index + 1) % points.count]
        area += Double(points[index].x * next.y - next.x * points[index].y)
    }
    return area / 2
}

func simplifyCollinear(_ points: [IntPoint]) -> [IntPoint] {
    guard points.count > 2 else { return points }
    var simplified = points
    var changed = true

    while changed, simplified.count > 2 {
        changed = false
        var nextPass: [IntPoint] = []
        for index in simplified.indices {
            let previous = simplified[(index - 1 + simplified.count) % simplified.count]
            let current = simplified[index]
            let next = simplified[(index + 1) % simplified.count]
            let dx1 = current.x - previous.x
            let dy1 = current.y - previous.y
            let dx2 = next.x - current.x
            let dy2 = next.y - current.y
            if dx1 * dy2 == dy1 * dx2 {
                changed = true
                continue
            }
            nextPass.append(current)
        }
        simplified = nextPass
    }

    return simplified
}

func boundingBox(of points: [IntPoint]) -> (minX: Int, minY: Int, maxX: Int, maxY: Int) {
    var minX = Int.max
    var minY = Int.max
    var maxX = Int.min
    var maxY = Int.min

    for point in points {
        minX = min(minX, point.x)
        minY = min(minY, point.y)
        maxX = max(maxX, point.x)
        maxY = max(maxY, point.y)
    }

    return (minX, minY, maxX, maxY)
}

func pathData(from path: CGPath) -> String {
    var commands: [String] = []

    path.applyWithBlock { elementPointer in
        let element = elementPointer.pointee
        let points = element.points

        switch element.type {
        case .moveToPoint:
            commands.append(String(format: "M %.2f %.2f", points[0].x, points[0].y))
        case .addLineToPoint:
            commands.append(String(format: "L %.2f %.2f", points[0].x, points[0].y))
        case .addQuadCurveToPoint:
            commands.append(String(
                format: "Q %.2f %.2f %.2f %.2f",
                points[0].x,
                points[0].y,
                points[1].x,
                points[1].y
            ))
        case .addCurveToPoint:
            commands.append(String(
                format: "C %.2f %.2f %.2f %.2f %.2f %.2f",
                points[0].x,
                points[0].y,
                points[1].x,
                points[1].y,
                points[2].x,
                points[2].y
            ))
        case .closeSubpath:
            commands.append("Z")
        @unknown default:
            break
        }
    }

    return commands.joined(separator: " ")
}

func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
    CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
}

func perpendicularDistance(point: CGPoint, lineStart: CGPoint, lineEnd: CGPoint) -> Double {
    let dx = lineEnd.x - lineStart.x
    let dy = lineEnd.y - lineStart.y

    if abs(dx) < .ulpOfOne && abs(dy) < .ulpOfOne {
        return hypot(point.x - lineStart.x, point.y - lineStart.y)
    }

    let numerator = abs(dy * point.x - dx * point.y + lineEnd.x * lineStart.y - lineEnd.y * lineStart.x)
    let denominator = hypot(dx, dy)
    return Double(numerator / denominator)
}

func simplifyRDP(_ points: [CGPoint], epsilon: Double) -> [CGPoint] {
    guard points.count > 2 else { return points }

    var maxDistance = 0.0
    var splitIndex = 0

    for index in 1..<(points.count - 1) {
        let distance = perpendicularDistance(
            point: points[index],
            lineStart: points[0],
            lineEnd: points[points.count - 1]
        )
        if distance > maxDistance {
            maxDistance = distance
            splitIndex = index
        }
    }

    if maxDistance > epsilon {
        let firstHalf = simplifyRDP(Array(points[0...splitIndex]), epsilon: epsilon)
        let secondHalf = simplifyRDP(Array(points[splitIndex...]), epsilon: epsilon)
        return Array(firstHalf.dropLast()) + secondHalf
    }

    return [points[0], points[points.count - 1]]
}

func simplifyClosedLoop(_ points: [CGPoint], epsilon: Double) -> [CGPoint] {
    guard points.count > 3 else { return points }

    var openPoints = points
    openPoints.append(points[0])
    let simplified = simplifyRDP(openPoints, epsilon: epsilon)
    let closed = Array(simplified.dropLast())

    return closed.count >= 3 ? closed : points
}

func polygonArea(_ points: [CGPoint]) -> Double {
    guard points.count > 2 else { return 0 }
    var area = 0.0

    for index in points.indices {
        let next = points[(index + 1) % points.count]
        area += Double(points[index].x * next.y - next.x * points[index].y)
    }

    return area / 2
}

func linearClosedPath(from points: [CGPoint]) -> CGPath {
    let path = CGMutablePath()
    guard let first = points.first else { return path }

    path.move(to: first)
    for point in points.dropFirst() {
        path.addLine(to: point)
    }
    path.closeSubpath()
    return path
}

func smoothClosedPath(from points: [CGPoint]) -> CGPath {
    let path = CGMutablePath()
    guard points.count > 2 else { return linearClosedPath(from: points) }

    let firstMidpoint = midpoint(points[points.count - 1], points[0])
    path.move(to: firstMidpoint)

    for index in points.indices {
        let current = points[index]
        let next = points[(index + 1) % points.count]
        path.addQuadCurve(to: midpoint(current, next), control: current)
    }

    path.closeSubpath()
    return path
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    throw AssetError.usage
}

let sourcePath = arguments[1]
let outputDirectory = arguments[2]

try FileManager.default.createDirectory(
    at: URL(fileURLWithPath: outputDirectory),
    withIntermediateDirectories: true
)

guard let image = NSImage(contentsOfFile: sourcePath) else {
    throw AssetError.imageLoadFailed(sourcePath)
}

var proposedRect = NSRect(origin: .zero, size: image.size)
guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
    throw AssetError.imageLoadFailed(sourcePath)
}

let width = cgImage.width
let height = cgImage.height
let bytesPerPixel = 4
let bytesPerRow = bytesPerPixel * width
let colorSpace = CGColorSpaceCreateDeviceRGB()

var sourceBytes = [UInt8](repeating: 0, count: Int(bytesPerRow * height))
guard let sourceContext = CGContext(
    data: &sourceBytes,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: bytesPerRow,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    throw AssetError.contextCreationFailed
}

sourceContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

func pixelOffset(x: Int, y: Int) -> Int {
    y * bytesPerRow + x * bytesPerPixel
}

func rgbaAt(x: Int, y: Int) -> RGBA {
    let offset = pixelOffset(x: x, y: y)
    return RGBA(
        r: sourceBytes[offset],
        g: sourceBytes[offset + 1],
        b: sourceBytes[offset + 2],
        a: sourceBytes[offset + 3]
    )
}

func luma(_ pixel: RGBA) -> Double {
    0.2126 * Double(pixel.r) + 0.7152 * Double(pixel.g) + 0.0722 * Double(pixel.b)
}

let fullDarkThreshold = 62.0
let fullLightThreshold = 118.0
let darkFallback = RGBA(r: 29, g: 23, b: 20, a: 255)

var darkAccumulator = ColorAccumulator()
var topAccumulator = ColorAccumulator()
var bottomAccumulator = ColorAccumulator()
var glowAccumulator = ColorAccumulator()

for y in 0..<height {
    for x in 0..<width {
        let pixel = rgbaAt(x: x, y: y)
        guard pixel.a > 24 else { continue }

        let brightness = luma(pixel)
        let darkness = clamp(
            (fullLightThreshold - brightness) / (fullLightThreshold - fullDarkThreshold),
            0,
            1
        )

        if darkness > 0.82 {
            darkAccumulator.add(r: pixel.r, g: pixel.g, b: pixel.b, weight: darkness)
        } else {
            if y > Int(Double(height) * 0.72) {
                bottomAccumulator.add(r: pixel.r, g: pixel.g, b: pixel.b)
            }
            if y < Int(Double(height) * 0.18) {
                topAccumulator.add(r: pixel.r, g: pixel.g, b: pixel.b)
            }

            let dx = Double(x - width / 2)
            let dy = Double(y - Int(Double(height) * 0.34))
            if (dx * dx) + (dy * dy) < pow(Double(width) * 0.15, 2) {
                glowAccumulator.add(r: pixel.r, g: pixel.g, b: pixel.b)
            }
        }
    }
}

let darkColor = darkAccumulator.color(fallback: darkFallback)
let topColor = topAccumulator.color(fallback: RGBA(r: 255, g: 142, b: 12, a: 255))
let bottomColor = bottomAccumulator.color(fallback: RGBA(r: 242, g: 118, b: 6, a: 255))
let glowColor = glowAccumulator.color(fallback: RGBA(r: 255, g: 222, b: 103, a: 255))

var foregroundBytes = [UInt8](repeating: 0, count: sourceBytes.count)
var backgroundBytes = [UInt8](repeating: 0, count: sourceBytes.count)

for y in 0..<height {
    for x in 0..<width {
        let pixel = rgbaAt(x: x, y: y)
        let offset = pixelOffset(x: x, y: y)
        guard pixel.a > 0 else { continue }

        let brightness = luma(pixel)
        let darkness = clamp(
            (fullLightThreshold - brightness) / (fullLightThreshold - fullDarkThreshold),
            0,
            1
        )

        let foregroundAlpha = UInt8(clamp(Double(pixel.a) * darkness, 0, 255))
        foregroundBytes[offset] = darkColor.r
        foregroundBytes[offset + 1] = darkColor.g
        foregroundBytes[offset + 2] = darkColor.b
        foregroundBytes[offset + 3] = foregroundAlpha

        let backgroundAlpha = UInt8(clamp(Double(pixel.a) * (1 - darkness), 0, 255))
        backgroundBytes[offset] = pixel.r
        backgroundBytes[offset + 1] = pixel.g
        backgroundBytes[offset + 2] = pixel.b
        backgroundBytes[offset + 3] = backgroundAlpha
    }
}

let foregroundPath = "\(outputDirectory)/roadflare-foreground-layer.png"
let backgroundPath = "\(outputDirectory)/roadflare-background-layer.png"
try writePNG(buffer: foregroundBytes, width: width, height: height, to: foregroundPath)
try writePNG(buffer: backgroundBytes, width: width, height: height, to: backgroundPath)

let transparencyAlphaThreshold = UInt8(16)
let edgeSuppressionRadius = 10
var transparentIntegral = [Int](repeating: 0, count: (width + 1) * (height + 1))

func integralOffset(x: Int, y: Int) -> Int {
    y * (width + 1) + x
}

for y in 0..<height {
    var runningRowTotal = 0
    for x in 0..<width {
        let alpha = sourceBytes[pixelOffset(x: x, y: y) + 3]
        runningRowTotal += alpha <= transparencyAlphaThreshold ? 1 : 0
        transparentIntegral[integralOffset(x: x + 1, y: y + 1)] =
            transparentIntegral[integralOffset(x: x + 1, y: y)] + runningRowTotal
    }
}

func isNearTransparency(x: Int, y: Int, radius: Int) -> Bool {
    let minX = max(0, x - radius)
    let minY = max(0, y - radius)
    let maxX = min(width - 1, x + radius)
    let maxY = min(height - 1, y + radius)

    let transparentCount =
        transparentIntegral[integralOffset(x: maxX + 1, y: maxY + 1)] -
        transparentIntegral[integralOffset(x: minX, y: maxY + 1)] -
        transparentIntegral[integralOffset(x: maxX + 1, y: minY)] +
        transparentIntegral[integralOffset(x: minX, y: minY)]

    return transparentCount > 0
}

let vectorMaskThreshold = UInt8(96)
func foregroundFilled(x: Int, y: Int) -> Bool {
    guard (0..<width).contains(x), (0..<height).contains(y) else { return false }
    return foregroundBytes[pixelOffset(x: x, y: y) + 3] >= vectorMaskThreshold &&
        !isNearTransparency(x: x, y: y, radius: edgeSuppressionRadius)
}

var directedEdges: [(IntPoint, IntPoint)] = []

for y in 0..<height {
    for x in 0..<width where foregroundFilled(x: x, y: y) {
        if !foregroundFilled(x: x, y: y - 1) {
            directedEdges.append((IntPoint(x: x, y: y), IntPoint(x: x + 1, y: y)))
        }
        if !foregroundFilled(x: x + 1, y: y) {
            directedEdges.append((IntPoint(x: x + 1, y: y), IntPoint(x: x + 1, y: y + 1)))
        }
        if !foregroundFilled(x: x, y: y + 1) {
            directedEdges.append((IntPoint(x: x + 1, y: y + 1), IntPoint(x: x, y: y + 1)))
        }
        if !foregroundFilled(x: x - 1, y: y) {
            directedEdges.append((IntPoint(x: x, y: y + 1), IntPoint(x: x, y: y)))
        }
    }
}

var startToEdgeIndices: [IntPoint: [Int]] = [:]
for (index, edge) in directedEdges.enumerated() {
    startToEdgeIndices[edge.0, default: []].append(index)
}

var usedEdgeIndices = Set<Int>()
var loops: [[IntPoint]] = []

for edgeIndex in directedEdges.indices {
    guard !usedEdgeIndices.contains(edgeIndex) else { continue }

    let start = directedEdges[edgeIndex].0
    var current = edgeIndex
    var loop = [start]
    usedEdgeIndices.insert(edgeIndex)

    while true {
        let end = directedEdges[current].1
        if end == start {
            break
        }
        loop.append(end)
        guard let candidates = startToEdgeIndices[end] else { break }
        guard let nextEdge = candidates.first(where: { !usedEdgeIndices.contains($0) }) else { break }
        usedEdgeIndices.insert(nextEdge)
        current = nextEdge
    }

    let simplified = simplifyCollinear(loop)
    if simplified.count >= 3, abs(signedArea(of: simplified)) >= 18 {
        loops.append(simplified)
    }
}

let edgeArtifactThreshold = 4
let cleanedLoops = loops.filter { loop in
    let box = boundingBox(of: loop)
    let loopArea = abs(signedArea(of: loop))
    let boxWidth = box.maxX - box.minX
    let boxHeight = box.maxY - box.minY
    let edgeDistance = min(box.minX, box.minY, width - box.maxX, height - box.maxY)
    let isTopEdgeArc =
        box.minY < 28 &&
        boxWidth > Int(Double(width) * 0.6) &&
        boxHeight < 40
    let isBottomCenterArtifact =
        box.minY > Int(Double(height) * 0.88) &&
        boxWidth > 70 &&
        boxHeight > 35 &&
        box.minX > Int(Double(width) * 0.30) &&
        box.maxX < Int(Double(width) * 0.60)
    let isSmallEdgeFragment =
        edgeDistance < 36 &&
        loopArea < 120 &&
        (boxWidth < 28 || boxHeight < 110)

    return !isTopEdgeArc &&
        !isBottomCenterArtifact &&
        !isSmallEdgeFragment &&
        box.minX > edgeArtifactThreshold &&
        box.minY > edgeArtifactThreshold &&
        box.maxX < width - edgeArtifactThreshold &&
        box.maxY < height - edgeArtifactThreshold
}

var sourceContourPaths: [CGPath] = []

for loop in cleanedLoops {
    let sourcePoints = loop.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }
    let box = boundingBox(of: loop)
    let simplifiedPoints = simplifyClosedLoop(
        sourcePoints,
        epsilon: max(box.maxX - box.minX, box.maxY - box.minY) > 80 ? 1.8 : 1.2
    )

    sourceContourPaths.append(
        linearClosedPath(from: simplifiedPoints)
    )
}

let combinedSourcePath = CGMutablePath()
for contourPath in sourceContourPaths {
    combinedSourcePath.addPath(contourPath)
}

var svg = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(width) \(height)" role="img" aria-labelledby="title desc">
  <title id="title">RoadFlare dark foreground trace</title>
  <desc id="desc">Editable vector trace of the dark foreground artwork from the RoadFlare app icon.</desc>
  <path fill="#\(String(format: "%02X%02X%02X", darkColor.r, darkColor.g, darkColor.b))" fill-rule="evenodd" d="
\(pathData(from: combinedSourcePath))
"/>
</svg>
"""

let svgPath = "\(outputDirectory)/roadflare-foreground.svg"
try svg.write(toFile: svgPath, atomically: true, encoding: .utf8)

let cropAlphaThreshold = 240
let cropInsetX = 8
let cropInsetTop = 0
let cropInsetBottom = 8
var cropMinX = width
var cropMinY = height
var cropMaxX = -1
var cropMaxY = -1

for y in 0..<height {
    for x in 0..<width {
        let alpha = Int(sourceBytes[pixelOffset(x: x, y: y) + 3])
        if alpha >= cropAlphaThreshold {
            if x < cropMinX { cropMinX = x }
            if x > cropMaxX { cropMaxX = x }
            if y < cropMinY { cropMinY = y }
            if y > cropMaxY { cropMaxY = y }
        }
    }
}

cropMinX += cropInsetX
cropMinY += cropInsetTop
cropMaxX -= cropInsetX
cropMaxY -= cropInsetBottom

let cropWidth = cropMaxX - cropMinX + 1
let cropHeight = cropMaxY - cropMinY + 1
let cropRect = CGRect(x: cropMinX, y: cropMinY, width: cropWidth, height: cropHeight)

let targetSize = 1024
let targetRect = CGRect(x: 0, y: 0, width: targetSize, height: targetSize)
guard
    let foregroundData = CGDataProvider(data: CFDataCreate(nil, foregroundBytes, foregroundBytes.count)!),
    let backgroundData = CGDataProvider(data: CFDataCreate(nil, backgroundBytes, backgroundBytes.count)!),
    let foregroundCG = CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: foregroundData,
        decode: nil,
        shouldInterpolate: true,
        intent: .defaultIntent
    ),
    let backgroundCG = CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: backgroundData,
        decode: nil,
        shouldInterpolate: true,
        intent: .defaultIntent
    ),
    let foregroundCrop = foregroundCG.cropping(to: cropRect),
    let backgroundCrop = backgroundCG.cropping(to: cropRect)
else {
    throw AssetError.contextCreationFailed
}

var iconBytes = [UInt8](repeating: 0, count: targetSize * targetSize * 4)
guard let iconContext = CGContext(
    data: &iconBytes,
    width: targetSize,
    height: targetSize,
    bitsPerComponent: 8,
    bytesPerRow: targetSize * 4,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    throw AssetError.contextCreationFailed
}

let topCG = CGColor(red: CGFloat(topColor.r) / 255, green: CGFloat(topColor.g) / 255, blue: CGFloat(topColor.b) / 255, alpha: 1)
let bottomCG = CGColor(red: CGFloat(bottomColor.r) / 255, green: CGFloat(bottomColor.g) / 255, blue: CGFloat(bottomColor.b) / 255, alpha: 1)
let glowCG = CGColor(red: CGFloat(glowColor.r) / 255, green: CGFloat(glowColor.g) / 255, blue: CGFloat(glowColor.b) / 255, alpha: 1)
let clearGlowCG = CGColor(
    colorSpace: colorSpace,
    components: [CGFloat(glowColor.r) / 255, CGFloat(glowColor.g) / 255, CGFloat(glowColor.b) / 255, 0]
) ?? glowCG

let linearGradient = CGGradient(colorsSpace: colorSpace, colors: [topCG, bottomCG] as CFArray, locations: [0, 1])!
iconContext.drawLinearGradient(
    linearGradient,
    start: CGPoint(x: targetSize / 2, y: targetSize),
    end: CGPoint(x: targetSize / 2, y: 0),
    options: []
)

let radialGradient = CGGradient(colorsSpace: colorSpace, colors: [glowCG, clearGlowCG] as CFArray, locations: [0, 1])!
iconContext.drawRadialGradient(
    radialGradient,
    startCenter: CGPoint(x: CGFloat(targetSize) * 0.5, y: CGFloat(targetSize) * 0.68),
    startRadius: 0,
    endCenter: CGPoint(x: CGFloat(targetSize) * 0.5, y: CGFloat(targetSize) * 0.68),
    endRadius: CGFloat(targetSize) * 0.46,
    options: []
)

iconContext.interpolationQuality = .high
iconContext.draw(backgroundCrop, in: targetRect)
iconContext.draw(foregroundCrop, in: targetRect)

let homeIconPath = "\(outputDirectory)/roadflare-app-icon-homescreen.png"
try writePNG(buffer: iconBytes, width: targetSize, height: targetSize, to: homeIconPath)

let themeTopColor = RGBA(r: 0xFF, g: 0x90, b: 0x6C, a: 255)
let themeBottomColor = RGBA(r: 0xFF, g: 0x73, b: 0x46, a: 255)
let themeGlowColor = RGBA(r: 0xFF, g: 0xC5, b: 0x63, a: 255)
let themeFlareCoreColor = RGBA(r: 0xFF, g: 0xDB, b: 0x8A, a: 255)
let flareCoreRadius = CGFloat(targetSize) * 0.010

func cgColor(_ color: RGBA, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat(color.r) / 255,
        green: CGFloat(color.g) / 255,
        blue: CGFloat(color.b) / 255,
        alpha: alpha
    )
}

var themePreviewBytes = [UInt8](repeating: 0, count: targetSize * targetSize * 4)
guard let themeContext = CGContext(
    data: &themePreviewBytes,
    width: targetSize,
    height: targetSize,
    bitsPerComponent: 8,
    bytesPerRow: targetSize * 4,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    throw AssetError.contextCreationFailed
}

let themeLinearGradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [cgColor(themeTopColor), cgColor(themeBottomColor)] as CFArray,
    locations: [0, 1]
)!
themeContext.drawLinearGradient(
    themeLinearGradient,
    start: CGPoint(x: targetSize / 2, y: targetSize),
    end: CGPoint(x: targetSize / 2, y: 0),
    options: []
)

let themeRadialGradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [cgColor(themeGlowColor), cgColor(themeGlowColor, alpha: 0)] as CFArray,
    locations: [0, 1]
)!
themeContext.drawRadialGradient(
    themeRadialGradient,
    startCenter: CGPoint(x: CGFloat(targetSize) * 0.5, y: CGFloat(targetSize) * 0.66),
    startRadius: 0,
    endCenter: CGPoint(x: CGFloat(targetSize) * 0.5, y: CGFloat(targetSize) * 0.66),
    endRadius: CGFloat(targetSize) * 0.44,
    options: []
)

let scaleX = CGFloat(targetSize) / CGFloat(cropWidth)
let scaleY = CGFloat(targetSize) / CGFloat(cropHeight)
let flareCoreSourceCenter = CGPoint(x: 362.1, y: 114.6)
let flareCorePreviewCenter = CGPoint(
    x: (flareCoreSourceCenter.x - CGFloat(cropMinX)) * scaleX,
    y: (flareCoreSourceCenter.y - CGFloat(cropMinY)) * scaleY
)
let bottomEdgeExtensionTopPath = CGMutablePath()
bottomEdgeExtensionTopPath.addPath(linearClosedPath(from: [
    CGPoint(x: 66, y: 940),
    CGPoint(x: 62, y: 980),
    CGPoint(x: 89, y: 1000),
    CGPoint(x: 118, y: 1024),
    CGPoint(x: 0, y: 1024)
]))
bottomEdgeExtensionTopPath.addPath(linearClosedPath(from: [
    CGPoint(x: 994, y: 940),
    CGPoint(x: 959, y: 980),
    CGPoint(x: 938, y: 1000),
    CGPoint(x: 906, y: 1024),
    CGPoint(x: 1024, y: 1024)
]))
var bottomEdgeExtensionRasterTransform = CGAffineTransform(
    a: 1,
    b: 0,
    c: 0,
    d: -1,
    tx: 0,
    ty: CGFloat(targetSize)
)
let bottomEdgeExtensionRasterPath = bottomEdgeExtensionTopPath.copy(using: &bottomEdgeExtensionRasterTransform) ?? CGMutablePath()

themeContext.setFillColor(cgColor(themeFlareCoreColor))
themeContext.fillEllipse(
    in: CGRect(
        x: flareCorePreviewCenter.x - flareCoreRadius,
        y: CGFloat(targetSize) - flareCorePreviewCenter.y - flareCoreRadius,
        width: flareCoreRadius * 2,
        height: flareCoreRadius * 2
    )
)

let foregroundRasterPath = CGMutablePath()

for sourceContourPath in sourceContourPaths {
    var targetTransform = CGAffineTransform(
        a: scaleX,
        b: 0,
        c: 0,
        d: -scaleY,
        tx: -CGFloat(cropMinX) * scaleX,
        ty: CGFloat(targetSize) + CGFloat(cropMinY) * scaleY
    )
    guard let transformedPath = sourceContourPath.copy(using: &targetTransform) else {
        continue
    }
    foregroundRasterPath.addPath(transformedPath)
}

themeContext.addPath(foregroundRasterPath)
themeContext.setFillColor(cgColor(darkColor))
themeContext.fillPath(using: .evenOdd)
themeContext.addPath(bottomEdgeExtensionRasterPath)
themeContext.setFillColor(cgColor(darkColor))
themeContext.fillPath()

let themePreviewPath = "\(outputDirectory)/roadflare-app-icon-theme-preview.png"
try writePNG(buffer: themePreviewBytes, width: targetSize, height: targetSize, to: themePreviewPath)

let foregroundVectorSVGPath = CGMutablePath()
for sourceContourPath in sourceContourPaths {
    var targetTransform = CGAffineTransform(
        a: scaleX,
        b: 0,
        c: 0,
        d: scaleY,
        tx: -CGFloat(cropMinX) * scaleX,
        ty: -CGFloat(cropMinY) * scaleY
    )
    guard let transformedPath = sourceContourPath.copy(using: &targetTransform) else {
        continue
    }
    foregroundVectorSVGPath.addPath(transformedPath)
}

let combinedThemeVectorSVGPath = CGMutablePath()
combinedThemeVectorSVGPath.addPath(foregroundVectorSVGPath)
combinedThemeVectorSVGPath.addPath(bottomEdgeExtensionTopPath)

var themeSVG = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" role="img" aria-labelledby="title desc">
  <title id="title">RoadFlare app icon preview using theme background</title>
  <desc id="desc">The original dark foreground artwork traced into vector form over a background using RoadFlare theme oranges.</desc>
  <defs>
    <linearGradient id="bg" x1="50%" y1="0%" x2="50%" y2="100%">
      <stop offset="0%" stop-color="#FF906C"/>
      <stop offset="100%" stop-color="#FF7346"/>
    </linearGradient>
    <radialGradient id="glow" cx="50%" cy="34%" r="44%">
      <stop offset="0%" stop-color="#FFC563"/>
      <stop offset="100%" stop-color="#FFC563" stop-opacity="0"/>
    </radialGradient>
  </defs>
  <rect width="1024" height="1024" fill="url(#bg)"/>
  <rect width="1024" height="1024" fill="url(#glow)"/>
  <circle cx="\(String(format: "%.2f", flareCorePreviewCenter.x))" cy="\(String(format: "%.2f", flareCorePreviewCenter.y))" r="\(String(format: "%.2f", flareCoreRadius))" fill="#\(String(format: "%02X%02X%02X", themeFlareCoreColor.r, themeFlareCoreColor.g, themeFlareCoreColor.b))"/>
  <path fill="#\(String(format: "%02X%02X%02X", darkColor.r, darkColor.g, darkColor.b))" fill-rule="evenodd" d="
\(pathData(from: combinedThemeVectorSVGPath))
"""

themeSVG += """
"/>
</svg>
"""

let themeSVGPath = "\(outputDirectory)/roadflare-app-icon-theme-preview.svg"
try themeSVG.write(toFile: themeSVGPath, atomically: true, encoding: .utf8)

print("Generated:")
print(foregroundPath)
print(backgroundPath)
print(svgPath)
print(homeIconPath)
print(themePreviewPath)
print(themeSVGPath)
