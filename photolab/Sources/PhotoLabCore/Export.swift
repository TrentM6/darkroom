import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Per-shoot export settings, saved at <report>/edit/.photolab/export.json.
public struct ExportSettings: Codable, Equatable {
    public var frame: Bool = true          // thin border around the photo
    public var side: Double = 3            // left/right width, % of the image's long edge
    public var topBottom: Double = 2       // top/bottom width, % of the image's long edge
    public var color: String = "#FFFFFF"
    public var dest: String = ""           // "" = ~/Desktop/<shoot> edits

    public init() {}
    enum CodingKeys: String, CodingKey { case frame, side, topBottom, color, dest }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d(_ k: CodingKeys) -> Double? {
            if let v = try? c.decodeIfPresent(Double.self, forKey: k) { return v }
            if let s = try? c.decodeIfPresent(String.self, forKey: k) { return Double(s) }
            return nil
        }
        frame = (try? c.decodeIfPresent(Bool.self, forKey: .frame)) ?? true
        side = d(.side) ?? 3
        topBottom = d(.topBottom) ?? 2
        color = (try? c.decodeIfPresent(String.self, forKey: .color)) ?? "#FFFFFF"
        dest = (try? c.decodeIfPresent(String.self, forKey: .dest)) ?? ""
    }

    public func clamped() -> ExportSettings {
        var s = self
        func q(_ v: Double) -> Double { v.isFinite ? ((min(15, max(0, v)) * 10).rounded() / 10) : 0 }
        s.side = q(side); s.topBottom = q(topBottom)
        let hex = color.trimmingCharacters(in: .whitespaces).uppercased()
        s.color = hex.range(of: "^#[0-9A-F]{6}$", options: .regularExpression) != nil ? hex : "#FFFFFF"
        s.dest = dest.trimmingCharacters(in: .whitespacesAndNewlines)
        return s
    }

    /// Border widths in pixels for an image of the given size.
    public func border(width: Int, height: Int) -> (side: Int, topBottom: Int) {
        guard frame else { return (0, 0) }
        let long = Double(max(width, height))
        return (Int((long * side / 100).rounded()), Int((long * topBottom / 100).rounded()))
    }

    var rgb: (CGFloat, CGFloat, CGFloat) {
        let h = Array(color.dropFirst())
        func c(_ i: Int) -> CGFloat { CGFloat(Int(String(h[i...i + 1]), radix: 16) ?? 255) / 255 }
        return h.count == 6 ? (c(0), c(2), c(4)) : (1, 1, 1)
    }
}

public enum ExportError: Error, CustomStringConvertible {
    case badDestination(String), render, frame, write(String)
    public var description: String {
        switch self {
        case .badDestination(let m): return m
        case .render: return "RawTherapee export failed"
        case .frame: return "could not add the frame"
        case .write(let m): return "could not save: \(m)"
        }
    }
}

public struct ExportResult {
    public var path: URL
    public var width: Int, height: Int              // final file, frame included
    public var imageWidth: Int, imageHeight: Int    // the photo inside the frame
}

public func defaultExportDir(shoot: String) -> String {
    (NSHomeDirectory() as NSString).appendingPathComponent("Desktop/\(shoot) edits")
}

public func loadExportSettings(reportDir: URL) -> ExportSettings {
    let url = reportDir.appendingPathComponent("edit/.photolab/export.json")
    guard let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(ExportSettings.self, from: d) else { return ExportSettings() }
    return s.clamped()
}

public func saveExportSettings(_ s: ExportSettings, reportDir: URL) throws {
    let dir = reportDir.appendingPathComponent("edit/.photolab")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try enc.encode(s).write(to: dir.appendingPathComponent("export.json"), options: .atomic)
}

/// The export folder: settings.dest (or ~/Desktop/<shoot> edits), created if missing.
/// Refuses any folder holding originals (and the report's edit/ workspace, whose entries link to them).
public func resolveExportDir(_ s: ExportSettings, report: ShootReport, reportDir: URL, create: Bool = true) throws -> URL {
    let raw = s.dest.isEmpty ? defaultExportDir(shoot: report.name) : s.dest
    let expanded = (raw as NSString).expandingTildeInPath
    guard expanded.hasPrefix("/") else { throw ExportError.badDestination("the destination must be a full path (like ~/Desktop/\(report.name) edits)") }
    let url = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
    var forbidden = Set(report.photos.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path })
    forbidden.insert(URL(fileURLWithPath: report.sourcePath).standardizedFileURL.resolvingSymlinksInPath().path)
    forbidden.insert(reportDir.appendingPathComponent("edit").standardizedFileURL.resolvingSymlinksInPath().path)
    for f in forbidden where url.path == f || url.path.hasPrefix(f + "/") {
        throw ExportError.badDestination("won't export into the originals' folder (\(f)); choose another destination")
    }
    if url.path == "/" { throw ExportError.badDestination("choose a folder, not /") }
    if create {
        do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) } catch {
            throw ExportError.badDestination("can't create \(url.path): \(error.localizedDescription)")
        }
    }
    return url
}

/// Draws `input` (RawTherapee's 16-bit TIFF of the edit) 1:1 inset on a solid canvas and writes a
/// 16-bit TIFF to `output`, keeping the colour profile and metadata (pixels are upright: orientation 1).
/// The JPEG is encoded once afterwards by RawTherapee (ImageIO would pick 4:2:0 chroma at q95).
/// With `grain`, the grain is added to the photo first (never to the frame).
func addFrame(input: URL, output: URL, settings s: ExportSettings, grain: GrainSpec? = nil) -> (Int, Int)? {
    guard let src = CGImageSourceCreateWithURL(input as CFURL, nil),
          let raw = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    guard let img = grain.map({ Grain.apply(raw, $0) }) ?? raw else { return nil }
    let (bx, by) = s.border(width: img.width, height: img.height)
    let W = img.width + 2 * bx, H = img.height + 2 * by
    let cs = (img.colorSpace?.model == .rgb ? img.colorSpace : nil) ?? CGColorSpace(name: CGColorSpace.sRGB)!
    let deep = img.bitsPerComponent >= 16
    let info = CGImageAlphaInfo.noneSkipLast.rawValue | (deep ? CGBitmapInfo.byteOrder16Little.rawValue : 0)
    guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: deep ? 16 : 8, bytesPerRow: 0, space: cs, bitmapInfo: info) else { return nil }
    let (r, g, b) = s.rgb
    ctx.setFillColor(CGColor(colorSpace: cs, components: [r, g, b, 1]) ?? CGColor(red: r, green: g, blue: b, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    ctx.interpolationQuality = .none
    ctx.draw(img, in: CGRect(x: bx, y: by, width: img.width, height: img.height))   // 1:1, no resampling
    guard let framed = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(output as CFURL, UTType.tiff.identifier as CFString, 1, nil) else { return nil }
    let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]) ?? [:]
    var meta: [String: Any] = [kCGImagePropertyOrientation as String: 1]
    if var exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] {
        exif[kCGImagePropertyExifPixelXDimension as String] = W
        exif[kCGImagePropertyExifPixelYDimension as String] = H
        meta[kCGImagePropertyExifDictionary as String] = exif
    }
    if var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
        tiff[kCGImagePropertyTIFFOrientation as String] = 1
        tiff.removeValue(forKey: kCGImagePropertyTIFFCompression as String)
        meta[kCGImagePropertyTIFFDictionary as String] = tiff
    }
    CGImageDestinationAddImage(dest, framed, meta as CFDictionary)
    return CGImageDestinationFinalize(dest) ? (W, H) : nil
}

extension EditEngine {
    /// Full-resolution export of one photo with its current sidecar into `dir` as <basename>.jpg,
    /// framed if the settings say so. RawTherapee renders into the report folder first; only the
    /// finished file is written to `dir`.
    /// `owns(path)` says whether an existing file at `path` was written by a previous photolab export
    /// of this shoot; anything else is never overwritten (the export gets "<name> (2).jpg" instead).
    public func export(_ p: PhotoReport, toDir dir: URL, settings: ExportSettings, owns: (String) -> Bool = { _ in false }) -> Result<ExportResult, ExportError> {
        export(p.ref, toDir: dir, settings: settings, owns: owns)
    }

    /// `grain`: film grain added in the 16-bit TIFF step (forces that path even without a frame).
    public func export(_ p: PhotoRef, toDir dir: URL, settings: ExportSettings, grain: GrainSpec? = nil, owns: (String) -> Bool = { _ in false }) -> Result<ExportResult, ExportError> {
        let fm = FileManager()
        let base = (p.file as NSString).deletingPathExtension
        var out = dir.appendingPathComponent(base + ".jpg")
        var n = 2
        while fm.fileExists(atPath: out.path) && !owns(out.path) {
            out = dir.appendingPathComponent("\(base) (\(n)).jpg"); n += 1
        }
        // Never write through a link or onto an original.
        if let attrs = try? fm.attributesOfItem(atPath: out.path), attrs[.type] as? FileAttributeType == .typeSymbolicLink {
            return .failure(.write("\(out.path) is a link; refusing to overwrite it"))
        }
        if out.resolvingSymlinksInPath().path == URL(fileURLWithPath: p.path).resolvingSymlinksInPath().path {
            return .failure(.write("that is the original file"))
        }
        let tmpDir = exportTmp
        try? fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let framed = (settings.frame && (settings.side > 0 || settings.topBottom > 0)) || grain != nil
        // Framed: render a lossless 16-bit TIFF, add the frame, then encode the JPEG once.
        let rendered = tmpDir.appendingPathComponent("\(p.id)-\(UUID().uuidString).\(framed ? "tif" : "jpg")")
        defer { try? fm.removeItem(at: rendered) }
        let format = framed ? ["-t", "-b16"] : ["-j95", "-js3"]
        guard runRT(["-q", "-Y", "-p", sidecar(p).path, "-o", rendered.path] + format + ["-c", link(p).path], output: rendered, timeout: 90) else {
            return .failure(.render)
        }
        guard let src = CGImageSourceCreateWithURL(rendered as CFURL, nil),
              let pr = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
              let iw = pr[kCGImagePropertyPixelWidth as String] as? Int, let ih = pr[kCGImagePropertyPixelHeight as String] as? Int else {
            return .failure(.render)
        }
        let staged = dir.appendingPathComponent(".\(base)-\(UUID().uuidString).jpg")
        defer { try? fm.removeItem(at: staged) }
        var size = (iw, ih)
        if framed {
            let framedTIFF = tmpDir.appendingPathComponent("\(p.id)-\(UUID().uuidString)-framed.tif")
            let neutral = tmpDir.appendingPathComponent("neutral-\(UUID().uuidString).pp3")
            defer { try? fm.removeItem(at: framedTIFF); try? fm.removeItem(at: neutral) }
            guard let s = addFrame(input: rendered, output: framedTIFF, settings: settings, grain: grain),
                  (try? "[Version]\nAppVersion=5.11\nVersion=351\n".write(to: neutral, atomically: true, encoding: .utf8)) != nil else { return .failure(.frame) }
            // Neutral profile = no processing: RawTherapee only encodes (q95, 4:4:4).
            let encoded = tmpDir.appendingPathComponent("\(p.id)-\(UUID().uuidString)-framed.jpg")
            defer { try? fm.removeItem(at: encoded) }
            guard runRT(["-q", "-Y", "-p", neutral.path, "-o", encoded.path, "-j95", "-js3", "-c", framedTIFF.path], output: encoded, timeout: 90),
                  (try? fm.copyItem(at: encoded, to: staged)) != nil else { return .failure(.frame) }
            size = s
        } else {
            do { try fm.copyItem(at: rendered, to: staged) } catch { return .failure(.write(error.localizedDescription)) }
        }
        // The original's metadata (EXIF incl. maker notes where ImageIO keeps them, TIFF, GPS, IPTC, XMP),
        // copied without re-encoding the pixels. RawTherapee's own EXIF is incomplete and invents dates.
        let withMeta = tmpDir.appendingPathComponent("\(p.id)-\(UUID().uuidString)-meta.jpg")
        defer { try? fm.removeItem(at: withMeta) }
        if copyOriginalMetadata(original: link(p), jpeg: staged, to: withMeta, width: size.0, height: size.1) {
            try? fm.removeItem(at: staged)
            do { try fm.moveItem(at: withMeta, to: staged) } catch { return .failure(.write(error.localizedDescription)) }
        }
        do {
            if fm.fileExists(atPath: out.path) { _ = try fm.replaceItemAt(out, withItemAt: staged) } else { try fm.moveItem(at: staged, to: out) }
        } catch { return .failure(.write(error.localizedDescription)) }
        return .success(ExportResult(path: out, width: size.0, height: size.1, imageWidth: iw, imageHeight: ih))
    }
}

/// Writes `jpeg`'s image data unchanged (no re-encode) to `out` with the original's metadata: orientation
/// 1 (pixels are upright), pixel dimensions updated, Software = Baseline Darkroom. Dates are only those the
/// original has. The JPEG's colour profile (sRGB) is kept.
func copyOriginalMetadata(original: URL, jpeg: URL, to out: URL, width: Int, height: Int) -> Bool {
    guard let orig = CGImageSourceCreateWithURL(original as CFURL, nil),
          let src = CGImageSourceCreateWithURL(jpeg as CFURL, nil),
          let meta = CGImageSourceCopyMetadataAtIndex(orig, 0, nil),
          let m = CGImageMetadataCreateMutableCopy(meta),
          let type = CGImageSourceGetType(src),
          let dest = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil) else { return false }
    func set(_ path: String, _ value: Any) {
        CGImageMetadataRemoveTagWithPath(m, nil, path as CFString)
        let parts = path.split(separator: ":")
        let ns = parts[0] == "tiff" ? kCGImageMetadataNamespaceTIFF : parts[0] == "xmp" ? kCGImageMetadataNamespaceXMPBasic : kCGImageMetadataNamespaceExif
        if let tag = CGImageMetadataTagCreate(ns, parts[0] as CFString, parts[1] as CFString, .default, value as CFTypeRef) {
            _ = CGImageMetadataSetTagWithPath(m, nil, path as CFString, tag)
        }
    }
    set("tiff:Orientation", 1)
    set("exif:PixelXDimension", width)
    set("exif:PixelYDimension", height)
    set("tiff:Software", "Baseline Darkroom")
    set("xmp:CreatorTool", "Baseline Darkroom")      // ImageIO writes TIFF Software from this when present
    // Thumbnail/size tags of the original no longer apply.
    for path in ["tiff:ImageWidth", "tiff:ImageLength", "tiff:ImageHeight"] { CGImageMetadataRemoveTagWithPath(m, nil, path as CFString) }
    let opts: [CFString: Any] = [kCGImageDestinationMetadata: m, kCGImageDestinationMergeMetadata: false]
    var err: Unmanaged<CFError>?
    guard CGImageDestinationCopyImageSource(dest, src, opts as CFDictionary, &err) else { return false }
    return FileManager.default.fileExists(atPath: out.path)
}
