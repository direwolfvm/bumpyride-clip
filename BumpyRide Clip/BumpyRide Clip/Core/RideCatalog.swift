import Foundation

/// Small display records only: never retain route points, bookmarks, or video data.
nonisolated struct RideCatalogEntry: Identifiable, Sendable {
    var id: URL { url }
    let url: URL
    let title: String
    let startedAt: Date?
    let duration: Double
    let reports: Int
    let syncs: Int
    let isProject: Bool
    let issue: String?

    init(url: URL, data: Data) throws {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        isProject = root?["format"] != nil
        let ride = isProject
            ? try ClipDates.decoder().decode(ClipProject.self, from: data).ride
            : try ClipDates.decoder().decode(RideData.self, from: data)
        self.url = url; title = ride.title; startedAt = ride.startedAt
        duration = ride.endedAt.timeIntervalSince(ride.startedAt)
        reports = ride.events.count; syncs = ride.syncs.count; issue = nil
    }
    init(url: URL, issue: String) {
        self.url = url; title = url.lastPathComponent; self.issue = issue
        startedAt = nil; duration = 0; reports = 0; syncs = 0; isProject = false
    }
    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || title.localizedStandardContains(query) || url.lastPathComponent.localizedStandardContains(query)
    }
}

nonisolated enum RideCatalog {
    static func read(_ url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(ClipError.message("Could not read this file."))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinated in
            result = Result {
                let values = try coordinated.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true else { throw ClipError.message("Choose a regular JSON file.") }
                guard (values.fileSize ?? 0) <= 100_000_000 else { throw ClipError.message("Ride JSON exceeds 100 MB.") }
                return try Data(contentsOf: coordinated)
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }
    static func scan(_ directory: URL) throws -> [RideCatalogEntry] {
        let urls = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        var entries: [RideCatalogEntry] = []
        for url in urls where ["json", "bumpyclip"].contains(url.pathExtension.lowercased()) {
            try Task.checkCancellation()
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            do { entries.append(try RideCatalogEntry(url: url, data: read(url))) }
            catch { entries.append(RideCatalogEntry(url: url, issue: "Couldn’t read this ride. Download it in Finder if it is cloud-only, then refresh.")) }
        }
        return entries.sorted {
            if $0.startedAt != $1.startedAt { return ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
            return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
    }
}
