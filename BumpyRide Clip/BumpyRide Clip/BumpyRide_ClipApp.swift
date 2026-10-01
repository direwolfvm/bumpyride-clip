import SwiftUI
import AppKit

@main
struct BumpyRide_ClipApp: App {
    @NSApplicationDelegateAdaptor(ClipAppDelegate.self) private var delegate
    @State private var workspace = ClipWorkspace()

    var body: some Scene {
        Window("BumpyRide Clip", id: "main") {
            ContentView(workspace: workspace)
                .onAppear { delegate.connect(workspace) }
        }
        .defaultSize(width: 1320, height: 850)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Choose Ride…") { workspace.openJSON() }.keyboardShortcut("o")
                    .disabled(workspace.busy)
                Button("Open Project or File…") { workspace.openJSON(projectOnly: true) }.keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(workspace.busy)
                Menu("Open Recent") {
                    ForEach(workspace.recentDocuments, id: \.self) { url in
                        Button(url.lastPathComponent) { workspace.openDocuments([url]) }
                    }
                    Divider()
                    Button("Clear Menu") { workspace.clearRecentDocuments() }
                }
                Button("Load Sample Project") { workspace.loadSampleProject() }.disabled(workspace.busy)
            }
            CommandGroup(after: .saveItem) {
                Button("Export Current Clip…") { workspace.export(reel: false) }
                    .keyboardShortcut("e").disabled(!workspace.canExportActive)
            }
        }
    }
}

@MainActor
final class ClipAppDelegate: NSObject, NSApplicationDelegate {
    var workspace: ClipWorkspace?
    private var pendingURLs: [URL] = []
    private var terminating = false
    func connect(_ workspace: ClipWorkspace) {
        self.workspace = workspace
        if pendingURLs.isEmpty { workspace.start() }
        else { workspace.openDocuments(pendingURLs); pendingURLs.removeAll() }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        if let workspace { workspace.openDocuments(urls) }
        else { pendingURLs.append(contentsOf: urls) }
    }
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        application(sender, open: [URL(fileURLWithPath: filename)])
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating, let workspace else { return .terminateNow }
        terminating = true
        Task {
            await workspace.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
