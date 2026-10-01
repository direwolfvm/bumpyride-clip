import Testing
import Foundation
@testable import ClipCore

struct ClipCoreTests {
    static let json = """
    {"id":"ride","title":"Ride","startedAt":"2026-09-02T12:00:00Z","endedAt":"2026-09-02T13:00:00Z",
    "closeCallEvents":[{"id":"close","timestamp":"2026-09-02T12:00:30Z","category":"vehicle"},{"id":"bad","timestamp":"not-a-date"}],
    "otherEvents":[{"id":"sync","timestamp":"2026-09-02T12:00:00Z","kind":" Video_Sync ","isCustom":true},
    {"id":"blocked","timestamp":"2026-09-02T12:01:00Z","kind":"blocked-lane"},
    {"id":"custom","timestamp":"2026-09-02T12:02:00Z","kind":"Pothole","isCustom":true}],
    "brakeEvents":[{"id":"brake","timestamp":"2026-09-02T12:00:10Z"}],"points":[{"latitude":1,"longitude":2}]}
    """
    static func ride() throws -> RideData { try ClipDates.decoder().decode(RideData.self, from: Data(json.utf8)) }
    static func source(_ duration: Double) -> SourceRecord { SourceRecord(name: UUID().uuidString + ".mov", size: 100, duration: duration, mtimeMs: nil) }

    @Test func parsesRideReportsAndSyncWithoutBrakesOrGPS() throws {
        let ride = try Self.ride()
        #expect(ride.events.map(\.id) == ["close", "blocked", "custom"])
        #expect(ride.events[1].label == "Blocked lane")
        #expect(ride.events[2].isCustom)
        #expect(ride.syncs.count == 1)
        #expect(ride.warnings.count == 1)
        let data = try ClipDates.encoder().encode(ride)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("brakeEvents")); #expect(!text.contains("latitude"))
    }
    @Test func choosesOnlyAnUnambiguousSync() throws {
        var ride = try Self.ride()
        #expect(ClipProject(ride: ride).videoStart == ride.syncs[0].timestamp)
        var second = ride.syncs[0]; second.id = "second"; ride.syncs.append(second)
        #expect(ClipProject(ride: ride).videoStart == nil)
        ride.syncs = []
        #expect(ClipProject(ride: ride).videoStart == nil)
    }
    @Test func legacyAndBuiltInSyncKindsRemainPrivateWorkflowMarkers() throws {
        for custom in [true, false] {
            for kind in ["Video Sync", "video-sync", "VIDEO_SYNC", "VideoSync"] {
                var raw = try #require(JSONSerialization.jsonObject(with: Data(Self.json.utf8)) as? [String: Any])
                raw["otherEvents"] = [["id":"sync", "kind":kind, "isCustom":custom, "timestamp":"2026-09-02T12:00:00Z"]]
                let ride = try ClipDates.decoder().decode(RideData.self, from: JSONSerialization.data(withJSONObject: raw))
                #expect(ride.syncs.map(\.id) == ["sync"])
                #expect(!ride.events.contains { $0.id == "sync" })
                let saved = ClipProject(ride: ride)
                let reopened = try ClipDates.decoder().decode(ClipProject.self, from: ClipDates.encoder().encode(saved))
                #expect(reopened.syncId == "sync")
                #expect(reopened.videoStart == ride.syncs.first?.timestamp)
            }
        }
    }
    @Test func crossesContiguousFilesAndClampsHandles() throws {
        let ride = try Self.ride(), sources = [Self.source(30), Self.source(50)]
        let plan = try ClipTimeline.resolve(ride.events[0], edit: ClipEdit(), videoStart: ride.startedAt, sources: sources)
        #expect(plan.available); #expect(plan.parts.count == 2)
        #expect(plan.parts.map(\.duration) == [15, 5]); #expect(plan.parts.map(\.offset) == [15, 0])
        let clamped = try ClipTimeline.resolve(ride.events[0], edit: ClipEdit(before: 40, after: 100), videoStart: ride.startedAt, sources: sources)
        #expect(clamped.available); #expect(clamped.isClamped); #expect(clamped.duration == 80)
    }
    @Test func gapsAndReportsOutsideFootageAreUnavailable() throws {
        let ride = try Self.ride()
        var second = Self.source(50); second.gapBefore = 10
        let sources = [Self.source(25), second]
        let gap = try ClipTimeline.resolve(ride.events[0], edit: ClipEdit(), videoStart: ride.startedAt, sources: sources)
        #expect(!gap.available)
        let spanning = try ClipTimeline.resolve(ride.events[1], edit: ClipEdit(before: 40), videoStart: ride.startedAt, sources: sources)
        #expect(!spanning.available); #expect(spanning.reason?.contains("gap") == true)
        let outside = try ClipTimeline.resolve(ride.events[2], edit: ClipEdit(), videoStart: ride.startedAt, sources: sources)
        #expect(!outside.available)
    }
    @Test func browserProjectRoundTripAndNativeBookmarks() throws {
        let ride = try Self.ride()
        let rawRide = try JSONSerialization.jsonObject(with: ClipDates.encoder().encode(ride))
        let raw: [String: Any] = ["format":"bumpyride-clip", "version":1, "ride":rawRide,
            "sources":[["name":"original.MOV","size":4001539139,"duration":996.5,"gapBefore":0]],
            "videoStart":"2026-09-02T12:00:00Z","syncId":"sync","offset":0,
            "edits":["close":["before":2,"after":3,"selected":true,"reviewed":true]]]
        var project = try ClipDates.decoder().decode(ClipProject.self, from: JSONSerialization.data(withJSONObject: raw))
        #expect(project.sources[0].size == 4001539139)
        #expect(project.edits["close"]?.before == 2)
        project.sources[0].bookmark = Data([1,2,3])
        let result = try ClipDates.decoder().decode(ClipProject.self, from: ClipDates.encoder().encode(project))
        #expect(result.sources[0].bookmark == Data([1,2,3])); #expect(result.sources[0].id == project.sources[0].id)
        #expect(result.edits == project.edits); #expect(result.videoStart == project.videoStart)
    }
    @Test func rejectsInvalidDatesAndHandles() throws {
        #expect(throws: (any Error).self) { try ClipDates.parse("2026-09-02T12:00:00") }
        #expect(throws: (any Error).self) { try ClipEdit(before: -1).validate() }
        #expect(throws: (any Error).self) { try ClipEdit(before: 0, after: 0).validate() }
        #expect(throws: (any Error).self) { try ClipEdit(before: .infinity).validate() }
        #expect(throws: (any Error).self) { try Self.source(-1).validate() }
    }
    @Test func relinkChecksOriginalIdentity() {
        let a = SourceRecord(name: "part.mov", size: 100, duration: 30, mtimeMs: 10000)
        var b = a
        #expect(a.matches(b))
        b.size += 1; #expect(!a.matches(b))
        b = a; b.duration += 1; #expect(!a.matches(b))
        b = a; b.mtimeMs = 13000; #expect(!a.matches(b))
    }
    @Test func defaultHandlesAndExistingEdits() throws {
        #expect(ClipEdit().before == 15); #expect(ClipEdit().after == 5)
        let defaults = try ClipDates.decoder().decode(ClipEdit.self, from: Data("{}".utf8))
        #expect(defaults.after == 5)
        let saved = try ClipDates.decoder().decode(ClipEdit.self, from: Data("{\"before\":15,\"after\":15}".utf8))
        #expect(saved.after == 15)
    }
    @Test func calibrationPreservesReferenceAndAlignsReports() throws {
        var project = ClipProject(ride: try Self.ride())
        let reference = try #require(project.videoStart)
        try project.calibrate(to: 0.3)
        #expect(abs(project.videoStart!.timeIntervalSince(reference) - 0.3) < 0.001)
        let eventOffset = project.ride.events[0].timestamp.timeIntervalSince(project.videoStart!)
        try project.calibrate(to: project.offset + eventOffset - 28.5)
        #expect(abs(project.ride.events[0].timestamp.timeIntervalSince(project.videoStart!) - 28.5) < 0.001)
        let restored = try ClipDates.decoder().decode(ClipProject.self, from: ClipDates.encoder().encode(project))
        #expect(abs(restored.offset - project.offset) < 0.001)
        try project.calibrate(to: 0)
        #expect(project.videoStart == reference)
        #expect(project.syncId == "sync")
        #expect(throws: (any Error).self) { try project.calibrate(to: .infinity) }
    }
    @Test func bulkTimingPreservesUnselectedEditsAndReviewState() throws {
        var project = ClipProject(ride: try Self.ride())
        project.edits = ["close":ClipEdit(before:1, after:2, selected:true, reviewed:true),
                        "blocked":ClipEdit(before:8, after:9, selected:true),
                        "custom":ClipEdit(before:3, after:4, reviewed:true)]
        try project.applyTimingToSelected(before:15, after:5)
        #expect(project.edits["close"] == ClipEdit(before:15, after:5, selected:true, reviewed:true))
        #expect(project.edits["blocked"] == ClipEdit(before:15, after:5, selected:true))
        #expect(project.edits["custom"] == ClipEdit(before:3, after:4, reviewed:true))
        let previous = project.edits
        #expect(throws: (any Error).self) { try project.applyTimingToSelected(before:0, after:0) }
        #expect(project.edits == previous)
    }

}
