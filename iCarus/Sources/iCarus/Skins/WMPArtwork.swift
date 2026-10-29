import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Piece 2 of the WMP importer: turn a skin's bitmaps into PNGs with real transparency,
// and work out where each button is from the colour-coded "mapping" images.
//
// How WMP skins mark transparency: a colour (usually magenta #FF00FF) is declared in the
// layout as `transparencyColor` ("see-through") and another (usually red #FF0000) as
// `clippingColor` ("outside the window's shape"). Both become fully transparent here.
//
// How WMP skins mark buttons: several buttons share one picture strip, and a second
// "mapping" picture paints each button's area in its own flat colour. Each button element
// in the layout names its `mappingColor`; the bounding box of that colour in the mapping
// image is where the button is within the strip.

struct RGB: Equatable {
    var r: UInt8
    var g: UInt8
    var b: UInt8

    /// "#FF00FF" or "FF00FF" -> colour. "none" and anything else -> nil.
    static func parse(_ text: String?) -> RGB? {
        guard var hex = text?.trimmingCharacters(in: .whitespaces), !hex.isEmpty else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return RGB(r: UInt8((value >> 16) & 0xFF), g: UInt8((value >> 8) & 0xFF), b: UInt8(value & 0xFF))
    }
}

struct PixelRect: Equatable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
}

struct WMPButtonRegion: Identifiable {
    let id = UUID()
    /// The layout element, e.g. "playelement" or "buttonelement".
    var element: String
    /// Human label: "play", "previous", "Minimize", ...
    var label: String
    var mappingColor: String
    /// Where the button is inside the picture strip, in pixels. nil if its colour wasn't found.
    var rect: PixelRect?
    var onClick: String?
}

struct WMPButtonGroup: Identifiable {
    let id = UUID()
    var mappingImage: String
    var stripSize: (width: Int, height: Int)?
    var left: Int?
    var top: Int?
    var image: String?
    var hoverImage: String?
    var downImage: String?
    var disabledImage: String?
    var regions: [WMPButtonRegion]
}

struct WMPConvertedImage: Identifiable {
    var id: String { source }
    /// File name as the layout wrote it.
    var source: String
    /// Name of the PNG that was written.
    var output: String
    var width: Int
    var height: Int
    /// How many pixels were made transparent.
    var keyedPixels: Int
}

struct WMPArtworkResult {
    var images: [WMPConvertedImage] = []
    var buttonGroups: [WMPButtonGroup] = []
    var problems: [String] = []
}

enum WMPArtwork {
    static let pictureExtensions: Set<String> = ["bmp", "gif", "jpg", "jpeg", "png"]

    /// Converts every picture the layout uses (into `outputFolder`) and locates the buttons.
    static func convert(layout root: WMSNode,
                        sourceFolder: URL,
                        files: [String],
                        outputFolder: URL) -> WMPArtworkResult {
        var result = WMPArtworkResult()

        // Archive files by lower-cased name (WMP skins are case-insensitive).
        var lookup: [String: String] = [:]
        for path in files {
            let key = (path as NSString).lastPathComponent.lowercased()
            if lookup[key] == nil { lookup[key] = path }
        }

        // 1. Which pictures are used, and which colours each one should make transparent.
        var keysByImage: [String: [RGB]] = [:]
        var shownName: [String: String] = [:]
        var mappingNodes: [WMSNode] = []
        // Many skins declare their transparent / outside colour once, on the <view>, and expect it
        // to apply to the other pictures too (e.g. hover and disabled strips).
        func colourKeys(_ node: WMSNode) -> [RGB] {
            [node.attr("transparencycolor"), node.attr("clippingcolor")].compactMap { RGB.parse($0) }
        }
        let viewKeys = root.allNodes.first(where: { $0.tag == "view" }).map(colourKeys) ?? []
        for node in root.allNodes {
            let own = colourKeys(node)
            let keys = own.isEmpty ? viewKeys : own
            for (attribute, raw) in node.attributes where attribute.hasSuffix("image") {
                guard let name = pictureName(raw) else { continue }
                if attribute == "mappingimage" {
                    if !mappingNodes.contains(where: { $0 === node }) { mappingNodes.append(node) }
                    continue
                }
                let lower = (name as NSString).lastPathComponent.lowercased()
                if shownName[lower] == nil { shownName[lower] = name }
                var list = keysByImage[lower] ?? []
                for key in keys where !list.contains(key) { list.append(key) }
                keysByImage[lower] = list
            }
        }

        // 2. Convert them.
        var usedOutputs = Set<String>()
        for (lower, keys) in keysByImage.sorted(by: { $0.key < $1.key }) {
            let shown = shownName[lower] ?? lower
            guard let relative = lookup[lower] else {
                result.problems.append("Missing image: \(shown)")
                continue
            }
            guard var image = RGBAImage.load(sourceFolder.appendingPathComponent(relative)) else {
                result.problems.append("Couldn't read image: \(shown)")
                continue
            }
            let keyed = image.makeTransparent(matching: keys, tolerance: 10)

            let base = (lower as NSString).deletingPathExtension
            var output = base + ".png"
            if usedOutputs.contains(output) { output = base + "_" + (lower as NSString).pathExtension + ".png" }
            usedOutputs.insert(output)

            guard image.writePNG(to: outputFolder.appendingPathComponent(output)) else {
                result.problems.append("Couldn't write PNG for: \(shown)")
                continue
            }
            result.images.append(WMPConvertedImage(source: shown, output: output,
                                                   width: image.width, height: image.height,
                                                   keyedPixels: keyed))
        }

        // 3. Locate buttons from the mapping images.
        for node in mappingNodes {
            guard let name = pictureName(node.attr("mappingimage")) else { continue }
            guard let relative = lookup[(name as NSString).lastPathComponent.lowercased()],
                  let map = RGBAImage.load(sourceFolder.appendingPathComponent(relative)) else {
                result.problems.append("Couldn't read mapping image: \(name)")
                continue
            }
            var regions: [WMPButtonRegion] = []
            for child in node.children {
                guard let hex = child.attr("mappingcolor"), let color = RGB.parse(hex) else { continue }
                regions.append(WMPButtonRegion(element: child.tag,
                                               label: label(for: child),
                                               mappingColor: hex.uppercased(),
                                               // Exact match first (some skins use near-identical colours).
                                               rect: map.boundingBox(of: color, tolerance: 0)
                                                   ?? map.boundingBox(of: color, tolerance: 24),
                                               onClick: child.attr("onclick")))
            }
            result.buttonGroups.append(WMPButtonGroup(
                mappingImage: name,
                stripSize: (map.width, map.height),
                left: Int(node.attr("left") ?? ""),
                top: Int(node.attr("top") ?? ""),
                image: node.attr("image"),
                hoverImage: node.attr("hoverimage"),
                downImage: node.attr("downimage"),
                disabledImage: node.attr("disabledimage"),
                regions: regions))
        }
        return result
    }

    /// A picture file name from a layout value, or nil for script/resource references.
    static func pictureName(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        let lower = value.lowercased()
        guard !lower.hasPrefix("jscript:"), !lower.hasPrefix("wmpprop:"), !lower.hasPrefix("res://"),
              pictureExtensions.contains((lower as NSString).pathExtension) else { return nil }
        return value
    }

    /// A readable name for a button element.
    private static func label(for element: WMSNode) -> String {
        let tag = element.tag
        switch tag {
        case "prevelement": return "previous"
        case "buttonelement":
            if let tip = element.attr("uptooltip") ?? element.attr("tooltip"), !tip.isEmpty { return tip }
            let click = (element.attr("onclick") ?? "").lowercased()
            if click.contains("minimize") { return "minimize" }
            if click.contains("close") { return "close" }
            return "custom"
        default:
            return tag.hasSuffix("element") ? String(tag.dropLast("element".count)) : tag
        }
    }
}

// MARK: - Pixels

/// An image as plain RGBA bytes (premultiplied alpha, top row first).
struct RGBAImage {
    let width: Int
    let height: Int
    var pixels: [UInt8]
    let colorSpace: CGColorSpace

    private static let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

    static func load(_ url: URL) -> RGBAImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }   // first frame only
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, width * height <= 16_000_000 else { return nil }

        // Prefer the picture's own colour space so the colours stay exactly as stored
        // (the key colours must match); fall back to plain RGB if that can't be used.
        var spaces: [CGColorSpace] = []
        if let own = image.colorSpace, own.model == .rgb { spaces.append(own) }
        spaces.append(CGColorSpaceCreateDeviceRGB())

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for space in spaces {
            var drawn = false
            pixels.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: space, bitmapInfo: bitmapInfo) else { return }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                drawn = true
            }
            if drawn { return RGBAImage(width: width, height: height, pixels: pixels, colorSpace: space) }
        }
        return nil
    }

    private func isClose(_ i: Int, to key: RGB, tolerance: Int) -> Bool {
        abs(Int(pixels[i]) - Int(key.r)) <= tolerance
            && abs(Int(pixels[i + 1]) - Int(key.g)) <= tolerance
            && abs(Int(pixels[i + 2]) - Int(key.b)) <= tolerance
    }

    /// Makes every (opaque) pixel close to one of the key colours fully transparent.
    /// Returns how many pixels were changed.
    mutating func makeTransparent(matching keys: [RGB], tolerance: Int) -> Int {
        guard !keys.isEmpty else { return 0 }
        var changed = 0
        for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 3] == 255 {
            if keys.contains(where: { isClose(i, to: $0, tolerance: tolerance) }) {
                pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0; pixels[i + 3] = 0
                changed += 1
            }
        }
        return changed
    }

    /// Smallest rectangle containing every pixel close to `color`, or nil if there are none.
    func boundingBox(of color: RGB, tolerance: Int) -> PixelRect? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                if pixels[i + 3] == 255, isClose(i, to: color, tolerance: tolerance) {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        return maxX < 0 ? nil : PixelRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    func writePNG(to url: URL) -> Bool {
        var copy = pixels
        let cgImage: CGImage? = copy.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: colorSpace, bitmapInfo: RGBAImage.bitmapInfo) else { return nil }
            return context.makeImage()
        }
        guard let image = cgImage,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}
