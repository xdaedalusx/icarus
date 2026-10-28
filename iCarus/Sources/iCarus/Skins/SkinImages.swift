import SwiftUI
import AppKit

/// Remembers decoded (and cropped) skin images so widgets can ask for them every frame.
private final class ImageBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

enum SkinImageCache {
    fileprivate static let cache = NSCache<NSString, ImageBox>()

    /// Called whenever skins are reloaded so a re-imported skin doesn't show stale artwork.
    static func clear() { cache.removeAllObjects() }
}

extension Skin {
    /// True when the skin wants a borderless window whose outline follows its artwork.
    var isShaped: Bool {
        manifest.layout == .widgets && manifest.widgets?.shaped == true
    }

    /// An image from the skin's folder, optionally cropped to `crop` = [x, y, width, height]
    /// in image pixels (top-left origin). Returns nil for built-in skins or missing files.
    ///
    /// Only the file NAME is used, so a skin can't reach outside its own folder.
    func image(named name: String?, crop: [Double]? = nil) -> CGImage? {
        guard let directory, let name, !name.isEmpty else { return nil }
        let safeName = (name as NSString).lastPathComponent
        let url = directory.appendingPathComponent(safeName)
        let cropKey = crop?.map { String($0) }.joined(separator: ",") ?? "-"
        let key = "\(url.path)|\(cropKey)" as NSString

        if let hit = SkinImageCache.cache.object(forKey: key) { return hit.image }

        guard let source = NSImage(contentsOf: url),
              var cgImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        if let crop, crop.count == 4 {
            let rect = CGRect(x: crop[0], y: crop[1], width: crop[2], height: crop[3])
            guard let cropped = cgImage.cropping(to: rect) else { return nil }
            cgImage = cropped
        }
        SkinImageCache.cache.setObject(ImageBox(cgImage), forKey: key)
        return cgImage
    }
}
