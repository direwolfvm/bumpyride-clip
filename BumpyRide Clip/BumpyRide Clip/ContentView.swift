import SwiftUI
import AVKit

struct ContentView: View {
    @Bindable var workspace: ClipWorkspace

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 235, ideal: 275, max: 340)
            } detail: {
                if workspace.project == nil { welcome }
                else { review }
            }
            .inspector(isPresented: Binding(get: { workspace.project != nil && workspace.showInspector }, set: { workspace.showInspector = $0 })) {
                if let event = workspace.activeEvent {
                    ClipInspector(workspace: workspace, event: event)
                        .inspectorColumnWidth(min: 230, ideal: 260, max: 310)
                } else {
                    ContentUnavailableView("Select a report", systemImage: "slider.horizontal.3")
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Menu {
                        Button("Open Ride…", systemImage: "bicycle") { workspace.openJSON() }.keyboardShortcut("o")
                        Button("Open Project…", systemImage: "folder") { workspace.openJSON(projectOnly: true) }.keyboardShortcut("o", modifiers: [.command, .shift])
                    } label: { Label("Open", systemImage: "folder") }
                    .disabled(workspace.busy)
                }
                ToolbarItemGroup {
                    Button("Link Videos", systemImage: "video.badge.plus") { workspace.addVideos() }
                        .disabled(workspace.project == nil || workspace.busy || workspace.isDemo)
                    Button("Manage Videos", systemImage: "film.stack") { workspace.showSources = true }
                        .disabled(workspace.project == nil || workspace.busy || workspace.isDemo)
                    Button("Video Sync", systemImage: "clock.arrow.2.circlepath") { workspace.showSync = true }
                        .disabled(workspace.project == nil || workspace.busy)
                    Button("Save Project", systemImage: "square.and.arrow.down") { workspace.saveProject() }
                        .keyboardShortcut("s").disabled(workspace.project == nil || workspace.busy)
                    Button("Clip Inspector", systemImage: "sidebar.right") { workspace.showInspector.toggle() }
                    Menu {
                        Button("Load Sample Project") { workspace.loadSampleProject() }.disabled(workspace.busy)
                        Button("Finish Project…") { workspace.finish() }.disabled(workspace.project == nil || workspace.busy)
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            statusBar
        }
        .sheet(isPresented: $workspace.showRideSelector) { RideSelector(workspace: workspace) }
        .sheet(isPresented: $workspace.showSources) { SourcesSheet(workspace: workspace) }
        .sheet(isPresented: $workspace.showSync) { SyncSheet(workspace: workspace) }
        .alert("BumpyRide Clip", isPresented: Binding(get: { workspace.errorMessage != nil }, set: { if !$0 { workspace.errorMessage = nil } })) {
            Button("OK") { workspace.errorMessage = nil }
        } message: { Text(workspace.errorMessage ?? "") }
        .frame(minWidth: 1000, minHeight: 680)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "bicycle").font(.title2).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("BumpyRide Clip").font(.headline)
                    Text("A BumpyRide companion").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.padding(16)
            Divider()
            if workspace.project != nil {
                Picker("Reports", selection: $workspace.filter) {
                    ForEach(ClipWorkspace.EventFilter.allCases) { Text($0.rawValue).tag($0) }
                }.labelsHidden().padding(12)
                HStack {
                    Text("\(workspace.reviewedCount) of \(workspace.events.count) reviewed")
                    Spacer()
                    Button("Select all") { workspace.selectAll() }.buttonStyle(.plain).foregroundStyle(.tint).disabled(workspace.busy)
                }.font(.caption).padding(.horizontal, 16).padding(.bottom, 8)
                List(selection: $workspace.selectedEventID) {
                    ForEach(workspace.visibleEvents) { event in
                        HStack(alignment: .top, spacing: 10) {
                            Toggle("Include \(event.label) in reel", isOn: editBinding(event.id, \.selected))
                                .labelsHidden().toggleStyle(.checkbox).padding(.top, 3).disabled(workspace.busy)
                            Image(systemName: event.symbol).foregroundStyle(event.color).frame(width: 18).padding(.top, 3)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(event.label).font(.system(.body, weight: .medium)).lineLimit(2)
                                HStack {
                                    Text(event.timestamp, style: .time)
                                    Spacer()
                                    if workspace.edit(for: event.id).reviewed { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                                    else if workspace.plan(for: event)?.available == false { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
                                }.font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 7).tag(event.id)
                    }
                }.listStyle(.sidebar)
                if workspace.visibleEvents.isEmpty { Text("No reports in this view").foregroundStyle(.secondary).padding() }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Ride reel", systemImage: "film.stack").font(.headline)
                        Spacer()
                        Text("\(workspace.selectedEvents.count) selected").foregroundStyle(.secondary).font(.caption)
                    }
                    Button { workspace.export(reel: true) } label: { Label("Export Selected Clips…", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).disabled(!workspace.canExportReel)
                    Text("Clips are combined in report order.").font(.caption).foregroundStyle(.secondary)
                }.padding(16)
            } else { Spacer() }
        }
    }

    private var welcome: some View {
        VStack(spacing: 25) {
            ZStack {
                RoundedRectangle(cornerRadius: 30).fill(Color(red: 0.065, green: 0.14, blue: 0.23))
                VStack(spacing: 12) {
                    Image(systemName: "film.stack").font(.system(size: 42, weight: .light)).foregroundStyle(Color(red: 0.3, green: 0.89, blue: 0.64))
                    Image(systemName: "waveform.path").font(.system(size: 22, weight: .medium)).foregroundStyle(.white)
                }
            }.frame(width: 110, height: 110)
            VStack(spacing: 10) {
                Text("Ride clips").font(.system(size: 27, weight: .semibold))
                Text("Review video for the things you track in BumpyRide.\nTrim clips, save them, or put a few together.")
                    .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            HStack(spacing: 12) {
                Button("Choose Ride…", systemImage: "bicycle") { workspace.openJSON() }.buttonStyle(.borderedProminent)
                Button("Open Project…", systemImage: "folder") { workspace.openJSON(projectOnly: true) }
            }.controlSize(.large).disabled(workspace.busy)
            Button("Try a sample project") { workspace.loadSampleProject() }.disabled(workspace.busy)
            Text("A short synthetic video is generated locally. No download or ride footage needed.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 28) {
                Label("Link original videos", systemImage: "link")
                Label("Sync by ride marker", systemImage: "clock")
                Label("Save only your clips", systemImage: "scissors")
            }.font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
    }

    private var review: some View {
        GeometryReader { geometry in
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                Text(workspace.project?.ride.title ?? "Ride").font(.title2.bold())
                HStack(spacing: 16) {
                    if let date = workspace.project?.ride.startedAt { Text(date, format: .dateTime.month(.wide).day().year()) }
                    Label("\(workspace.events.count) reports", systemImage: "flag")
                    Label("\(workspace.sources.count) videos", systemImage: "film")
                }.font(.callout).foregroundStyle(.secondary)
            }
            if workspace.sources.isEmpty {
                setupNotice("Link the videos from this ride", detail: "Add your original files in recording order. They stay in their current location.", action: "Link Videos…") { workspace.addVideos() }
            } else if workspace.missingCount > 0 {
                setupNotice("\(workspace.missingCount) videos need relinking", detail: "Choose the original files to restore playback and export.", action: "Relink Videos…") { workspace.addVideos() }
            }
            if workspace.project?.videoStart == nil {
                setupNotice("Set the first video’s start time", detail: "Choose a Video Sync marker or enter the actual recording start. Camera timestamps are ignored.", action: "Set Video Sync…") { workspace.showSync = true }
            }
            if let event = workspace.activeEvent {
                HStack {
                    Label(event.label, systemImage: event.symbol).font(.headline).foregroundStyle(event.color)
                    Spacer()
                    Text(event.timestamp, format: .dateTime.hour().minute().second()).monospacedDigit().foregroundStyle(.secondary)
                }
                GeometryReader { videoGeometry in
                ZStack {
                    Color.black
                    if workspace.player.currentItem != nil { NativePlayerView(player: workspace.player) }
                    else if workspace.isPreparing { ProgressView("Preparing clip…").tint(.white).foregroundStyle(.white) }
                    else {
                        VStack(spacing: 12) {
                            Image(systemName: "play.rectangle").font(.system(size: 40))
                            Text(workspace.activePlan?.reason ?? (workspace.hasAllSources ? "Set video sync to preview this report." : "Link your videos to preview this report."))
                                .multilineTextAlignment(.center).frame(maxWidth: 440)
                        }.foregroundStyle(.white.opacity(0.7)).padding()
                    }
                }.frame(width: videoGeometry.size.width, height: videoGeometry.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }.frame(height: max(150, geometry.size.height - (workspace.showCalibration ? 550 : 405)))
                if workspace.activePlan?.available == true { PreviewEventCue(workspace: workspace) }
                HStack {
                    Button("Play Clip", systemImage: "play.fill") { workspace.playClip() }
                    Button("Jump to Report", systemImage: "flag") { workspace.jumpToReport() }
                    Spacer()
                    if let plan = workspace.activePlan, plan.available {
                        Text("\(ClipDates.timecode(plan.duration)) • \(plan.parts.count) \(plan.parts.count == 1 ? "source" : "sources")")
                            .monospacedDigit().font(.callout).foregroundStyle(.secondary)
                    }
                }.disabled(workspace.player.currentItem == nil || workspace.isPreparing)
                DisclosureGroup("Calibrate video sync", isExpanded: $workspace.showCalibration) {
                    CalibrationControls(workspace: workspace)
                }.disabled(workspace.project?.videoStart == nil)
                if workspace.activePlan?.isClamped == true {
                    Label("Clip shortened at the beginning or end of available footage.", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                        .font(.caption).foregroundStyle(.orange)
                }
            } else {
                ContentUnavailableView("No report selected", systemImage: "flag", description: Text("Choose a report from the sidebar to review its clip."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if !workspace.sources.isEmpty { RecordingTimeline(workspace: workspace).frame(height: 58) }
        }.padding(24)
        }
        }
    }

    private func setupNotice(_ title: String, detail: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "info.circle.fill").foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 3) { Text(title).fontWeight(.medium); Text(detail).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button(action, action: perform).disabled(workspace.busy)
        }.padding(12).background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
    private var statusBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                if workspace.isImporting { ProgressView().controlSize(.small) }
                else { Image(systemName: "internaldrive").foregroundStyle(.secondary) }
                Text(workspace.status).font(.caption).lineLimit(2)
                Spacer()
                if workspace.isExporting {
                    ProgressView(value: workspace.exportProgress).frame(width: 120)
                    Text(workspace.exportProgress, format: .percent.precision(.fractionLength(0))).font(.caption).monospacedDigit()
                    Button("Cancel") { workspace.cancelExport() }
                } else if workspace.lastExport != nil {
                    Button("Show in Finder", systemImage: "folder") { workspace.revealExport() }
                }
            }.padding(.horizontal, 16).padding(.vertical, 9)
        }.background(.bar)
    }
    private func editBinding(_ id: String, _ key: WritableKeyPath<ClipEdit, Bool>) -> Binding<Bool> {
        Binding(get: { workspace.edit(for: id)[keyPath: key] }, set: { value in var edit = workspace.edit(for: id); edit[keyPath: key] = value; workspace.setEdit(id, edit) })
    }
}

extension RideReport {
    var color: Color { origin == .closeCall ? .orange : isCustom ? .purple : .blue }
}

private struct ClipInspector: View {
    @Bindable var workspace: ClipWorkspace
    let event: RideReport
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Label("Clip details", systemImage: "scissors").font(.title3.bold())
                VStack(alignment: .leading, spacing: 8) {
                    Text(event.label).font(.headline)
                    Text(event.timestamp, format: .dateTime.hour().minute().second()).foregroundStyle(.secondary)
                    if let category = event.category { Text(category.capitalized).font(.caption).foregroundStyle(.secondary) }
                }
                Divider()
                VStack(alignment: .leading, spacing: 18) {
                    Text("TRIM & EXTEND").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    handle("Before report", key: \.before)
                    handle("After report", key: \.after)
                    Button("Reset to 15s before / 5s after") {
                        var edit = workspace.edit(for: event.id); edit.before = 15; edit.after = 5; workspace.setEdit(event.id, edit)
                    }.font(.caption)
                    Text("Adjust either side in seconds. The report stays anchored to its ride timestamp.").font(.caption).foregroundStyle(.secondary)
                }
                if workspace.selectedEvents.count > 1 {
                    Button("Apply timing to \(workspace.selectedEvents.count) selected clips") { workspace.applyTimingToSelected() }
                        .frame(maxWidth: .infinity)
                    Text("Copies these before/after values to every checked clip, including those outside the current filter. Review status stays unchanged.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let plan = workspace.activePlan, plan.available {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Duration", value: ClipDates.timecode(plan.duration))
                        LabeledContent("Recording in", value: ClipDates.timecode(plan.start))
                        LabeledContent("Recording out", value: ClipDates.timecode(plan.end))
                    }.font(.callout).monospacedDigit()
                }
                Divider()
                Toggle("Reviewed", isOn: flag(\.reviewed))
                Toggle("Include in ride reel", isOn: flag(\.selected))
                Button { workspace.export(reel: false) } label: {
                    Label("Export Clip…", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!workspace.canExportActive)
                Text("Exported clips are saved where you choose. Project files contain metadata only.").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }.padding(20).disabled(workspace.busy)
        }
    }
    private func handle(_ label: String, key: WritableKeyPath<ClipEdit, Double>) -> some View {
        let binding = Binding<Double>(get: { workspace.edit(for: event.id)[keyPath: key] }, set: { value in
            var edit = workspace.edit(for: event.id); edit[keyPath: key] = value; workspace.setEdit(event.id, edit)
        })
        return VStack(alignment: .leading, spacing: 8) {
            Text(label).fontWeight(.medium)
            HStack {
                TextField(label, value: binding, format: .number.precision(.fractionLength(0...2))).textFieldStyle(.roundedBorder).labelsHidden()
                Text("sec").foregroundStyle(.secondary)
                Stepper(label, value: binding, in: 0...86400, step: 1).labelsHidden()
            }
            Slider(value: binding, in: 0...max(60, binding.wrappedValue), step: 0.5).accessibilityLabel(label)
        }
    }
    private func flag(_ key: WritableKeyPath<ClipEdit, Bool>) -> Binding<Bool> {
        Binding(get: { workspace.edit(for: event.id)[keyPath: key] }, set: { value in var edit = workspace.edit(for: event.id); edit[keyPath: key] = value; workspace.setEdit(event.id, edit) })
    }
}

private struct RecordingTimeline: View {
    var workspace: ClipWorkspace
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("RECORDING").font(.caption2.weight(.semibold))
                Spacer()
                if let start = workspace.project?.videoStart { Text("Starts \(start.formatted(.dateTime.hour().minute().second()))") }
                Text(ClipDates.timecode(workspace.timelineDuration)).monospacedDigit()
            }.font(.caption).foregroundStyle(.secondary)
            GeometryReader { geometry in
                let total = max(1, workspace.timelineDuration)
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    ForEach(Array(((try? ClipTimeline.segments(workspace.sources)) ?? []).enumerated()), id: \.element.source.id) { index, segment in
                        RoundedRectangle(cornerRadius: 4).fill(index.isMultiple(of: 2) ? Color.green.opacity(0.3) : Color.blue.opacity(0.25))
                            .frame(width: max(1, geometry.size.width * segment.source.duration / total))
                            .offset(x: geometry.size.width * segment.start / total)
                            .help(segment.source.name)
                    }
                    if let plan = workspace.activePlan, plan.available {
                        RoundedRectangle(cornerRadius: 3).fill(.green)
                            .frame(width: max(3, geometry.size.width * (plan.end - plan.start) / total))
                            .offset(x: geometry.size.width * plan.start / total)
                        Rectangle().fill(.primary).frame(width: 2).offset(x: geometry.size.width * plan.eventOffset / total)
                    }
                }
            }.frame(height: 18)
            Text("Green marks the current clip; the line marks the report.").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct SourcesSheet: View {
    @Bindable var workspace: ClipWorkspace
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Ride videos").font(.title2.bold())
            Text("Put files in recording order. Add a gap only when the camera stopped between files; split files normally have no gap.").foregroundStyle(.secondary)
            List {
                ForEach(Array(workspace.sources.enumerated()), id: \.element.id) { index, source in
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(spacing: 10) {
                            Text("\(index + 1)").font(.headline).foregroundStyle(.secondary).frame(width: 20)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(source.name).fontWeight(.medium)
                                Text("\(ClipDates.timecode(source.duration)) • \(ByteCountFormatter.string(fromByteCount: source.size, countStyle: .file)) • \(workspace.isLinked(source) ? "Linked" : "Needs relinking")")
                                    .font(.caption).foregroundStyle(workspace.isLinked(source) ? Color.secondary : .orange)
                            }
                            Spacer()
                            Button("Move earlier", systemImage: "arrow.up") { workspace.moveSource(source.id, by: -1) }.labelStyle(.iconOnly).disabled(index == 0)
                            Button("Move later", systemImage: "arrow.down") { workspace.moveSource(source.id, by: 1) }.labelStyle(.iconOnly).disabled(index == workspace.sources.count - 1)
                            Button("Unlink video", systemImage: "minus.circle") { workspace.removeSource(source.id) }.labelStyle(.iconOnly)
                        }
                        if index > 0 {
                            HStack {
                                Text("Gap before this file").font(.caption)
                                TextField("Gap in seconds", value: Binding(get: { source.gapBefore }, set: { workspace.setGap(source.id, value: $0) }), format: .number)
                                    .frame(width: 90).textFieldStyle(.roundedBorder)
                                Text("seconds").font(.caption).foregroundStyle(.secondary)
                            }.padding(.leading, 30)
                        }
                    }.padding(.vertical, 7)
                }
            }.frame(minHeight: 160, maxHeight: 330).disabled(workspace.busy)
            Text("Videos are referenced in place and never copied into the project. Unlinking a file does not delete it.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(workspace.missingCount > 0 ? "Relink Missing Videos…" : "Link Videos…", systemImage: "plus") { workspace.addVideos() }.disabled(workspace.busy)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 650)
    }
}

private struct SyncSheet: View {
    @Bindable var workspace: ClipWorkspace
    @Environment(\.dismiss) var dismiss
    @State private var marker = ""
    @State private var manual = Date()
    @State private var adjustment: Double = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Video sync", systemImage: "clock.arrow.2.circlepath").font(.title2.bold())
            Text("Set the real-world time of the first frame in the first video. Camera metadata is never used for alignment.").foregroundStyle(.secondary)
            Form {
                Picker("Start reference", selection: $marker) {
                    Text("Enter time manually").tag("")
                    ForEach(workspace.project?.ride.syncs ?? []) { sync in
                        Text("Video Sync • \(sync.timestamp.formatted(.dateTime.hour().minute().second()))").tag(sync.id)
                    }
                }
                if marker.isEmpty {
                    DatePicker("Recording start", selection: $manual, displayedComponents: [.date, .hourAndMinute])
                    TextField("Exact start (including seconds)", value: $manual, format: .dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute().second())
                        .textFieldStyle(.roundedBorder)
                }
                TextField("Fine adjustment (seconds)", value: $adjustment, format: .number).textFieldStyle(.roundedBorder)
            }
            Text("Positive adjustment moves the recording start later. Times are shown in \(TimeZone.current.identifier).").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply Sync") { workspace.setSync(id: marker, manual: manual, adjustment: adjustment); dismiss() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!adjustment.isFinite)
            }
        }.padding(24).frame(width: 540)
        .onAppear {
            marker = workspace.project?.syncId ?? ""; adjustment = workspace.project?.offset ?? 0
            manual = workspace.project?.videoStart?.addingTimeInterval(-adjustment) ?? workspace.project?.ride.startedAt ?? Date()
        }
    }
}

/// Use AVKit directly for native transport controls and reliable framework linking.
private struct NativePlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.videoGravity = .resizeAspect
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}


private struct PreviewEventCue: View {
    var workspace: ClipWorkspace
    var body: some View {
        let duration = max(0.001, workspace.activePlan?.duration ?? 1)
        let atEvent = abs(workspace.eventDelta) <= 0.15
        VStack(spacing: 8) {
            HStack {
                Label("Event at \(workspace.eventInPreview, specifier: "%.1f")s in clip", systemImage: "flag.fill")
                Spacer()
                Text(atEvent ? "EVENT RECORDED" : String(format: "%.1fs %@ event", abs(workspace.eventDelta), workspace.eventDelta < 0 ? "before" : "after"))
                    .fontWeight(.semibold)
            }.font(.caption).monospacedDigit()
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary).frame(height: 7)
                    Rectangle().fill(.orange).frame(width: 4, height: 17)
                        .offset(x: max(0, min(geometry.size.width - 4, geometry.size.width * workspace.eventInPreview / duration)))
                    Rectangle().fill(.primary).frame(width: 2, height: 11)
                        .offset(x: max(0, min(geometry.size.width - 2, geometry.size.width * workspace.previewSeconds / duration)))
                }.frame(height: 17)
            }.frame(height: 17).accessibilityLabel("Orange marker: recorded event. Thin line: playback position.")
        }.padding(10).background(atEvent ? Color.orange.opacity(0.2) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct CalibrationControls: View {
    @Bindable var workspace: ClipWorkspace
    @State private var correction: Double = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Applies to all reports in this ride. Pause at the matching moment, then align the event to that frame.")
                .font(.caption).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack { nudgeButtons; matchButton }
                VStack(alignment: .leading) { HStack { nudgeButtons }; matchButton }
            }
            HStack {
                Text("Start correction")
                TextField("Start correction in seconds", value: $correction, format: .number.precision(.fractionLength(0...3)))
                    .textFieldStyle(.roundedBorder).frame(width: 85)
                Text("sec").foregroundStyle(.secondary)
                Button("Apply") { workspace.calibrate(to: correction) }.disabled(!correction.isFinite)
                Button("Reset correction") { workspace.calibrate(to: 0) }
            }.font(.callout)
            Text("Positive correction = video started later than the sync reference. Orange line = event; thin line = playback.")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(.top, 8).disabled(!workspace.canCalibrate)
            .onAppear { correction = workspace.project?.offset ?? 0 }
            .onChange(of: workspace.project?.offset) { _, value in correction = value ?? 0 }
            .onSubmit { workspace.calibrate(to: correction) }
    }
    private var nudgeButtons: some View {
        Group {
            Button("Event 0.1s earlier") { workspace.calibrate(to: ((workspace.project?.offset ?? 0) * 1000 + 100).rounded() / 1000) }
            Button("Event 0.1s later") { workspace.calibrate(to: ((workspace.project?.offset ?? 0) * 1000 - 100).rounded() / 1000) }
        }
    }
    private var matchButton: some View {
        Button("Match event to this frame", systemImage: "scope") { workspace.matchEventToFrame() }
    }
}
