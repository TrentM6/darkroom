import Foundation
import ImageIO

// MARK: - Standard EXIF via ImageIO

func readCapture(_ props: [String: Any]) -> CaptureInfo {
    let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
    let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
    let aux = props[kCGImagePropertyExifAuxDictionary as String] as? [String: Any] ?? [:]

    func d(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    let dateStr = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String
    let offset = exif["OffsetTimeOriginal"] as? String
    var ts: Double? = nil
    if let dateStr {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        if let offset {
            f.dateFormat = "yyyy:MM:dd HH:mm:ssxxx"
            ts = f.date(from: dateStr + offset)?.timeIntervalSince1970
        }
        if ts == nil {
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            ts = f.date(from: dateStr)?.timeIntervalSince1970
        }
        if let sub = exif[kCGImagePropertyExifSubsecTimeOriginal as String] as? String, let s = Double("0." + sub), ts != nil {
            ts! += s
        }
    }

    let fn = d(exif[kCGImagePropertyExifFNumber as String])
    let exposure = d(exif[kCGImagePropertyExifExposureTime as String])
    var shutter: String? = nil
    if let t = exposure {
        if t < 1 { shutter = "1/\(Int((1 / t).rounded()))" } else { shutter = String(format: "%gs", t) }
    }
    let iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.intValue

    let programs = [0: "Not defined", 1: "Manual", 2: "Program AE", 3: "Aperture priority", 4: "Shutter priority", 5: "Creative", 6: "Action", 7: "Portrait", 8: "Landscape"]
    let meters = [0: "Unknown", 1: "Average", 2: "Center-weighted", 3: "Spot", 4: "Multi-spot", 5: "Multi-segment", 6: "Partial"]
    var flashFired: Bool? = nil
    if let f = exif[kCGImagePropertyExifFlash as String] as? NSNumber { flashFired = (f.intValue & 1) == 1 }

    var af: [Double]? = nil
    if let a = aux["AFInfo"] as? [Any], a.count >= 4 {
        let vals = a.prefix(4).compactMap { d($0) }
        if vals.count == 4 {
            // Fuji reports the AF frame centre and size, normalized.
            af = [vals[0] - vals[2] / 2, vals[1] - vals[3] / 2, vals[2], vals[3]]
        }
    }
    var focusMode: String? = nil
    if let fm = aux["FocusMode"] as? NSNumber { focusMode = fm.intValue == 0 ? "Manual / unknown" : "Auto (\(fm.intValue))" }

    let lens = (exif[kCGImagePropertyExifLensModel as String] as? String) ?? (aux["LensModel"] as? String)
    return CaptureInfo(
        dateTimeOriginal: dateStr,
        timestamp: ts,
        make: (tiff[kCGImagePropertyTIFFMake as String] as? String)?.trimmingCharacters(in: .whitespaces),
        model: (tiff[kCGImagePropertyTIFFModel as String] as? String)?.trimmingCharacters(in: .whitespaces),
        lens: lens?.trimmingCharacters(in: .whitespaces),
        manualLens: (fn ?? 0) == 0,
        focalLength: d(exif[kCGImagePropertyExifFocalLength as String]),
        focalLength35: d(exif[kCGImagePropertyExifFocalLenIn35mmFilm as String]),
        fNumber: (fn ?? 0) > 0 ? fn : nil,
        exposureTime: exposure,
        shutter: shutter,
        iso: iso,
        exposureBias: d(exif[kCGImagePropertyExifExposureBiasValue as String]),
        exposureProgram: (exif[kCGImagePropertyExifExposureProgram as String] as? NSNumber).flatMap { programs[$0.intValue] },
        meteringMode: (exif[kCGImagePropertyExifMeteringMode as String] as? NSNumber).flatMap { meters[$0.intValue] },
        flashFired: flashFired,
        brightnessValue: d(exif[kCGImagePropertyExifBrightnessValue as String]),
        software: tiff[kCGImagePropertyTIFFSoftware as String] as? String,
        focusMode: focusMode,
        afPoint: af,
        compressedBitsPerPixel: d(exif[kCGImagePropertyExifCompressedBitsPerPixel as String])
    )
}

// MARK: - Fujifilm maker notes (parsed directly from the EXIF block)

enum TagValue {
    case ints([Int])
    case string(String)
    case doubles([Double])

    var int: Int? {
        if case .ints(let v) = self { return v.first }
        return nil
    }
    var intArray: [Int]? {
        if case .ints(let v) = self { return v }
        return nil
    }
    var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

private struct Bytes {
    let d: [UInt8]
    let little: Bool
    func u16(_ o: Int) -> Int {
        guard o + 1 < d.count else { return 0 }
        return little ? Int(d[o]) | Int(d[o + 1]) << 8 : Int(d[o]) << 8 | Int(d[o + 1])
    }
    func u32(_ o: Int) -> Int {
        guard o + 3 < d.count else { return 0 }
        if little { return Int(d[o]) | Int(d[o + 1]) << 8 | Int(d[o + 2]) << 16 | Int(d[o + 3]) << 24 }
        return Int(d[o]) << 24 | Int(d[o + 1]) << 16 | Int(d[o + 2]) << 8 | Int(d[o + 3])
    }
}

/// Reads the Fujifilm MakerNote IFD from a JPEG's APP1 EXIF segment.
func readFujiMakerNotes(url: URL) -> [Int: TagValue] {
    guard let fh = try? FileHandle(forReadingFrom: url) else { return [:] }
    defer { try? fh.close() }
    guard var head = try? fh.read(upToCount: 256 * 1024) else { return [:] }
    // A Fuji RAF starts "FUJIFILMCCD-RAW" and holds a full JPEG preview (with the camera's EXIF and maker notes)
    // at the big-endian offset in bytes 84–87: read the notes from there.
    if head.count > 92, head.starts(with: Array("FUJIFILMCCD-RAW".utf8)) {
        let h = [UInt8](head.prefix(92))
        let off = Int(h[84]) << 24 | Int(h[85]) << 16 | Int(h[86]) << 8 | Int(h[87])
        guard off > 0, (try? fh.seek(toOffset: UInt64(off))) != nil, let jpeg = try? fh.read(upToCount: 256 * 1024) else { return [:] }
        head = jpeg
    }
    let bytes = [UInt8](head)
    guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return [:] }

    // Walk JPEG segments to APP1/Exif.
    var p = 2
    var tiffStart = -1
    while p + 4 < bytes.count {
        guard bytes[p] == 0xFF else { break }
        let marker = bytes[p + 1]
        let len = Int(bytes[p + 2]) << 8 | Int(bytes[p + 3])
        if marker == 0xE1, p + 10 < bytes.count,
           bytes[p + 4] == 0x45, bytes[p + 5] == 0x78, bytes[p + 6] == 0x69, bytes[p + 7] == 0x66 {
            tiffStart = p + 10
            break
        }
        if marker == 0xDA { break }
        p += 2 + len
    }
    guard tiffStart > 0 else { return [:] }

    let little = bytes[tiffStart] == 0x49
    let b = Bytes(d: bytes, little: little)
    func findTag(ifdAt: Int, tag: Int) -> (type: Int, count: Int, value: Int)? {
        let n = b.u16(ifdAt)
        guard n > 0, n < 1000 else { return nil }
        for i in 0..<n {
            let e = ifdAt + 2 + i * 12
            if b.u16(e) == tag { return (b.u16(e + 2), b.u32(e + 4), b.u32(e + 8)) }
        }
        return nil
    }
    let ifd0 = tiffStart + b.u32(tiffStart + 4)
    guard let exifPtr = findTag(ifdAt: ifd0, tag: 0x8769) else { return [:] }
    let exifIFD = tiffStart + exifPtr.value
    guard let mn = findTag(ifdAt: exifIFD, tag: 0x927C) else { return [:] }
    let mStart = tiffStart + mn.value
    guard mStart + 12 < bytes.count,
          String(bytes: bytes[mStart..<mStart + 8], encoding: .ascii) == "FUJIFILM" else { return [:] }

    // Fuji maker notes are always little-endian, offsets relative to the maker note start.
    let m = Bytes(d: bytes, little: true)
    let ifd = mStart + m.u32(mStart + 8)
    let count = m.u16(ifd)
    guard count > 0, count < 2000 else { return [:] }
    let typeSize = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8]
    var out: [Int: TagValue] = [:]
    for i in 0..<count {
        let e = ifd + 2 + i * 12
        let tag = m.u16(e), type = m.u16(e + 2), n = m.u32(e + 4)
        guard let sz = typeSize[type], n > 0, n < 4096 else { continue }
        let total = sz * n
        let at = total <= 4 ? e + 8 : mStart + m.u32(e + 8)
        guard at + total <= bytes.count else { continue }
        switch type {
        case 2:
            let s = String(bytes: bytes[at..<at + total].prefix { $0 != 0 }, encoding: .ascii) ?? ""
            out[tag] = .string(s.trimmingCharacters(in: .whitespaces))
        case 1, 7:
            out[tag] = .ints((0..<n).map { Int(bytes[at + $0]) })
        case 6:
            out[tag] = .ints((0..<n).map { Int(Int8(bitPattern: bytes[at + $0])) })
        case 3:
            out[tag] = .ints((0..<n).map { m.u16(at + $0 * 2) })
        case 8:
            out[tag] = .ints((0..<n).map { Int(Int16(truncatingIfNeeded: m.u16(at + $0 * 2))) })
        case 4:
            out[tag] = .ints((0..<n).map { m.u32(at + $0 * 4) })
        case 9:
            out[tag] = .ints((0..<n).map { Int(Int32(truncatingIfNeeded: m.u32(at + $0 * 4))) })
        case 5, 10:
            out[tag] = .doubles((0..<n).map {
                let num = m.u32(at + $0 * 8), den = m.u32(at + $0 * 8 + 4)
                let sn = type == 10 ? Double(Int32(truncatingIfNeeded: num)) : Double(num)
                let sd = type == 10 ? Double(Int32(truncatingIfNeeded: den)) : Double(den)
                return sd == 0 ? 0 : sn / sd
            })
        default:
            continue
        }
    }
    return out
}

func fujiSettings(tags: [Int: TagValue], pictureStyle: [String: Any]?) -> FujiSettings? {
    guard !tags.isEmpty else { return nil }

    let filmModes: [Int: String] = [
        0x000: "Provia / Standard", 0x100: "Studio Portrait", 0x110: "Studio Portrait (enhanced saturation)",
        0x120: "Astia / Soft", 0x130: "Studio Portrait (increased sharpness)", 0x200: "Velvia / Vivid",
        0x300: "Studio Portrait Ex", 0x400: "Velvia / Vivid", 0x500: "Pro Neg. Std", 0x501: "Pro Neg. Hi",
        0x600: "Classic Chrome", 0x700: "Eterna", 0x800: "Classic Negative", 0x900: "Eterna Bleach Bypass",
        0xA00: "Nostalgic Neg.", 0xB00: "Reala Ace",
    ]
    let monoModes: [Int: String] = [
        0x300: "Monochrome", 0x301: "Monochrome + R filter", 0x302: "Monochrome + Ye filter",
        0x303: "Monochrome + G filter", 0x310: "Sepia", 0x500: "Acros", 0x501: "Acros + R filter",
        0x502: "Acros + Ye filter", 0x503: "Acros + G filter",
    ]
    let saturationRaw = tags[0x1003]?.int
    var film = "Unknown"
    if let fm = tags[0x1401]?.int { film = filmModes[fm] ?? String(format: "Film mode 0x%X", fm) }
    if let s = saturationRaw, let mono = monoModes[s] { film = mono }

    var dr: String? = nil
    if let dev = tags[0x1403]?.int, dev > 0 { dr = "DR\(dev)" }
    let drSettings = [0: "Auto", 1: "Manual", 0x100: "Standard (100%)", 0x200: "Wide 1 (200%)", 0x201: "Wide 2 (400%)", 0x8000: "Film Simulation"]
    let drSetting = tags[0x1402]?.int.flatMap { drSettings[$0] }
    var focusMode: String? = nil
    if let fm = tags[0x1021]?.int { focusMode = [0: "AF", 1: "Manual focus"][fm] }
    if dr == nil, let s = tags[0x1402]?.int {
        dr = [0x100: "DR100", 0x200: "DR200", 0x201: "DR400"][s]
        // In Auto, the camera records the DR it actually chose in AutoDynamicRange.
        if s == 0, let auto = tags[0x140B]?.int, auto > 0 { dr = "DR\(auto) (auto)" }
    }
    var drPriority: String? = nil
    if let p = tags[0x1443]?.int {
        if p == 0 { drPriority = "Off" }
        else if p == 1 { drPriority = "Auto" }
        if let fixed = tags[0x1445]?.int, fixed > 0 { drPriority = fixed == 1 ? "Weak" : "Strong" }
    }

    // Tone settings are stored as -16 per +1 step.
    func tone(_ t: Int) -> Double? { tags[t]?.int.map { -Double($0) / 16 } }

    let level3: [Int: String] = [0: "Off", 32: "Weak", 64: "Strong"]
    var grain = "Off"
    if let rough = tags[0x1047]?.int, rough > 0 {
        grain = level3[rough] ?? "On"
        if let size = tags[0x104C]?.int { grain += size == 32 ? ", Large" : size == 16 ? ", Small" : "" }
    }
    let chrome = tags[0x1048]?.int.flatMap { level3[$0] } ?? "—"
    let chromeBlue = tags[0x104E]?.int.flatMap { level3[$0] } ?? "—"

    let nrMap: [Int: String] = [0x0: "0", 0x100: "+2", 0x180: "+1", 0x1C0: "+3", 0x1E0: "+4", 0x200: "-2", 0x280: "-1", 0x2C0: "-3", 0x2E0: "-4", 0x8000: "Normal"]
    let nr = tags[0x100E]?.int.flatMap { nrMap[$0] }

    let wbMap: [Int: String] = [
        0x0: "Auto", 0x1: "Auto (white priority)", 0x2: "Auto (ambience priority)", 0x100: "Daylight",
        0x200: "Shade", 0x300: "Fluorescent 1", 0x301: "Fluorescent 2", 0x302: "Fluorescent 3",
        0x303: "Fluorescent 4", 0x304: "Fluorescent 5", 0x400: "Incandescent", 0x500: "Flash",
        0x600: "Underwater", 0xF00: "Custom 1", 0xF01: "Custom 2", 0xF02: "Custom 3", 0xF03: "Custom 4",
        0xF04: "Custom 5", 0xFF0: "Kelvin",
    ]
    let wb = tags[0x1002]?.int.flatMap { wbMap[$0] }
    var wbShift: [Int]? = nil
    if let ft = tags[0x100A]?.intArray, ft.count >= 2 { wbShift = [ft[0] / 20, ft[1] / 20] }

    let colorNames: [String: String] = ["Normal": "0", "Medium High": "+1", "High": "+2", "Medium Low": "-1", "Low": "-2"]
    var color: String? = nil
    if let ps = pictureStyle, let sat = ps["Saturation"] as? [Any], let name = sat.first as? String {
        color = colorNames[name] ?? name
    }
    let sharpMap: [Int: String] = [0x0: "-4", 0x1: "-3", 0x2: "-2", 0x3: "0", 0x4: "+2", 0x5: "+3", 0x6: "+4", 0x82: "-1", 0x84: "+1", 0x8000: "Film Simulation"]
    let sharp = tags[0x1001]?.int.flatMap { sharpMap[$0] }
    if monoModes[saturationRaw ?? -1] != nil { color = "B&W" }

    var warnings: [String] = []
    if tags[0x1300]?.int == 1 { warnings.append("Blur warning") }
    if tags[0x1301]?.int == 1 { warnings.append("Focus warning") }
    if tags[0x1302]?.int == 1 { warnings.append("Exposure warning") }

    let shutterTypes = [0: "Mechanical", 1: "Electronic", 2: "Electronic (long)", 3: "Electronic front curtain"]
    let clarity = tags[0x100F]?.int.map { Int(Int32(truncatingIfNeeded: $0)) / 1000 }

    let ht = tone(0x1041), st = tone(0x1040)
    func signed(_ v: Double?) -> String {
        guard let v else { return "—" }
        return v == 0 ? "0" : (v > 0 ? "+" : "") + String(format: v == v.rounded() ? "%.0f" : "%.1f", v)
    }
    var recipe = film
    if let dr { recipe += " · \(dr)" }
    if let sharp { recipe += " · Sharp \(sharp)" }
    if let nr { recipe += " · NR \(nr)" }
    recipe += " · H \(signed(ht)) S \(signed(st))"
    if let color { recipe += " · Color \(color)" }
    if grain != "Off" { recipe += " · Grain \(grain)" }
    if chrome != "Off" && chrome != "—" { recipe += " · CCE \(chrome)" }
    if let wb { recipe += " · WB \(wb)" }
    if let s = wbShift, s != [0, 0] { recipe += String(format: " R%+d B%+d", s[0], s[1]) }

    return FujiSettings(
        filmSimulation: film,
        dynamicRange: dr,
        dynamicRangeSetting: drSetting,
        dRangePriority: drPriority,
        highlightTone: ht,
        shadowTone: st,
        color: color,
        sharpness: sharp,
        noiseReduction: nr,
        clarity: clarity,
        grainEffect: grain,
        colorChrome: chrome,
        colorChromeBlue: chromeBlue,
        whiteBalance: wb,
        whiteBalanceShift: wbShift,
        colorTemperature: tags[0x1005]?.int,
        quality: tags[0x1000]?.string,
        shutterType: tags[0x1050]?.int.flatMap { shutterTypes[$0] },
        sequenceNumber: tags[0x1101]?.int,
        cameraWarnings: warnings,
        facesDetectedByCamera: tags[0x4100]?.int,
        focusMode: focusMode,
        recipe: recipe
    )
}

/// Debug: every raw Fujifilm maker-note tag in a file.
public func dumpFujiTags(path: String) -> [String] {
    readFujiMakerNotes(url: URL(fileURLWithPath: path)).sorted { $0.key < $1.key }.map { k, v in
        switch v {
        case .ints(let a): return String(format: "0x%04X  ", k) + a.prefix(16).map(String.init).joined(separator: " ")
        case .string(let s): return String(format: "0x%04X  ", k) + "\"" + s + "\""
        case .doubles(let d): return String(format: "0x%04X  ", k) + d.map { String($0) }.joined(separator: " ")
        }
    }
}
