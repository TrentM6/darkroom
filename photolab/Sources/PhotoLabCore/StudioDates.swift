import Foundation

// Project dates: the first capture date (EXIF); else a date written in the folder name ("November 9 - NY
// Street", "jul.4", "11.17 Brooklyn", "2025-11-09 …"), with the year taken from the photos' file dates;
// else none (dateSource "file").

extension ISO8601DateFormatter {
    /// "2026-07-04T11:18:10" in local time.
    static let local: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        f.timeZone = .current
        return f
    }()
}

extension Studio {
    /// (yyyy-MM-dd or nil, "exif" | "folder" | "file")
    func projectDate(_ p: ProjectFile) -> (String?, String) {
        if let d = p.date, p.photos.contains(where: { $0.time != nil }) { return (d, "exif") }
        let key = p.id + "|" + p.folder
        if let cached = folderDates[key] { return cached.map { ($0, "folder") } ?? (nil, "file") }
        let fileDates = p.photos.prefix(40).compactMap { (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date }
        let names = [p.name] + URL(fileURLWithPath: p.folder).pathComponents.suffix(3).reversed()
        let d = names.lazy.compactMap { Self.dateInName($0, reference: fileDates.min() ?? Date()) }.first
        folderDates[key] = .some(d)
        return d.map { ($0, "folder") } ?? (nil, "file")
    }

    static let monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    /// A date written in a folder name. Without a year: the latest year that puts the date on or before
    /// `reference` (the photos were written after the shoot).
    static func dateInName(_ raw: String, reference: Date) -> String? {
        let s = raw.lowercased()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        func valid(_ y: Int, _ m: Int, _ d: Int) -> Bool {
            guard (1...12).contains(m), (1...31).contains(d), (1990...2100).contains(y) else { return false }
            return cal.date(from: DateComponents(year: y, month: m, day: d)).map { cal.component(.day, from: $0) == d } ?? false
        }
        func fmt(_ y: Int, _ m: Int, _ d: Int) -> String { String(format: "%04d-%02d-%02d", y, m, d) }
        func withYear(_ m: Int, _ d: Int) -> String? {
            var y = cal.component(.year, from: reference)
            guard valid(y, m, d) || valid(y - 1, m, d) else { return nil }
            if let date = cal.date(from: DateComponents(year: y, month: m, day: d)), date > reference.addingTimeInterval(2 * 86400) { y -= 1 }
            return valid(y, m, d) ? fmt(y, m, d) : nil
        }
        func groups(_ pattern: String) -> [String]? {
            guard let re = try? NSRegularExpression(pattern: pattern), let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
            return (1..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : String(s[Range(m.range(at: $0), in: s)!]) }
        }
        // 2025-11-09, 2025.11.09, 2025_11_09
        if let g = groups(#"(?<!\d)(\d{4})[-._ ](\d{1,2})[-._ ](\d{1,2})(?!\d)"#), let y = Int(g[0]), let m = Int(g[1]), let d = Int(g[2]), valid(y, m, d) { return fmt(y, m, d) }
        // November 9, nov.9th, aug.4th, Jul.3-…, 9 November
        if let g = groups(#"\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?[\s._-]*(\d{1,2})(?:st|nd|rd|th)?(?!\d)"#),
           let mi = monthNames.firstIndex(of: g[0]), let d = Int(g[1]), let r = withYear(mi + 1, d) { return r }
        if let g = groups(#"(?<!\d)(\d{1,2})(?:st|nd|rd|th)?[\s._-]+(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*"#),
           let d = Int(g[0]), let mi = monthNames.firstIndex(of: g[1]), let r = withYear(mi + 1, d) { return r }
        // 11.17 Brooklyn (month.day at the start)
        if let g = groups(#"^(\d{1,2})[./-](\d{1,2})(?!\d)"#), let m = Int(g[0]), let d = Int(g[1]), let r = withYear(m, d) { return r }
        return nil
    }
}
