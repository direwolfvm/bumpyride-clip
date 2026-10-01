import SwiftUI
import AppKit

@MainActor @Observable
final class RideLibrary {
    var entries: [RideCatalogEntry] = []
    var directory: URL?
    var loading = false
    var error: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    private static let bookmarkKey = "ride-library-folder"

    static var defaultDirectory: URL {
        // Foundation’s home directory resolves to the sandbox container.
        let home = getpwuid(getuid()).map { URL(fileURLWithPath: String(cString: $0.pointee.pw_dir), isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Mobile Documents/iCloud~com~herbertindustries~BumpyRide/Documents/Rides")
    }
    func start() {
        if let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) {
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                                  relativeTo: nil, bookmarkDataIsStale: &stale)
                scan(url, remember: stale)
                return
            } catch { /* A moved or unavailable folder can be selected again. */ }
        }
        scan(Self.defaultDirectory)
    }
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose your BumpyRide rides folder"
        panel.message = "Choose the Rides folder in BumpyRide’s iCloud Documents, or a folder of downloaded ride JSON files."
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.directoryURL = directory ?? Self.defaultDirectory
        panel.prompt = "Use Rides Folder"
        if panel.runModal() == .OK, let url = panel.url { scan(url, remember: true) }
    }
    func scan(_ url: URL, remember: Bool = false) {
        task?.cancel(); generation = UUID()
        let token = generation
        directory = url; loading = true; error = nil; entries = []
        // Each scan owns its scope until the background reader actually completes,
        // even if its sheet closes or a different folder is selected meanwhile.
        let access = url.startAccessingSecurityScopedResource()
        if remember {
            do {
                let data = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
                UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
            } catch { self.error = "This folder can be read now, but you may need to choose it again next time." }
        }
        task = Task {
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let reader = Task.detached { try RideCatalog.scan(url) }
            do {
                let result = try await withTaskCancellationHandler { try await reader.value } onCancel: { reader.cancel() }
                guard !Task.isCancelled, generation == token else { return }
                entries = result; loading = false
            } catch {
                guard !Task.isCancelled, generation == token else { return }
                self.error = "Choose your rides folder to grant access. Cloud-only rides may need downloading in Finder first."
                loading = false
            }
        }
    }
    func stop() { task?.cancel(); generation = UUID() }

    // Resolve the saved folder again so the import can hold access after the sheet closes.
    func accessibleDirectory() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return directory }
        var stale = false
        let resolved = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        return resolved?.standardizedFileURL == directory?.standardizedFileURL ? resolved : directory
    }
}

struct RideSelector: View {
    @Bindable var workspace: ClipWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var library = RideLibrary()
    @State private var query = ""
    @State private var onlyReports = false
    @State private var selection: URL?
    private var visible: [RideCatalogEntry] {
        library.entries.filter { $0.matches(query) && (!onlyReports || $0.reports > 0) }
    }
    private var selected: RideCatalogEntry? { visible.first { $0.url == selection && $0.issue == nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Choose a ride", systemImage: "bicycle").font(.title2.bold())
                Spacer()
                Button("Choose Folder…") { selection = nil; library.chooseFolder() }
                Button("Refresh", systemImage: "arrow.clockwise") {
                    selection = nil
                    if let url = library.accessibleDirectory() { library.scan(url) }
                }.disabled(library.loading || library.directory == nil)
            }
            Text(library.directory?.path ?? "Choose your BumpyRide rides folder")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            HStack {
                TextField("Search ride title or filename", text: $query).textFieldStyle(.roundedBorder)
                Toggle("With reports", isOn: $onlyReports).toggleStyle(.checkbox)
            }
            if let error = library.error { Text(error).foregroundStyle(.secondary).font(.callout) }
            if library.loading {
                ProgressView("Reading ride details…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visible.isEmpty {
                ContentUnavailableView("No rides found", systemImage: "bicycle",
                    description: Text(library.entries.isEmpty ? "Choose a folder containing BumpyRide ride JSON files, or open one file below." : "Try another search or turn off With reports."))
            } else {
                List(selection: $selection) {
                    ForEach(visible) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(entry.title.isEmpty ? "Untitled ride" : entry.title).font(.headline)
                                if entry.isProject { Text("Saved project").font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                                if let date = entry.startedAt { Text(date, format: .dateTime.month(.abbreviated).day().year().hour().minute()).foregroundStyle(.secondary) }
                            }
                            if let issue = entry.issue {
                                Label(issue, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
                            } else {
                                HStack(spacing: 18) {
                                    Label(ClipDates.timecode(entry.duration), systemImage: "clock")
                                    Label("\(entry.reports) reports", systemImage: "flag")
                                    Label(entry.syncs == 0 ? "No video sync" : "\(entry.syncs) video sync", systemImage: "video")
                                }.font(.callout).foregroundStyle(.secondary)
                            }
                            Text(entry.url.lastPathComponent).font(.caption2).foregroundStyle(.tertiary)
                        }.padding(.vertical, 7).tag(entry.url)
                    }
                }.listStyle(.bordered)
                Text("Newest rides first · Dates come from the ride, not the file · Hard brakes excluded")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Open a File…") { dismiss(); workspace.openJSON(projectOnly: true) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open Ride") { openSelected() }.keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).disabled(selected == nil || library.loading || workspace.busy)
            }
        }.padding(24).frame(width: 800, height: 580)
            .task { library.start() }.onDisappear { library.stop() }
    }
    private func openSelected() {
        guard let selected else { return }
        workspace.loadJSON(selected.url, directory: library.accessibleDirectory())
        dismiss()
    }
}
