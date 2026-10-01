import Foundation

nonisolated enum ClipError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

nonisolated enum ClipDates {
    static func parse(_ text: String) throws -> Date {
        guard text.range(of: #"(Z|[+-]\d\d:\d\d)$"#, options: .regularExpression) != nil else {
            throw ClipError.message("Dates must include an ISO 8601 timezone.")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: text) else { throw ClipError.message("Invalid date: \(text)") }
        return date
    }
    static func string(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { try parse($0.singleValueContainer().decode(String.self)) }
        return decoder
    }
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer(); try container.encode(string(date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
    static func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite, abs(seconds) < Double(Int.max / 2) else { return "—" }
        let value = Int(abs(seconds))
        return String(format: "%@%02d:%02d", seconds < 0 ? "−" : "", value / 60, value % 60)
    }
}

nonisolated struct RideReport: Identifiable, Hashable, Sendable {
    enum Origin: String, Sendable { case closeCall, other }
    var id: String
    var timestamp: Date
    var kind: String
    var isCustom: Bool
    var category: String?
    var origin: Origin
    var isSync: Bool { origin == .other && kind.lowercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "_" } == "videosync" }
    var label: String {
        if origin == .closeCall { return "Close call" }
        if !isCustom && kind == "blocked-lane" { return "Blocked lane" }
        return kind
    }
    var symbol: String { origin == .closeCall ? "exclamationmark.triangle.fill" : isCustom ? "flag.fill" : "road.lanes" }
}

nonisolated private struct WireReport: Codable {
    var id: String?
    var timestamp: Date
    var kind: String?
    var isCustom: Bool?
    var category: String?
    init(_ report: RideReport) {
        id = report.id; timestamp = report.timestamp; category = report.category
        kind = report.origin == .other ? report.kind : nil
        isCustom = report.origin == .other ? report.isCustom : nil
    }
}
nonisolated private struct LossyReport: Decodable {
    let value: WireReport?
    init(from decoder: Decoder) throws { value = try? WireReport(from: decoder) }
}

/// Decodes the iCloud ride schema directly. GPS traces and hard brakes are never retained.
nonisolated struct RideData: Codable, Sendable {
    var id: String
    var title: String
    var startedAt: Date
    var endedAt: Date
    var events: [RideReport]
    var syncs: [RideReport]
    var warnings: [String]
    private enum CodingKeys: String, CodingKey { case id, title, startedAt, endedAt, closeCallEvents, otherEvents }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); title = try c.decode(String.self, forKey: .title)
        startedAt = try c.decode(Date.self, forKey: .startedAt); endedAt = try c.decode(Date.self, forKey: .endedAt)
        guard !id.isEmpty, endedAt >= startedAt else { throw ClipError.message("Choose a valid BumpyRide ride JSON.") }
        events = []; syncs = []; warnings = []; var ids = Set<String>()
        for (key, origin) in [(CodingKeys.closeCallEvents, RideReport.Origin.closeCall), (.otherEvents, .other)] {
            for (index, item) in (try c.decodeIfPresent([LossyReport].self, forKey: key) ?? []).enumerated() {
                guard let item = item.value, origin == .closeCall || !(item.kind?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) else {
                    warnings.append("Skipped invalid \(key.rawValue) entry \(index + 1)."); continue
                }
                let reportID = item.id ?? "\(key.rawValue)-\(index)"
                guard ids.insert(reportID).inserted else { warnings.append("Skipped duplicate report \(reportID)."); continue }
                let report = RideReport(id: reportID, timestamp: item.timestamp,
                    kind: origin == .closeCall ? "close-call" : item.kind!, isCustom: origin == .other && item.isCustom == true,
                    category: item.category, origin: origin)
                if report.isSync { syncs.append(report) } else { events.append(report) }
            }
        }
        events.sort { $0.timestamp < $1.timestamp }; syncs.sort { $0.timestamp < $1.timestamp }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(title, forKey: .title)
        try c.encode(startedAt, forKey: .startedAt); try c.encode(endedAt, forKey: .endedAt)
        try c.encode(events.filter { $0.origin == .closeCall }.map(WireReport.init), forKey: .closeCallEvents)
        try c.encode((events.filter { $0.origin == .other } + syncs).map(WireReport.init), forKey: .otherEvents)
    }
}

nonisolated struct ClipEdit: Codable, Equatable, Sendable {
    var before: Double = 15
    var after: Double = 5
    var selected = false
    var reviewed = false
    init(before: Double = 15, after: Double = 5, selected: Bool = false, reviewed: Bool = false) {
        self.before = before; self.after = after; self.selected = selected; self.reviewed = reviewed
    }
    private enum CodingKeys: String, CodingKey { case before, after, selected, reviewed }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        before = try c.decodeIfPresent(Double.self, forKey: .before) ?? 15
        after = try c.decodeIfPresent(Double.self, forKey: .after) ?? 5
        selected = try c.decodeIfPresent(Bool.self, forKey: .selected) ?? false
        reviewed = try c.decodeIfPresent(Bool.self, forKey: .reviewed) ?? false
        try validate()
    }
    func validate() throws {
        guard before.isFinite, after.isFinite, before >= 0, after >= 0, before + after > 0 else {
            throw ClipError.message("Clip handles must be non-negative and total more than zero.")
        }
    }
}

nonisolated struct SourceRecord: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    var name: String
    var size: Int64
    var duration: Double
    var mtimeMs: Double?
    var gapBefore: Double = 0
    var bookmark: Data?
    private enum CodingKeys: String, CodingKey { case id, name, size, duration, mtimeMs, gapBefore, bookmark }
    init(name: String, size: Int64, duration: Double, mtimeMs: Double?, bookmark: Data? = nil) {
        self.name = name; self.size = size; self.duration = duration; self.mtimeMs = mtimeMs; self.bookmark = bookmark
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name); size = try c.decode(Int64.self, forKey: .size)
        duration = try c.decode(Double.self, forKey: .duration); mtimeMs = try c.decodeIfPresent(Double.self, forKey: .mtimeMs)
        gapBefore = try c.decodeIfPresent(Double.self, forKey: .gapBefore) ?? 0
        bookmark = try c.decodeIfPresent(Data.self, forKey: .bookmark)
        try validate()
    }
    func validate() throws {
        guard !name.isEmpty, size >= 0, duration.isFinite, duration > 0, gapBefore.isFinite, gapBefore >= 0,
              mtimeMs == nil || mtimeMs!.isFinite else { throw ClipError.message("Invalid video metadata.") }
    }
    func matches(_ other: SourceRecord) -> Bool {
        name == other.name && size == other.size && abs(duration - other.duration) < 0.25 &&
        (mtimeMs == nil || other.mtimeMs == nil || abs(mtimeMs! - other.mtimeMs!) < 2000)
    }
}

/// Version 1 stays compatible with web .bumpyclip.json projects; bookmarks are an optional native extension.
nonisolated struct ClipProject: Codable, Sendable {
    var format = "bumpyride-clip"
    var version = 1
    var ride: RideData
    var sources: [SourceRecord] = []
    var videoStart: Date?
    var syncId = ""
    var offset: Double = 0
    var edits: [String: ClipEdit] = [:]
    // The native sample regenerates its temporary video when reopened.
    var demoVersion: Int?
    init(ride: RideData) {
        self.ride = ride
        if ride.syncs.count == 1 { videoStart = ride.syncs[0].timestamp; syncId = ride.syncs[0].id }
    }
    mutating func calibrate(to adjustment: Double) throws {
        guard let start = videoStart, adjustment.isFinite else { throw ClipError.message("Set video sync first and enter a finite adjustment.") }
        let corrected = start.addingTimeInterval(adjustment - offset)
        guard corrected.timeIntervalSince1970.isFinite, abs(corrected.timeIntervalSince1970) < 253_402_300_800 else { throw ClipError.message("Sync adjustment is out of range.") }
        videoStart = corrected; offset = adjustment
    }
    mutating func applyTimingToSelected(before: Double, after: Double) throws {
        try ClipEdit(before: before, after: after).validate()
        for event in ride.events where edits[event.id]?.selected == true {
            edits[event.id]?.before = before; edits[event.id]?.after = after
        }
    }
    private enum CodingKeys: String, CodingKey { case format, version, ride, sources, videoStart, syncId, offset, edits, demoVersion }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(String.self, forKey: .format) == "bumpyride-clip", try c.decode(Int.self, forKey: .version) == 1 else {
            throw ClipError.message("Unsupported project format or version.")
        }
        ride = try c.decode(RideData.self, forKey: .ride); sources = try c.decode([SourceRecord].self, forKey: .sources)
        guard sources.count <= 100, Set(sources.map(\.id)).count == sources.count else { throw ClipError.message("Invalid project source list.") }
        let start = try c.decodeIfPresent(String.self, forKey: .videoStart) ?? ""
        videoStart = start.isEmpty ? nil : try ClipDates.parse(start)
        syncId = try c.decodeIfPresent(String.self, forKey: .syncId) ?? ""
        offset = try c.decodeIfPresent(Double.self, forKey: .offset) ?? 0
        guard offset.isFinite else { throw ClipError.message("Invalid sync adjustment.") }
        edits = try c.decodeIfPresent([String: ClipEdit].self, forKey: .edits) ?? [:]
        demoVersion = try c.decodeIfPresent(Int.self, forKey: .demoVersion)
        guard demoVersion == nil || demoVersion == 1 else { throw ClipError.message("Unsupported sample project version.") }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(format, forKey: .format); try c.encode(version, forKey: .version); try c.encode(ride, forKey: .ride)
        try c.encode(sources, forKey: .sources); try c.encode(videoStart.map(ClipDates.string) ?? "", forKey: .videoStart)
        try c.encode(syncId, forKey: .syncId); try c.encode(offset, forKey: .offset); try c.encode(edits, forKey: .edits)
        try c.encodeIfPresent(demoVersion, forKey: .demoVersion)
    }
}

nonisolated struct ClipPart: Sendable { var sourceID: UUID; var offset: Double; var duration: Double }
nonisolated struct ClipPlan: Sendable {
    var eventOffset: Double
    var start: Double
    var end: Double
    var parts: [ClipPart]
    var isClamped: Bool
    var reason: String?
    var duration: Double { parts.reduce(0) { $0 + $1.duration } }
    var available: Bool { reason == nil && duration > 0 }
}
nonisolated enum ClipTimeline {
    static func segments(_ sources: [SourceRecord]) throws -> [(source: SourceRecord, start: Double, end: Double)] {
        var cursor: Double = 0
        return try sources.enumerated().map { index, source in
            try source.validate()
            let start = cursor + (index == 0 ? 0 : source.gapBefore)
            cursor = start + source.duration
            guard cursor.isFinite else { throw ClipError.message("Recording timeline is too long.") }
            return (source, start, cursor)
        }
    }
    static func resolve(_ event: RideReport, edit: ClipEdit, videoStart: Date, sources: [SourceRecord]) throws -> ClipPlan {
        try edit.validate()
        let segments = try segments(sources), offset = event.timestamp.timeIntervalSince(videoStart)
        let requestedStart = offset - edit.before, requestedEnd = offset + edit.after, total = segments.last?.end ?? 0
        let start = max(0, requestedStart), end = min(total, requestedEnd)
        let parts = segments.compactMap { segment -> ClipPart? in
            let lower = max(start, segment.start), upper = min(end, segment.end)
            return upper - lower > 0.0001 ? ClipPart(sourceID: segment.source.id, offset: lower - segment.start, duration: upper - lower) : nil
        }
        let duration = parts.reduce(0) { $0 + $1.duration }
        let covered = segments.contains { offset >= $0.start && offset < $0.end }
        let hasGap = end > start && duration < end - start - 0.01
        return ClipPlan(eventOffset: offset, start: start, end: end, parts: parts,
            isClamped: requestedStart < 0 || requestedEnd > total,
            reason: !covered ? "This report is outside the available footage." : hasGap ? "This clip crosses a recording gap. Shorten its handles or correct the gap." : nil)
    }
}
