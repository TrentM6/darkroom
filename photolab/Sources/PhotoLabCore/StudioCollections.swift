import Foundation

// Collections: bodies of work the photographer puts together by hand ("New York Street"), from any shoots,
// in their own order. Kept in library.json; a collection holds references, never copies, so removing a
// photo from one (or deleting the collection) never touches a file. Exported like Best Work.

public struct CollectionFile: Codable, Equatable {
    public var id: String
    public var name: String
    public var created: String
    public var items: [ItemRef] = []
}

extension Studio {
    public var scanCamera: String? { sync { lib.scanCamera } }
    public func setScanCamera(_ c: String?) {
        let v = c?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        sync { lib.scanCamera = v.isEmpty ? nil : String(v.prefix(60)); markDirty("") }
    }

    /// A folder Darkroom made of links to photos elsewhere (it holds a ".darkroom-links" marker): its photos are
    /// reached through their collection, so it isn't listed among the projects.
    static func isLinkFolder(_ folder: String) -> Bool {
        FileManager.default.fileExists(atPath: URL(fileURLWithPath: folder).appendingPathComponent(".darkroom-links").path)
    }

    static func collectionId() -> String { "col-" + String(UUID().uuidString.prefix(8)).lowercased() }

    /// The items that still exist (a removed project or a photo gone from disk drops out quietly).
    func liveItems(_ c: CollectionFile) -> [ItemRef] {
        var seen = Set<ItemRef>()
        return c.items.filter { r in
            guard seen.insert(r).inserted, let i = photoIndex(r.projectId, r.id), let ph = projects[r.projectId]?.photos[i], !ph.gone else { return false }
            return true
        }
    }

    func collectionSummary(_ c: CollectionFile) -> [String: Any] {
        let items = liveItems(c)
        var cover: Any = NSNull()
        if let r = items.first, let p = projects[r.projectId], let i = photoIndex(r.projectId, r.id) { cover = thumbURL(p.id, p.photos[i]) ?? NSNull() }
        return ["id": c.id, "name": c.name, "count": items.count, "cover": cover, "created": c.created]
    }

    public func collectionsJSON() -> [[String: Any]] { sync { lib.collections.map { collectionSummary($0) } } }

    func collectionIndex(_ cid: String) throws -> Int {
        guard let i = lib.collections.firstIndex(where: { $0.id == cid }) else { throw StudioError.notFound("no collection \(cid)") }
        return i
    }

    static func cleanName(_ raw: String) throws -> String {
        let n = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        guard !n.isEmpty else { throw StudioError.bad("a collection needs a name") }
        return n
    }

    public func createCollection(_ name: String, items: [ItemRef] = []) throws -> [String: Any] {
        let n = try Self.cleanName(name)
        return sync {
            var c = CollectionFile(id: Self.collectionId(), name: n, created: Store.iso())
            c.items = items.filter { photoIndex($0.projectId, $0.id) != nil }
            lib.collections.append(c)
            markDirty("")
            return collectionSummary(c)
        }
    }

    public func renameCollection(_ cid: String, _ name: String) throws -> [String: Any] {
        let n = try Self.cleanName(name)
        return try sync {
            let i = try collectionIndex(cid)
            lib.collections[i].name = n
            markDirty("")
            return collectionSummary(lib.collections[i])
        }
    }

    public func deleteCollection(_ cid: String) throws {
        try sync {
            let i = try collectionIndex(cid)
            lib.collections.remove(at: i)
            markDirty("")
        }
    }

    /// Adds photos at the end, skipping ones already in it. Returns how many were added.
    public func addToCollection(_ cid: String, _ refs: [ItemRef]) throws -> (added: Int, summary: [String: Any]) {
        try sync {
            let i = try collectionIndex(cid)
            var have = Set(lib.collections[i].items)
            var added = 0
            for r in refs where photoIndex(r.projectId, r.id) != nil && have.insert(r).inserted {
                lib.collections[i].items.append(r); added += 1
            }
            if added > 0 { markDirty("") }
            return (added, collectionSummary(lib.collections[i]))
        }
    }

    public func removeFromCollection(_ cid: String, _ refs: [ItemRef]) throws -> [String: Any] {
        try sync {
            let i = try collectionIndex(cid)
            let gone = Set(refs)
            lib.collections[i].items.removeAll { gone.contains($0) }
            markDirty("")
            return collectionSummary(lib.collections[i])
        }
    }

    /// The given order first; anything left out keeps its place after them.
    public func setCollectionOrder(_ cid: String, _ refs: [ItemRef]) throws -> [ItemRef] {
        try sync {
            let i = try collectionIndex(cid)
            let current = liveItems(lib.collections[i]), valid = Set(current)
            var seen = Set<ItemRef>()
            var order = refs.filter { valid.contains($0) && seen.insert($0).inserted }
            order += current.filter { !seen.contains($0) }
            lib.collections[i].items = order
            markDirty("")
            return order
        }
    }

    /// A photo's collections, by name (the badge on Best Work, All Selects and collections). Called inside sync.
    func withCollections(_ d: [String: Any], _ pid: String, _ id: String) -> [String: Any] {
        let r = ItemRef(projectId: pid, id: id)
        var d = d
        d["collections"] = lib.collections.filter { $0.items.contains(r) }.map { ["id": $0.id, "name": $0.name] }
        return d
    }

    public func collectionJSON(_ cid: String) throws -> [String: Any] {
        try sync {
            let c = lib.collections[try collectionIndex(cid)]
            let photos = liveItems(c).compactMap { r -> [String: Any]? in
                guard let p = projects[r.projectId], let i = photoIndex(r.projectId, r.id) else { return nil }
                return withCollections(collectionItem(r.projectId, p, p.photos[i]), r.projectId, r.id)
            }
            var d = collectionSummary(c)
            d["photos"] = photos
            return d
        }
    }

    public func collectionRefs(_ cid: String) throws -> (name: String, items: [ItemRef]) {
        try sync { let c = lib.collections[try collectionIndex(cid)]; return (c.name, liveItems(c)) }
    }
}
