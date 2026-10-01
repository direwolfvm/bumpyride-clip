import Foundation
import Testing
@testable import ClipCore

struct RideCatalogTests {
    @Test func catalogUsesRideDatesAndCountsAndSupportsSavedProjects() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldURL = directory.appendingPathComponent("recently-modified.json")
        try Data(ClipCoreTests.json.utf8).write(to: oldURL)
        var newer = try ClipCoreTests.ride()
        newer.title = "Evening commute"
        newer.startedAt = newer.startedAt.addingTimeInterval(86400)
        newer.endedAt = newer.endedAt.addingTimeInterval(86400)
        let projectURL = directory.appendingPathComponent("saved.bumpyclip")
        try ClipDates.encoder().encode(ClipProject(ride: newer)).write(to: projectURL)
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: projectURL.path)
        try Data("{}".utf8).write(to: directory.appendingPathComponent("invalid.json"))
        try Data().write(to: directory.appendingPathComponent("ignore.mov"))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("folder.json"), withIntermediateDirectories: true)
        let entries = try RideCatalog.scan(directory)
        #expect(entries.count == 3)
        #expect(entries[0].title == "Evening commute")
        #expect(entries[0].isProject)
        #expect(entries[1].duration == 3600)
        #expect(entries[1].reports == 3) // Sync and hard brake are not review reports.
        #expect(entries[1].syncs == 1)
        #expect(entries[2].issue != nil)
        #expect(entries[0].matches("COMMUTE"))
        #expect(entries[0].matches("saved"))
        #expect(!entries[0].matches("morning"))
        #expect(entries[0].matches("  "))
    }
    @Test func noReportsAndNoSyncAreValidRides() throws {
        var ride = try ClipCoreTests.ride(); ride.events = []; ride.syncs = []
        let entry = try RideCatalogEntry(url: URL(fileURLWithPath: "/empty.json"), data: ClipDates.encoder().encode(ride))
        #expect(entry.reports == 0); #expect(entry.syncs == 0); #expect(entry.issue == nil)
    }
}
