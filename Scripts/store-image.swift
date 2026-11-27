// Puts one screenshot and one headline into a render: the picture of a device, exported from
// Spline, whose screen is filled with one flat key color. Compiled once per run by screenshots.sh.
// See "Store images" in Documentation/ScriperKit.md.
//
// The key marks where the screenshot goes. Whatever the render shows in front of the screen, the
// Dynamic Island or an object floating before the device, already covers the key, so the
// screenshot lands behind it without any layering, and no app has to list coordinates.
//
// Usage:
//   store-image <render.png> <screenshot.png> <output.jpg | output.png>
//     [--headline <text>] [--font <file>] [--weight <100…900>] [--color <rrggbb>]
//   The output is a JPEG or a PNG by its file name, never with an alpha channel.
//   Exits 1 when the render holds no key-colored screen.

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Tuning

/// The key color of a screen: pure magenta, which no interface and no stage uses by accident.
let keyColor: (r: Double, g: Double, b: Double) = (255, 0, 255)
/// How far red and blue must stand above green for a pixel to count as fully key. Lower values
/// keep more of the soft edge around the screen.
let keyRange = 200.0
/// From this share of key on, a pixel belongs to the screen when its edges are measured.
let solidKey = 0.6
/// The part of each screen edge its line is measured on, as a share of the edge trimmed at both
/// ends: the rounded corners lie outside it.
let edgeTrim = 0.22
/// Edge points kept per round when a line is fitted. The rest are the ones an object in front of
/// the screen pushed out of place.
let fitKeepShare = 0.67
let fitRounds = 4
/// The headline's box, as shares of the image: left edge, top edge, width, and largest height.
let headlineBox = (x: 0.085, y: 0.055, width: 0.83, maxHeight: 0.125)
/// The headline's size as a share of the image width, and how far it may shrink to fit its box
/// in a language with longer words.
let headlineSize = 0.074
let headlineMinimumScale = 0.5
let headlineShrinkStep = 0.96
let headlineLineHeight = 1.08
/// Quality of a store image written as JPEG, 0 to 1. High enough that small interface text
/// shows no artifacts, at about a fifth of the size of the same image as PNG.
let jpegQuality = 0.92

// MARK: - Pixels

/// An image as RGBA bytes, top row first.
struct Bitmap {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
    }

    init(image: CGImage, width: Int? = nil, height: Int? = nil) {
        self.init(width: width ?? image.width, height: height ?? image.height)
        let frame = CGRect(x: 0, y: 0, width: self.width, height: self.height)
        withContext { context in
            context.interpolationQuality = .high
            context.draw(image, in: frame)
        }
    }

    /// Draws into the pixels with Core Graphics, origin at the bottom left.
    mutating func withContext(_ draw: (CGContext) -> Void) {
        let width = width, height = height
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            draw(context)
        }
    }

    /// The pixels as an image without an alpha channel. App Store Connect rejects a screenshot
    /// that has one, even when every pixel is opaque.
    var opaqueImage: CGImage? {
        var copy = pixels
        let width = width, height = height
        return copy.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )?.makeImage()
        }
    }
}

func loadImage(_ path: String) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

/// Writes the image in the format its file name asks for: JPEG for `.jpg` and `.jpeg`, PNG for
/// anything else.
func save(_ image: CGImage, to path: String) -> Bool {
    let url = URL(fileURLWithPath: path)
    let isJPEG = ["jpg", "jpeg"].contains(url.pathExtension.lowercased())
    let type = isJPEG ? UTType.jpeg : UTType.png
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
        return false
    }
    let properties = isJPEG ? [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary : nil
    CGImageDestinationAddImage(destination, image, properties)
    return CGImageDestinationFinalize(destination)
}

// MARK: - Finding the screen

/// How much of each pixel is key, 0 to 1.
func keyShare(of render: Bitmap) -> [Double] {
    var share = [Double](repeating: 0, count: render.width * render.height)
    for index in 0..<share.count {
        let red = Double(render.pixels[index * 4])
        let green = Double(render.pixels[index * 4 + 1])
        let blue = Double(render.pixels[index * 4 + 2])
        share[index] = min(max((min(red, blue) - green) / keyRange, 0), 1)
    }
    return share
}

/// The columns of the screen nearest the middle. A neighboring device can reach into the frame
/// with a strip of its own screen, which must not count.
func middleScreenColumns(share: [Double], width: Int, height: Int) -> ClosedRange<Int>? {
    var runs: [ClosedRange<Int>] = []
    var start: Int?
    for x in 0..<width {
        var holdsKey = false
        for y in 0..<height where share[y * width + x] > solidKey {
            holdsKey = true
            break
        }
        if holdsKey, start == nil { start = x }
        if !holdsKey, let from = start {
            runs.append(from...(x - 1))
            start = nil
        }
    }
    if let from = start { runs.append(from...(width - 1)) }
    let middle = Double(width) / 2
    return runs.min { abs(Double($0.lowerBound + $0.upperBound) / 2 - middle) < abs(Double($1.lowerBound + $1.upperBound) / 2 - middle) }
}

/// A line `value = slope * along + offset` through points, fitted again and again without the
/// points furthest from it.
func fitLine(_ points: [(along: Double, value: Double)]) -> (slope: Double, offset: Double)? {
    var kept = points
    var line: (slope: Double, offset: Double)?
    for _ in 0..<fitRounds {
        guard kept.count >= 8 else { break }
        let count = Double(kept.count)
        let meanAlong = kept.reduce(0) { $0 + $1.along } / count
        let meanValue = kept.reduce(0) { $0 + $1.value } / count
        let spread = kept.reduce(0) { $0 + ($1.along - meanAlong) * ($1.along - meanAlong) }
        guard spread > 0 else { break }
        let slope = kept.reduce(0) { $0 + ($1.along - meanAlong) * ($1.value - meanValue) } / spread
        let offset = meanValue - slope * meanAlong
        line = (slope, offset)
        kept.sort { abs($0.value - slope * $0.along - offset) < abs($1.value - slope * $1.along - offset) }
        kept = Array(kept.prefix(Int(Double(kept.count) * fitKeepShare)))
    }
    return line
}

/// The corners of the screen: top left, top right, bottom right, bottom left.
func screenCorners(share: [Double], columns: ClosedRange<Int>, width: Int, height: Int) -> [CGPoint]? {
    var top = height, bottom = -1
    for y in 0..<height {
        for x in columns where share[y * width + x] > solidKey {
            top = min(top, y)
            bottom = max(bottom, y)
            break
        }
    }
    guard bottom > top else { return nil }

    var left: [(Double, Double)] = [], right: [(Double, Double)] = []
    let rowInset = Int(Double(bottom - top) * edgeTrim)
    for y in (top + rowInset)...(bottom - rowInset) {
        let row = columns.filter { share[y * width + $0] > solidKey }
        guard let first = row.first, let last = row.last else { continue }
        left.append((Double(y), Double(first)))
        right.append((Double(y), Double(last) + 1))
    }
    var upper: [(Double, Double)] = [], lower: [(Double, Double)] = []
    let columnInset = Int(Double(columns.count) * edgeTrim)
    for x in (columns.lowerBound + columnInset)...(columns.upperBound - columnInset) {
        let column = (top...bottom).filter { share[$0 * width + x] > solidKey }
        guard let first = column.first, let last = column.last else { continue }
        upper.append((Double(x), Double(first)))
        lower.append((Double(x), Double(last) + 1))
    }
    guard let leftLine = fitLine(left), let rightLine = fitLine(right),
          let topLine = fitLine(upper), let bottomLine = fitLine(lower) else { return nil }

    // A side runs x = slope * y + offset, the top and bottom y = slope * x + offset.
    func corner(_ side: (slope: Double, offset: Double), _ cap: (slope: Double, offset: Double)) -> CGPoint {
        let x = (side.slope * cap.offset + side.offset) / (1 - side.slope * cap.slope)
        return CGPoint(x: x, y: cap.slope * x + cap.offset)
    }
    return [corner(leftLine, topLine), corner(rightLine, topLine), corner(rightLine, bottomLine), corner(leftLine, bottomLine)]
}

// MARK: - Fitting the screenshot

/// The eight numbers that carry a point of the render to its place in the screenshot.
func projection(from corners: [CGPoint], to size: CGSize) -> [Double]? {
    let targets = [CGPoint.zero, CGPoint(x: size.width, y: 0), CGPoint(x: size.width, y: size.height), CGPoint(x: 0, y: size.height)]
    var rows: [[Double]] = []
    for (corner, target) in zip(corners, targets) {
        let x = Double(corner.x), y = Double(corner.y), u = Double(target.x), v = Double(target.y)
        rows.append([x, y, 1, 0, 0, 0, -u * x, -u * y, u])
        rows.append([0, 0, 0, x, y, 1, -v * x, -v * y, v])
    }
    for pivot in 0..<8 {
        guard let best = (pivot..<8).max(by: { abs(rows[$0][pivot]) < abs(rows[$1][pivot]) }), abs(rows[best][pivot]) > 1e-12 else {
            return nil
        }
        rows.swapAt(pivot, best)
        for row in 0..<8 where row != pivot {
            let factor = rows[row][pivot] / rows[pivot][pivot]
            for column in pivot..<9 { rows[row][column] -= factor * rows[pivot][column] }
        }
    }
    return (0..<8).map { rows[$0][8] / rows[$0][$0] }
}

func compose(render: Bitmap, screenshot: CGImage) -> Bitmap? {
    let width = render.width, height = render.height
    var share = keyShare(of: render)
    guard let columns = middleScreenColumns(share: share, width: width, height: height),
          let corners = screenCorners(share: share, columns: columns, width: width, height: height) else { return nil }
    // Key outside the middle screen stays as it is: it belongs to a neighboring device.
    for y in 0..<height {
        for x in 0..<width where !columns.contains(x) { share[y * width + x] = 0 }
    }

    // Scaled to about the size it takes on the device first, so fitting it only bends it and
    // small text keeps its edges.
    let screenWidth = Int(max(hypot(corners[1].x - corners[0].x, corners[1].y - corners[0].y), 1).rounded())
    let screenHeight = Int(max(hypot(corners[3].x - corners[0].x, corners[3].y - corners[0].y), 1).rounded())
    let shot = Bitmap(image: screenshot, width: screenWidth, height: screenHeight)
    guard let map = projection(from: corners, to: CGSize(width: screenWidth, height: screenHeight)) else { return nil }

    var output = render
    for y in 0..<height {
        for x in 0..<width {
            let key = share[y * width + x]
            guard key > 0 else { continue }
            let px = Double(x) + 0.5, py = Double(y) + 0.5
            let scale = map[6] * px + map[7] * py + 1
            let u = min(max((map[0] * px + map[1] * py + map[2]) / scale - 0.5, 0), Double(screenWidth - 1))
            let v = min(max((map[3] * px + map[4] * py + map[5]) / scale - 0.5, 0), Double(screenHeight - 1))
            let x0 = Int(u), y0 = Int(v), x1 = min(x0 + 1, screenWidth - 1), y1 = min(y0 + 1, screenHeight - 1)
            let fx = u - Double(x0), fy = v - Double(y0)
            let keyParts = [keyColor.r, keyColor.g, keyColor.b]
            for channel in 0..<3 {
                func sample(_ sx: Int, _ sy: Int) -> Double { Double(shot.pixels[(sy * screenWidth + sx) * 4 + channel]) }
                let color = (sample(x0, y0) * (1 - fx) + sample(x1, y0) * fx) * (1 - fy)
                    + (sample(x0, y1) * (1 - fx) + sample(x1, y1) * fx) * fy
                // Along the edge a pixel is part key, part device. The key is taken back out
                // of it, or a magenta fringe stays around the screen.
                let mixed = Double(render.pixels[(y * width + x) * 4 + channel])
                let device = min(max((mixed - key * keyParts[channel]) / max(1 - key, 0.05), 0), 255)
                output.pixels[(y * width + x) * 4 + channel] = UInt8((device * (1 - key) + color * key).rounded())
            }
        }
    }
    return output
}

// MARK: - Headline

/// The headline's font at a size: the given file at the given weight, or the system's bold face.
/// Core Text fills in other fonts for scripts the face does not cover.
func headlineFont(file: String?, weight: Double, size: CGFloat) -> CTFont {
    if let file,
       let descriptors = CTFontManagerCreateFontDescriptorsFromURL(URL(fileURLWithPath: file) as CFURL) as? [CTFontDescriptor],
       let descriptor = descriptors.first {
        // 'wght', the weight axis of a variable font. A font without the axis ignores it.
        let weightAxis = 0x7767_6874
        let weighted = CTFontDescriptorCreateCopyWithAttributes(
            descriptor, [kCTFontVariationAttribute: [weightAxis: weight]] as CFDictionary
        )
        return CTFontCreateWithFontDescriptor(weighted, size, nil)
    }
    return CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil) ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
}

func drawHeadline(_ text: String, into bitmap: inout Bitmap, fontFile: String?, weight: Double, color: CGColor) {
    let width = CGFloat(bitmap.width), height = CGFloat(bitmap.height)
    let boxWidth = width * headlineBox.width, maxHeight = height * headlineBox.maxHeight
    var size = width * headlineSize
    let smallest = size * headlineMinimumScale

    func frame(at size: CGFloat) -> (setter: CTFramesetter, fit: CGSize) {
        var lineHeight = CGFloat(headlineLineHeight)
        var alignment = CTTextAlignment.natural
        let style = withUnsafeBytes(of: &lineHeight) { lineHeightBytes in
            withUnsafeBytes(of: &alignment) { alignmentBytes in
                CTParagraphStyleCreate([
                    CTParagraphStyleSetting(spec: .lineHeightMultiple, valueSize: MemoryLayout<CGFloat>.size, value: lineHeightBytes.baseAddress!),
                    CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: alignmentBytes.baseAddress!)
                ], 2)
            }
        }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): headlineFont(file: fontFile, weight: weight, size: size),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style
        ]
        let setter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(
            setter, CFRange(), nil, CGSize(width: boxWidth, height: .greatestFiniteMagnitude), nil
        )
        return (setter, fit)
    }

    // A language with longer words gets a smaller headline rather than one that runs into the
    // device below it.
    var fitted = frame(at: size)
    while fitted.fit.height > maxHeight, size > smallest {
        size *= headlineShrinkStep
        fitted = frame(at: size)
    }
    let box = CGRect(
        x: width * headlineBox.x, y: height - height * headlineBox.y - fitted.fit.height,
        width: boxWidth, height: fitted.fit.height
    )
    bitmap.withContext { context in
        CTFrameDraw(CTFramesetterCreateFrame(fitted.setter, CFRange(), CGPath(rect: box, transform: nil), nil), context)
    }
}

// MARK: - Run

func color(fromHex hex: String) -> CGColor? {
    guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
    return CGColor(
        srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
        blue: CGFloat(value & 0xFF) / 255, alpha: 1
    )
}

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

var arguments = Array(CommandLine.arguments.dropFirst())
var options: [String: String] = [:]
while let index = arguments.firstIndex(where: { $0.hasPrefix("--") }) {
    guard index + 1 < arguments.count else { fail("Missing value for \(arguments[index])", code: 64) }
    options[String(arguments[index].dropFirst(2))] = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
}
guard arguments.count == 3 else {
    fail("Usage: store-image <render.png> <screenshot.png> <output.jpg | output.png> [--headline <text>] [--font <file>] [--weight <100…900>] [--color <rrggbb>]", code: 64)
}
guard let renderImage = loadImage(arguments[0]) else { fail("Cannot read \(arguments[0])", code: 66) }
guard let screenshot = loadImage(arguments[1]) else { fail("Cannot read \(arguments[1])", code: 66) }
guard var output = compose(render: Bitmap(image: renderImage), screenshot: screenshot) else {
    fail("No key-colored screen in \(arguments[0])", code: 1)
}
if let headline = options["headline"], !headline.isEmpty {
    let ink = options["color"].flatMap(color(fromHex:)) ?? CGColor(srgbRed: 0.07, green: 0.07, blue: 0.09, alpha: 1)
    drawHeadline(headline, into: &output, fontFile: options["font"], weight: Double(options["weight"] ?? "") ?? 700, color: ink)
}
guard let result = output.opaqueImage, save(result, to: arguments[2]) else { fail("Cannot write \(arguments[2])", code: 73) }
