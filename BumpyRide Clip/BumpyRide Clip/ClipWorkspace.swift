import AppKit
import AVKit
import Observation
import UniformTypeIdentifiers

@MainActor @Observable
final class ClipWorkspace {
    var project: ClipProject?
    var selectedEventID: String? { didSet { if oldValue != selectedEventID { preparePreview() } } }
    var filter: EventFilter = .all
    var errorMessage: String?
    var status = "Open a BumpyRide JSON and link your original ride videos."
    var isImporting = false { didSet { if !isImporting { drainDocumentQueue() } } }
    var isPreparing = false
    var isExporting = false { didSet { if !isExporting { drainDocumentQueue() } } }
    var exportProgress: Double = 0
    var lastExport: URL?
    var showRideSelector = false
    var showSources = false
    var showSync = false
    var showInspector = true
    var player = AVPlayer()
    var showCalibration = false
    var previewSeconds: Double = 0
    @ObservationIgnored private var previewStart: Double = 0
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var media: [UUID: SourceMedia] = [:]
    @ObservationIgnored private var scopedURLs: [UUID: URL] = [:]
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var previewGeneration = UUID()
    @ObservationIgnored private var exportGeneration = UUID()
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var restoreTask: Task<Void, Never>?
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var pendingDocuments: [(url: URL, access: Bool)] = []
    @ObservationIgnored private var isShuttingDown = false
    @ObservationIgnored private var demoVideoURL: URL?
    static let projectType = UTType(exportedAs: "com.herbertindustries.bumpyride.clipproject", conformingTo: .json)
    var isDemo: Bool { project?.demoVersion != nil }
    var recentDocuments: [URL] = NSDocumentController.shared.recentDocumentURLs
    @ObservationIgnored private let autosaveURL: URL
    @ObservationIgnored private let scratchURL: URL

    enum EventFilter: String, CaseIterable, Identifiable {
        case all = "All reports", close = "Close calls", blocked = "Blocked lanes", custom = "Custom events", unreviewed = "Not reviewed"
        var id: Self { self }
    }
    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BumpyRideClip", isDirectory: true)
        autosaveURL = support.appendingPathComponent("autosave.bumpyclip.json")
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("BumpyRideClipRenders", isDirectory: true)
        scratchURL = cache.appendingPathComponent("\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            for directory in try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil) {
                let components = directory.lastPathComponent.split(separator: "-", maxSplits: 1)
                if components.count == 2, UUID(uuidString: String(components[1])) != nil,
                   let pid = Int32(components[0]), kill(pid, 0) == -1, errno == ESRCH {
                    try? FileManager.default.removeItem(at: directory)
                }
            }
            try FileManager.default.createDirectory(at: scratchURL, withIntermediateDirectories: true)
        } catch { errorMessage = error.localizedDescription }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, !self.isPreparing, self.player.currentItem != nil, time.seconds.isFinite else { return }
                self.previewSeconds = time.seconds
            }
        }
    }
    var events: [RideReport] { project?.ride.events ?? [] }
    var sources: [SourceRecord] { project?.sources ?? [] }
    var activeEvent: RideReport? { events.first { $0.id == selectedEventID } }
    var hasAllSources: Bool { !sources.isEmpty && sources.allSatisfy { media[$0.id] != nil } }
    var missingCount: Int { sources.filter { media[$0.id] == nil }.count }
    var busy: Bool { isImporting || isExporting }
    var timelineDuration: Double { (try? ClipTimeline.segments(sources).last?.end) ?? 0 }
    var reviewedCount: Int { events.filter { edit(for: $0.id).reviewed }.count }
    var selectedEvents: [RideReport] { events.filter { edit(for: $0.id).selected } }
    var visibleEvents: [RideReport] {
        events.filter { event in
            switch filter {
            case .all: true
            case .close: event.origin == .closeCall
            case .blocked: event.origin == .other && !event.isCustom && event.kind == "blocked-lane"
            case .custom: event.isCustom
            case .unreviewed: !edit(for: event.id).reviewed
            }
        }
    }
    func edit(for id: String) -> ClipEdit { project?.edits[id] ?? ClipEdit() }
    func isLinked(_ source: SourceRecord) -> Bool { media[source.id] != nil }
    func plan(for event: RideReport) -> ClipPlan? {
        guard let project, let start = project.videoStart else { return nil }
        return try? ClipTimeline.resolve(event, edit: edit(for: event.id), videoStart: start, sources: project.sources)
    }
    var activePlan: ClipPlan? { activeEvent.flatMap { plan(for: $0) } }
    var canExportActive: Bool { !busy && hasAllSources && activePlan?.available == true }
    var canExportReel: Bool { !busy && hasAllSources && !selectedEvents.isEmpty && selectedEvents.allSatisfy { plan(for: $0)?.available == true } }

    func start() {
        guard !didStart else { return }; didStart = true
        guard FileManager.default.fileExists(atPath: autosaveURL.path) else { return }
        isImporting = true
        restoreTask = Task {
            defer { isImporting = false }
            do {
                let data = try await Self.readJSON(autosaveURL)
                let saved = try ClipDates.decoder().decode(ClipProject.self, from: data)
                try await install(saved)
                status = "Restored your last project. \(sources.isEmpty ? "Link your ride videos to continue." : missingCount == 0 ? "Original videos are linked." : "Relink missing videos to continue.")"
            } catch { errorMessage = "Could not restore the last project. \(error.localizedDescription)" }
        }
    }
    // Finder/Dock/open-recent requests may arrive before the view or during import/export.
    func openDocuments(_ urls: [URL]) {
        didStart = true
        for url in urls {
            guard url.isFileURL, ["json", "bumpyclip"].contains(url.pathExtension.lowercased()) else {
                errorMessage = "Choose a BumpyRide ride JSON or .bumpyclip project."; continue
            }
            pendingDocuments.append((url, url.startAccessingSecurityScopedResource()))
        }
        drainDocumentQueue()
    }
    private func drainDocumentQueue() {
        guard !busy, !isShuttingDown, !pendingDocuments.isEmpty else { return }
        let next = pendingDocuments.removeFirst()
        loadJSON(next.url, existingAccess: next.access)
    }
    private func noteRecent(_ url: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        recentDocuments = NSDocumentController.shared.recentDocumentURLs
    }
    func clearRecentDocuments() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        recentDocuments = []
    }
    nonisolated private static func readJSON(_ url: URL) async throws -> Data {
        try await Task.detached { try RideCatalog.read(url) }.value
    }
    func openJSON(projectOnly: Bool = false) {
        guard !busy else { return }
        if !projectOnly { showRideSelector = true; return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.projectType, .json]; panel.allowsMultipleSelection = false
        panel.title = "Open a BumpyRide ride or project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadJSON(url)
    }
    func loadJSON(_ url: URL, existingAccess: Bool = false, directory: URL? = nil) {
        guard !busy else { return }
        let folderAccess = directory?.startAccessingSecurityScopedResource() ?? false
        isImporting = true
        importTask = Task {
            let access = existingAccess || url.startAccessingSecurityScopedResource()
            defer {
                if access { url.stopAccessingSecurityScopedResource() }
                if folderAccess { directory?.stopAccessingSecurityScopedResource() }
                isImporting = false
            }
            do {
                let data = try await Self.readJSON(url)
                try Task.checkCancellation()
                let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let next: ClipProject
                if root?["format"] != nil { next = try ClipDates.decoder().decode(ClipProject.self, from: data) }
                else { next = ClipProject(ride: try ClipDates.decoder().decode(RideData.self, from: data)) }
                guard confirmReplacingProject() else { return }
                try await install(next)
                noteRecent(url)
                status = next.ride.warnings.isEmpty ? "Loaded \(next.ride.events.count) reports. Hard brakes are excluded." : next.ride.warnings.joined(separator: " ")
            } catch { errorMessage = "Could not open \(url.lastPathComponent). \(error.localizedDescription)" }
        }
    }
    func loadSampleProject() {
        guard !busy, confirmReplacingProject() else { return }
        isImporting = true; status = "Generating a small sample video on this Mac…"
        importTask = Task {
            defer { isImporting = false }
            do {
                try await install(SampleProject.make())
                status = "Sample project: synthetic video generated locally. Your last real project’s autosave is preserved."
            } catch { errorMessage = error.localizedDescription }
        }
    }
    private func install(_ next: ClipProject) async throws {
        var sample: SourceMedia?
        var sampleURL: URL?
        if next.demoVersion != nil {
            let url = scratchURL.appendingPathComponent("sample-\(UUID().uuidString).mp4")
            do {
                try await SampleProject.generate(at: url)
                sample = try await SourceMedia.load(url); sampleURL = url
                try Task.checkCancellation()
            } catch { try? FileManager.default.removeItem(at: url); throw error }
        }
        clearPlayback(); releaseSources(); project = next; lastExport = nil; dirty = false
        if let sample {
            sample.record.id = next.sources.first?.id ?? sample.record.id
            // Stable display name; no security bookmark to an ephemeral generated file.
            sample.record.name = "Generated sample.mp4"
            project?.sources = [sample.record]; media[sample.record.id] = sample; demoVideoURL = sampleURL
        }
        for record in next.sources where next.demoVersion == nil {
            if Task.isCancelled { break }
            guard let bookmark = record.bookmark else { continue }
            var scoped: URL?
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
                if url.startAccessingSecurityScopedResource() { scoped = url }
                let loaded = try await SourceMedia.load(url)
                try Task.checkCancellation()
                guard record.matches(loaded.record) else { throw ClipError.message("Original video has changed.") }
                var refreshed = loaded.record; refreshed.id = record.id; refreshed.gapBefore = record.gapBefore
                refreshed.bookmark = try Self.bookmark(url)
                loaded.record = refreshed; media[record.id] = loaded; scopedURLs[record.id] = scoped
                if let index = project?.sources.firstIndex(where: { $0.id == record.id }) { project?.sources[index] = refreshed }
            } catch { scoped?.stopAccessingSecurityScopedResource() }
        }
        selectedEventID = next.ride.events.first?.id
        saveAutosave(); preparePreview()
    }
    private static func bookmark(_ url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    func addVideos() {
        guard project != nil, !busy, !isDemo else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.movie, .video]; panel.allowsMultipleSelection = true
        panel.title = missingCount > 0 ? "Relink the original videos" : "Link ride videos in recording order"
        panel.message = "Originals stay in place. Select one or more files; adjust their order in Manage Videos."
        guard panel.runModal() == .OK else { return }
        attach(panel.urls)
    }
    func attach(_ urls: [URL]) {
        guard project != nil, !busy, !isDemo else { return }
        isImporting = true; status = "Reading video metadata…"
        importTask = Task {
            defer { isImporting = false; saveAutosave(); preparePreview() }
            var failures: [String] = []
            let relinking = missingCount > 0
            for url in urls {
                if Task.isCancelled { break }
                if media.values.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) { continue }
                let scoped = url.startAccessingSecurityScopedResource()
                do {
                    let loaded = try await SourceMedia.load(url)
                try Task.checkCancellation()
                    loaded.record.bookmark = try Self.bookmark(url)
                    if relinking {
                        guard let index = project?.sources.firstIndex(where: { media[$0.id] == nil && $0.matches(loaded.record) }), let expected = project?.sources[index] else {
                            throw ClipError.message("Does not match a missing original (name, size, duration, modification time).")
                        }
                        loaded.record.id = expected.id; loaded.record.gapBefore = expected.gapBefore
                        project?.sources[index] = loaded.record
                    } else {
                        guard sources.count < 100 else { throw ClipError.message("A project supports up to 100 source files.") }
                        project?.sources.append(loaded.record)
                    }
                    media[loaded.record.id] = loaded
                    if scoped { scopedURLs[loaded.record.id] = url }
                } catch { if scoped { url.stopAccessingSecurityScopedResource() }; failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            dirty = true
            status = "\(sources.count - missingCount) videos linked in place. \(missingCount > 0 ? "\(missingCount) still need relinking." : "No copies created.")"
            if !failures.isEmpty { errorMessage = failures.joined(separator: "\n\n") }
        }
    }
    func moveSource(_ id: UUID, by delta: Int) {
        guard !busy, let index = project?.sources.firstIndex(where: { $0.id == id }), sources.indices.contains(index + delta) else { return }
        project?.sources.swapAt(index, index + delta); project?.sources[0].gapBefore = 0; changed()
    }
    func removeSource(_ id: UUID) {
        guard !busy else { return }
        clearPlayback(); project?.sources.removeAll { $0.id == id }; media.removeValue(forKey: id)
        scopedURLs.removeValue(forKey: id)?.stopAccessingSecurityScopedResource()
        if !sources.isEmpty { project?.sources[0].gapBefore = 0 }; changed()
    }
    func setGap(_ id: UUID, value: Double) {
        guard !busy, value.isFinite, value >= 0, let index = project?.sources.firstIndex(where: { $0.id == id }) else { return }
        project?.sources[index].gapBefore = index == 0 ? 0 : value; changed()
    }
    func setEdit(_ id: String, _ edit: ClipEdit) {
        guard !busy else { return }
        do { try edit.validate() } catch { errorMessage = error.localizedDescription; return }
        let old = self.edit(for: id); project?.edits[id] = edit
        dirty = true; saveAutosave()
        if old.before != edit.before || old.after != edit.after { preparePreview() }
    }
    func selectAll() {
        let eligible = visibleEvents.filter { plan(for: $0)?.available == true }
        let selected = eligible.allSatisfy { edit(for: $0.id).selected }
        for event in eligible { var value = edit(for: event.id); value.selected = !selected; project?.edits[event.id] = value }
        dirty = true; saveAutosave()
    }
    func setSync(id: String, manual: Date, adjustment: Double) {
        guard !busy, adjustment.isFinite else { return }
        let reference = project?.ride.syncs.first { $0.id == id }?.timestamp ?? manual
        project?.syncId = id; project?.offset = adjustment; project?.videoStart = reference.addingTimeInterval(adjustment)
        changed()
    }
    var canCalibrate: Bool { !busy && !isPreparing && player.currentItem != nil && activePlan?.available == true }
    var eventInPreview: Double { max(0, (activePlan?.eventOffset ?? 0) - (activePlan?.start ?? 0)) }
    var eventDelta: Double { previewSeconds - eventInPreview }
    func calibrate(to adjustment: Double) {
        guard canCalibrate else { return }
        let position = previewStart + player.currentTime().seconds
        do { try project?.calibrate(to: adjustment) }
        catch { errorMessage = error.localizedDescription; return }
        dirty = true; saveAutosave(); preparePreview(keepingRecordingTime: position)
        status = "Video sync calibrated for all reports in this ride."
    }
    func matchEventToFrame() {
        guard canCalibrate, let plan = activePlan else { return }
        let adjustment = (project?.offset ?? 0) + plan.eventOffset - (previewStart + player.currentTime().seconds)
        calibrate(to: (adjustment * 1000).rounded() / 1000)
    }
    func applyTimingToSelected() {
        guard !busy, let activeEvent, selectedEvents.count > 1 else { return }
        let handles = edit(for: activeEvent.id)
        do { try project?.applyTimingToSelected(before: handles.before, after: handles.after) }
        catch { errorMessage = error.localizedDescription; return }
        changed()
        status = "Applied \(handles.before)s before / \(handles.after)s after to \(selectedEvents.count) selected clips."
    }
    private func changed() { dirty = true; saveAutosave(); preparePreview() }
    private func clearPlayback() {
        previewGeneration = UUID(); previewTask?.cancel(); previewTask = nil
        player.pause(); player.replaceCurrentItem(with: nil); isPreparing = false; previewSeconds = 0
    }
    func preparePreview(keepingRecordingTime position: Double? = nil) {
        clearPlayback()
        guard hasAllSources, let plan = activePlan, plan.available else { return }
        let token = previewGeneration, linked = media
        previewStart = plan.start
        let seekSeconds = max(0, min(plan.duration - 0.001, (position ?? plan.start) - plan.start))
        previewSeconds = seekSeconds
        isPreparing = true
        previewTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(120))
                let composition = try await MediaEngine.compose(parts: plan.parts, sources: linked)
                try Task.checkCancellation()
                guard token == previewGeneration else { return }
                player.replaceCurrentItem(with: composition.playerItem())
                await player.seek(to: CMTime(seconds: seekSeconds, preferredTimescale: 60_000), toleranceBefore: .zero, toleranceAfter: .zero)
                guard token == previewGeneration else { return }
                previewSeconds = seekSeconds; isPreparing = false
            } catch is CancellationError { }
            catch { if token == previewGeneration { isPreparing = false; errorMessage = error.localizedDescription } }
        }
    }
    func playClip() { guard !isPreparing, player.currentItem != nil else { return }; player.seek(to: .zero); player.play() }
    func jumpToReport() {
        guard let plan = activePlan, plan.available else { return }
        player.pause(); player.seek(to: CMTime(seconds: plan.eventOffset - plan.start, preferredTimescale: 60_000), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func export(reel: Bool) {
        guard reel ? canExportReel : canExportActive else { return }
        let reports = reel ? selectedEvents : activeEvent.map { [$0] } ?? []
        let parts = reports.compactMap { plan(for: $0) }.flatMap(\.parts)
        let panel = NSSavePanel(); panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = reel ? "BumpyRide Reel.mp4" : "\(activeEvent?.label ?? "BumpyRide Clip").mp4"
        panel.title = reel ? "Export \(reports.count) clips in report order" : "Export clip"
        panel.message = "MP4 at the first clip’s video dimensions and frame rate. Originals are left untouched."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        guard !FileManager.default.fileExists(atPath: destination.path) else { errorMessage = "That file already exists. Choose a new export filename."; return }
        isExporting = true; exportProgress = 0; player.pause(); lastExport = nil
        status = "Exporting \(reports.count) \(reports.count == 1 ? "clip" : "clips")…"
        let token = UUID(); exportGeneration = token
        let temporary = scratchURL.appendingPathComponent("\(token.uuidString).mp4"), linked = media
        exportTask = Task {
            let access = destination.startAccessingSecurityScopedResource()
            defer { if access { destination.stopAccessingSecurityScopedResource() }; try? FileManager.default.removeItem(at: temporary); isExporting = false; exportTask = nil }
            do {
                let composition = try await MediaEngine.compose(parts: parts, sources: linked)
                try await MediaEngine.export(composition, to: temporary) { [weak self] value in
                    if self?.exportGeneration == token { self?.exportProgress = value }
                }
                try Task.checkCancellation()
                try FileManager.default.copyItem(at: temporary, to: destination)
                lastExport = destination; status = "Saved \(destination.lastPathComponent)."
            } catch is CancellationError { status = "Export cancelled. Temporary video removed." }
            catch { if Task.isCancelled { status = "Export cancelled." } else { errorMessage = error.localizedDescription; status = "Export failed." } }
        }
    }
    func cancelExport() { exportTask?.cancel() }
    func revealExport() { if let lastExport { NSWorkspace.shared.activateFileViewerSelecting([lastExport]) } }
    @discardableResult func saveProject() -> Bool {
        guard let project else { return false }
        let panel = NSSavePanel(); panel.allowedContentTypes = [Self.projectType]; panel.nameFieldStringValue = "\(project.ride.title.replacingOccurrences(of: "/", with: "-")).bumpyclip"
        panel.title = "Save BumpyRide Clip project"
        panel.message = isDemo ? "Saves sample edits only. The sample video is regenerated when reopened in the Mac app." : "Project files include ride/report times and file references that can reveal local file locations. Treat them as personal metadata when sharing. Videos stay in place."
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do { try ClipDates.encoder().encode(project).write(to: url, options: .atomic); noteRecent(url); dirty = false; status = "Project saved. No video files were copied."; return true }
        catch { errorMessage = error.localizedDescription; return false }
    }
    private func confirmReplacingProject() -> Bool {
        guard project != nil, dirty else { return true }
        let alert = NSAlert(); alert.messageText = "Save this project before continuing?"
        alert.informativeText = "Save your clip edits and file references to a project you can reopen later."
        alert.addButton(withTitle: "Save Project"); alert.addButton(withTitle: "Discard Edits"); alert.addButton(withTitle: "Cancel")
        switch alert.runModal() { case .alertFirstButtonReturn: return saveProject(); case .alertSecondButtonReturn: return true; default: return false }
    }
    func finish() {
        guard !busy, confirmReplacingProject() else { return }
        let wasDemo = isDemo
        clearPlayback(); releaseSources(); project = nil; selectedEventID = nil; lastExport = nil; dirty = false
        if !wasDemo { try? FileManager.default.removeItem(at: autosaveURL) }
        status = "Session finished. Original videos and saved exports are untouched."
    }
    private func releaseSources() {
        media.removeAll(); scopedURLs.values.forEach { $0.stopAccessingSecurityScopedResource() }; scopedURLs.removeAll()
        if let demoVideoURL { try? FileManager.default.removeItem(at: demoVideoURL) }; demoVideoURL = nil
    }
    private func saveAutosave() {
        guard let project, project.demoVersion == nil else { return }
        do { try ClipDates.encoder().encode(project).write(to: autosaveURL, options: .atomic) }
        catch { errorMessage = "Autosave failed. Save your project manually. \(error.localizedDescription)" }
    }
    func shutdown() async {
        isShuttingDown = true
        for document in pendingDocuments where document.access { document.url.stopAccessingSecurityScopedResource() }
        pendingDocuments.removeAll()
        restoreTask?.cancel(); await restoreTask?.value
        importTask?.cancel(); await importTask?.value
        saveAutosave(); previewTask?.cancel(); await previewTask?.value
        exportTask?.cancel(); await exportTask?.value
        if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
        clearPlayback(); releaseSources(); try? FileManager.default.removeItem(at: scratchURL)
    }
}
