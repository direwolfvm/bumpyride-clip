import {
  parseRide,
  segmentsFor,
  resolveClip,
  formatTime,
  timestamp,
  validateProject,
  rideForProject,
  calibratedStart,
  applySelectedTiming,
  eventCue,
} from "./domain.js";

const $ = (id) => document.getElementById(id);
const escape = (value) =>
  String(value ?? "").replace(
    /[&<>"']/g,
    (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        c
      ],
  );
const humanSize = (bytes) => `${(bytes / 1024 ** 3).toFixed(2)} GB`;
const clockTime = (value) =>
  new Date(value).toLocaleTimeString([], {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
const dateTime = (value) =>
  new Date(value).toLocaleString([], {
    dateStyle: "medium",
    timeStyle: "short",
  });
const kindClass = (event) => (event.isCustom ? "custom" : event.kind);
const STORAGE_KEY = "bumpyride-clip-project-v1";
let session,
  ride = null,
  sources = [],
  pendingSources = [],
  edits = Object.create(null),
  videoStart = "",
  syncId = "",
  offset = 0,
  activeId = "",
  filter = "all";
let currentSourceId = "",
  previewJobId = "",
  previewKey = "",
  activeJobId = "",
  playbackMode = "source",
  isPlayingClip = false,
  loadingVideo = false,
  noticeTimer;
let isDirty = false,
  busy = false,
  playbackGeneration = 0;
const video = $("video");
const editFor = (id) =>
  (edits[id] ||= { before: 15, after: 5, selected: false, reviewed: false });
const activeEvent = () => ride?.events.find((e) => e.id === activeId);
const ready = () =>
  Boolean(ride && sources.length && videoStart && !pendingSources.length);
const clipFor = (event) =>
  ready() ? resolveClip(event, editFor(event.id), videoStart, sources) : null;
const activeClip = () => (activeEvent() ? clipFor(activeEvent()) : null);
const selectedEvents = () =>
  ride?.events.filter((e) => editFor(e.id).selected) || [];
const jobURL = (id, action) =>
  `/api/jobs/${id}/${action}?session=${encodeURIComponent(session.id)}`;
async function api(
  url,
  payload,
  method = payload === undefined ? "GET" : "POST",
) {
  const response = await fetch(url, {
    method,
    headers: {
      "x-session": session?.id || "",
      ...(payload !== undefined ? { "Content-Type": "application/json" } : {}),
    },
    body: payload !== undefined ? JSON.stringify(payload) : undefined,
  });
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || "Something went wrong.");
  return data;
}
function notice(message, error = false) {
  clearTimeout(noticeTimer);
  $("notice").textContent = message;
  $("notice").className = `notice${error ? " error" : ""}`;
  $("notice").hidden = false;
  noticeTimer = setTimeout(
    () => ($("notice").hidden = true),
    error ? 14000 : 6500,
  );
}
function safely(fn) {
  return async (...args) => {
    try {
      await fn(...args);
    } catch (error) {
      notice(error.message, true);
    }
  };
}
function dialog(title, html) {
  $("dialog-title").textContent = title;
  $("dialog-body").innerHTML = html;
  if (!$("dialog").open) $("dialog").showModal();
}
function closeDialog() {
  $("dialog").close();
}
$("close-dialog").onclick = closeDialog;
$("dialog").addEventListener("click", (e) => {
  if (e.target === $("dialog")) {
    const r = $("dialog").getBoundingClientRect();
    if (
      e.clientX < r.left ||
      e.clientX > r.right ||
      e.clientY < r.top ||
      e.clientY > r.bottom
    )
      closeDialog();
  }
});
function projectData() {
  if (!ride) return null;
  return {
    format: "bumpyride-clip",
    version: 1,
    savedAt: new Date().toISOString(),
    ride: rideForProject(ride),
    videoStart,
    syncId,
    offset,
    edits,
    sources: [...sources, ...pendingSources]
      .sort((a, b) =>
        pendingSources.length
          ? (a.projectOrder ?? 0) - (b.projectOrder ?? 0)
          : 0,
      )
      .map(({ name, size, mtimeMs, duration, gapBefore }) => ({
        name,
        size,
        mtimeMs,
        duration,
        gapBefore: gapBefore || 0,
      })),
  };
}
function remember() {
  if (!ride) return;
  isDirty = true;
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(projectData()));
  } catch {
    notice(
      "Browser autosave is unavailable. Save your project JSON to keep your edits.",
      true,
    );
  }
  $("project-state").textContent = "Edits saved in this browser";
}
function invalidatePreview() {
  previewKey = "";
  previewJobId = "";
}
function renderAll() {
  document.body.classList.toggle("has-ride", Boolean(ride));
  $("project-title").textContent = ride
    ? ride.title
    : "Ride clips";
  $("project-subtitle").textContent = ride
    ? `${dateTime(ride.startedAt)} · ${ride.events.length} reports · ${formatTime(timestamp(ride.endedAt) - timestamp(ride.startedAt))} ride`
    : "Review video for the things you track in BumpyRide.";
  $("save-project").disabled = !ride;
  $("ride-badge").textContent = ride ? `${ride.events.length} REPORTS` : "JSON";
  $("ride-summary").innerHTML = ride
    ? `<p class="setup-copy">${escape(ride.title)}</p><p class="muted">${ride.syncs.length} video sync ${ride.syncs.length === 1 ? "marker" : "markers"} · Hard brakes excluded</p>`
    : '<p class="setup-copy">Choose a BumpyRide ride.</p><p class="muted">Open a ride from BumpyRide’s iCloud Documents.</p>';
  $("video-badge").textContent =
    `${sources.length} FILE${sources.length === 1 ? "" : "S"}`;
  const total = segmentsFor(sources).at(-1)?.end || 0;
  $("source-summary").innerHTML = sources.length
    ? `<p class="setup-copy">${sources.length} linked ${sources.length === 1 ? "video" : "videos"} · ${formatTime(total)} of recording</p><p class="muted">${humanSize(sources.reduce((sum, s) => sum + s.size, 0))} · ${sources.some((s) => s.uploaded) ? "Includes temporary browser uploads" : "Original files linked in place"}</p>`
    : pendingSources.length
      ? `<p class="setup-copy">Relink ${pendingSources.length} original video files</p><p class="muted">Your saved edits are ready. Add the matching videos.</p>`
      : '<p class="setup-copy">Add the videos from your ride.</p><p class="muted">Link originals in place, including files over 4 GB.</p>';
  $("sync-badge").textContent = videoStart
    ? syncId
      ? "SYNCED"
      : "MANUAL"
    : "NOT SET";
  $("sync-summary").innerHTML = videoStart
    ? `<p class="setup-copy">Video starts ${escape(clockTime(videoStart))}</p><p class="muted">${syncId ? "From Video Sync report" : "Manually aligned"}${offset ? ` · ${offset > 0 ? "+" : ""}${offset}s correction` : ""}</p>`
    : `<p class="setup-copy">${ride ? "Set the first video’s real start time." : "Match reports to the video."}</p><p class="muted">${ride && !ride.syncs.length ? "No Video Sync report in this ride. Set it manually." : ride?.syncs.length > 1 ? "Choose which Video Sync report matches this footage." : "A Video Sync report sets the first video’s start."}</p>`;
  renderEvents();
  renderTimeline();
  renderEditor();
}
function filteredEvents() {
  return (ride?.events || []).filter(
    (e) =>
      filter === "all" ||
      (filter === "custom"
        ? e.isCustom
        : filter === "unreviewed"
          ? !editFor(e.id).reviewed
          : !e.isCustom && e.kind === filter),
  );
}
function renderEvents() {
  $("event-count").textContent = ride?.events.length || 0;
  $("review-count").textContent =
    `${ride?.events.filter((e) => editFor(e.id).reviewed).length || 0} reviewed`;
  const events = filteredEvents();
  if (!ride)
    $("event-list").innerHTML =
      '<div class="empty-list"><span class="empty-symbol">⚑</span><h3>No ride loaded.</h3><p>Close calls, blocked lanes, and custom events will appear here.</p><small>Hard brakes are left out.</small></div>';
  else if (!events.length)
    $("event-list").innerHTML =
      '<div class="empty-hint">No events in this view. Only close calls, blocked lanes, and custom reports become clips.</div>';
  else
    $("event-list").innerHTML = events
      .map((e) => {
        const edit = editFor(e.id),
          clip = clipFor(e);
        return `<div class="event-row${e.id === activeId ? " active" : ""}"><input type="checkbox" data-select="${escape(e.id)}" aria-label="Select ${escape(e.label)} at ${escape(clockTime(e.timestamp))} for reel" ${edit.selected ? "checked" : ""} ${clip && !clip.available && !edit.selected ? "disabled" : ""}><button data-event="${escape(e.id)}" aria-pressed="${e.id === activeId}"><span class="event-icon ${escape(kindClass(e))}">${e.kind === "close-call" ? "!" : e.kind === "blocked-lane" ? "▥" : "⚑"}</span><span class="event-text"><strong>${escape(e.label)}</strong><small>${escape(clockTime(e.timestamp))}${clip && !clip.available ? " · No coverage" : ""}</small></span>${edit.reviewed ? '<span class="event-check" title="Reviewed">✓</span>' : ""}<span class="event-duration">${clip?.available ? `${clip.duration.toFixed(0)}s` : "—"}</span></button></div>`;
      })
      .join("");
  document
    .querySelectorAll("[data-event]")
    .forEach((b) => (b.onclick = () => selectEvent(b.dataset.event)));
  document.querySelectorAll("[data-select]").forEach(
    (i) =>
      (i.onchange = () => {
        editFor(i.dataset.select).selected = i.checked;
        const event = ride.events.find((e) => e.id === i.dataset.select);
        i.disabled = !i.checked && clipFor(event)?.available === false;
        remember();
        renderSelection();
      }),
  );
  const selectable = events.filter((e) => clipFor(e)?.available);
  $("select-all").textContent =
    selectable.length && selectable.every((e) => editFor(e.id).selected)
      ? "Deselect all"
      : "Select all";
  $("select-all").disabled = !selectable.length;
  renderSelection();
}
function renderSelection() {
  const selected = selectedEvents(),
    clips = selected.map(clipFor),
    valid = ready() && clips.every((c) => c?.available);
  $("selected-count").textContent =
    `${selected.length} ${selected.length === 1 ? "clip" : "clips"} selected`;
  $("reel-duration").textContent = selected.length
    ? `${formatTime(clips.reduce((n, c) => n + (c?.duration || 0), 0))} · In report order${valid ? "" : " · Check footage coverage"}`
    : "Build a reel from your ride";
  $("export-reel").disabled = !selected.length || !valid || busy;
  $("apply-selected-timing").hidden = selected.length < 2;
  $("apply-selected-timing").textContent = `Apply timing to ${selected.length} selected clips`;
  $("apply-selected-timing").disabled = !activeId || busy;
}
function renderTimeline() {
  const segments = segmentsFor(sources),
    total = segments.at(-1)?.end || 0;
  $("timeline-duration").textContent = formatTime(total);
  if (!total) {
    $("timeline").innerHTML =
      '<span class="timeline-placeholder">Your video segments and reports will appear here</span>';
    return;
  }
  $("timeline").innerHTML =
    segments
      .map(
        (s, i) =>
          `<span class="segment" style="left:${(s.start / total) * 100}%;width:${(s.duration / total) * 100}%" title="${escape(s.name)}">${String(i + 1).padStart(2, "0")} · ${escape(s.name)}</span>`,
      )
      .join("") +
    (ready()
      ? ride.events
          .map((e) => {
            const c = clipFor(e);
            if (c.offset < 0 || c.offset > total) return "";
            return `<button class="marker ${escape(kindClass(e))}${e.id === activeId ? " active" : ""}" data-marker="${escape(e.id)}" style="left:${Math.min(99.5, (c.offset / total) * 100)}%" aria-label="${escape(e.label)} at ${formatTime(c.offset)}" title="${escape(e.label)} · ${formatTime(c.offset)}"></button>`;
          })
          .join("")
      : "");
  document
    .querySelectorAll("[data-marker]")
    .forEach((b) => (b.onclick = () => selectEvent(b.dataset.marker)));
}
function renderEditor() {
  const e = activeEvent(),
    c = activeClip();
  $("active-title").textContent = e ? e.label : "Clip preview";
  $("active-kicker").textContent = e
    ? `REPORT ${String(ride.events.indexOf(e) + 1).padStart(2, "0")} / ${String(ride.events.length).padStart(2, "0")}`
    : "CLIP PREVIEW";
  $("active-time").textContent = e ? clockTime(e.timestamp) : "";
  $("clip-editor").hidden = !e;
  $("event-cue").hidden = !c?.available;
  $("calibrate").disabled = !c?.available || busy;
  $("calibration-offset").value = offset;
  $("calibration-controls").hidden = !$("calibrate").checked || !c?.available;
  for (const id of ["calibration-offset", "event-earlier", "event-later", "match-frame", "reset-calibration"])
    $(id).disabled = !c?.available || busy;
  updateEventCue();
  if (!e) {
    clearVideo();
    return;
  }
  const edit = editFor(e.id);
  $("before").value = edit.before;
  $("after").value = edit.after;
  for (const side of ["before", "after"]) {
    $(`${side}-range`).max = Math.max(90, edit[side]);
    $(`${side}-range`).value = edit[side];
  }
  $("reviewed").checked = edit.reviewed;
  $("clip-length").textContent = c
    ? `${c.duration.toFixed(1)}s clip`
    : "20s default";
  $("clip-boundaries").textContent = c?.available
    ? `${formatTime(c.start)} → ${formatTime(c.end)}${c.parts.length > 1 ? " · Spans files" : ""}`
    : "Connect footage and set the alignment";
  for (const id of [
    "play-clip",
    "jump-event",
    "compatible-preview",
    "export-clip",
  ])
    $(id).disabled = !c?.available || busy;
  let note = "Original files stay exactly where you put them.",
    warning = false;
  if (!sources.length || pendingSources.length) {
    note = pendingSources.length
      ? "Relink all saved source videos to review this clip."
      : "Add your ride videos to preview this report.";
    warning = true;
  } else if (!videoStart) {
    note =
      "Set a Video Sync marker or enter the first video’s real start time.";
    warning = true;
  } else if (!c?.available) {
    note = c?.reason || "No footage available.";
    warning = true;
  } else if (c.clamped) {
    note =
      "This clip reaches the edge of the available footage; its export is shortened to fit.";
    warning = true;
  } else if (c.parts.length > 1)
    note =
      "This clip spans video files. Playback and export join the pieces automatically.";
  else
    note = `Report at ${formatTime(c.offset)} · ${sources.find((s) => s.id === c.parts[0].sourceId)?.name || ""}`;
  setPreviewNote(note, warning);
  if (!c?.available) clearVideo();
}
function setPreviewNote(text, warning = false) {
  $("preview-note").className = `preview-note${warning ? " warning" : ""}`;
  $("preview-note").innerHTML =
    `<span class="dot"></span><span>${escape(text)}</span>`;
}
function clearVideo() {
  playbackGeneration++;
  isPlayingClip = false;
  video.pause();
  video.removeAttribute("src");
  video.load();
  currentSourceId = "";
  video.hidden = true;
  $("video-empty").hidden = false;
  $("video-tag").hidden = false;
}
function selectEvent(id) {
  activeId = id;
  invalidatePreview();
  video.pause();
  isPlayingClip = false;
  renderEvents();
  renderTimeline();
  renderEditor();
  if (activeClip()?.available) seekTimeline(activeClip().start);
}
function seekTimeline(time, autoplay = false) {
  const segment =
    segmentsFor(sources).find(
      (s) => time >= s.start - 0.001 && time < s.end - 0.001,
    ) || segmentsFor(sources).at(-1);
  if (!segment) return;
  const generation = ++playbackGeneration;
  playbackMode = "source";
  loadingVideo = true;
  video.hidden = false;
  $("video-empty").hidden = true;
  $("video-tag").hidden = true;
  const seek = () => {
    if (generation !== playbackGeneration) return;
    video.currentTime = Math.max(
      0,
      Math.min(segment.duration - 0.01, time - segment.start),
    );
    loadingVideo = false;
    updateEventCue();
    if (autoplay)
      video.play().catch(() => {
        isPlayingClip = false;
      });
  };
  if (currentSourceId !== segment.id || !video.src.includes("/media/")) {
    currentSourceId = segment.id;
    video.onloadedmetadata = seek;
    video.src = `/media/${segment.id}?session=${encodeURIComponent(session.id)}`;
    video.load();
  } else seek();
}
video.addEventListener("error", () => {
  if (video.getAttribute("src")) {
    loadingVideo = false;
    setPreviewNote(
      "Your browser cannot play this source directly. Use “Build compatible preview” to create a small local preview.",
      true,
    );
  }
});
video.addEventListener("play", () => {
  if (playbackMode !== "source" || loadingVideo) return;
  const clip = activeClip(),
    segment = segmentsFor(sources).find((s) => s.id === currentSourceId);
  if (!clip?.available || !segment) return;
  isPlayingClip = true;
  const position = segment.start + video.currentTime;
  if (position < clip.start - 0.05 || position >= clip.end - 0.05)
    seekTimeline(clip.start, true);
});
video.addEventListener("timeupdate", () => {
  updateEventCue();
  if (loadingVideo || !isPlayingClip || playbackMode !== "source") return;
  const c = activeClip(),
    s = segmentsFor(sources).find((s) => s.id === currentSourceId);
  if (!c || !s) return;
  if (s.start + video.currentTime >= c.end - 0.04) {
    video.pause();
    isPlayingClip = false;
  }
});
video.addEventListener("ended", () => {
  if (!isPlayingClip || playbackMode !== "source") return;
  const c = activeClip(),
    s = segmentsFor(sources).find((s) => s.id === currentSourceId);
  if (c && s && s.end < c.end - 0.05) seekTimeline(s.end + 0.001, true);
  else isPlayingClip = false;
});
$("play-clip").onclick = () => {
  if (playbackMode === "preview" && previewKey === clipKey()) {
    video.currentTime = 0;
    video.play().catch(() => {});
    return;
  }
  const c = activeClip();
  if (c?.available) {
    isPlayingClip = true;
    seekTimeline(c.start, true);
  }
};
$("jump-event").onclick = () => {
  const c = activeClip();
  if (c?.available) {
    isPlayingClip = false;
    video.pause();
    seekTimeline(c.offset);
  }
};
function recordingPosition() {
  if (loadingVideo || video.hidden || !video.readyState) return null;
  if (playbackMode === "preview") return previewKey === clipKey() ? activeClip()?.start + video.currentTime : null;
  const segment = segmentsFor(sources).find((s) => s.id === currentSourceId);
  return segment ? segment.start + video.currentTime : null;
}
function updateEventCue() {
  const clip = activeClip(), position = recordingPosition();
  if (!clip?.available) return;
  const cue = eventCue(clip, position ?? clip.start);
  $("event-cue-label").textContent = `⚑ Event recorded at ${cue.eventTime.toFixed(1)}s in this clip`;
  $("event-cue-status").textContent = position == null ? "Loading preview…" : cue.atEvent ? "EVENT RECORDED" : `${Math.abs(cue.delta).toFixed(1)}s ${cue.delta < 0 ? "before" : "after"} event`;
  $("event-cue").classList.toggle("at-event", position != null && cue.atEvent);
  $("clip-event-marker").style.left = `${cue.eventFraction * 100}%`;
  $("clip-playhead").style.left = `${cue.playheadFraction * 100}%`;
  $("match-frame").disabled = busy || position == null || !video.paused;
}
for (const name of ["seeked", "loadedmetadata", "pause", "play", "emptied"])
  video.addEventListener(name, updateEventCue);
$("calibrate").onchange = () => renderEditor();
function calibrate(adjustment) {
  if (busy || !activeClip()?.available) return;
  const position = recordingPosition();
  const corrected = calibratedStart(videoStart, offset, adjustment);
  video.pause(); isPlayingClip = false;
  videoStart = corrected; offset = adjustment;
  invalidatePreview(); remember(); renderAll();
  const clip = activeClip();
  if (clip?.available) seekTimeline(Math.max(clip.start, Math.min(clip.end - 0.01, position ?? clip.start)));
  // Compatible previews are cached cuts; rebuild after alignment changes if the source cannot play.
}
$("calibration-offset").onchange = safely((event) => calibrate(Number(event.target.value)));
$("event-earlier").onclick = safely(() => calibrate(Math.round((offset + 0.1) * 1000) / 1000));
$("event-later").onclick = safely(() => calibrate(Math.round((offset - 0.1) * 1000) / 1000));
$("reset-calibration").onclick = safely(() => calibrate(0));
$("match-frame").onclick = safely(() => {
  const position = recordingPosition(), clip = activeClip();
  if (position == null || !clip?.available || !video.paused) return;
  calibrate(Math.round((offset + clip.offset - position) * 1000) / 1000);
});
$("apply-selected-timing").onclick = safely(() => {
  if (busy || !activeId || selectedEvents().length < 2) return;
  const edit = editFor(activeId), count = selectedEvents().length;
  edits = applySelectedTiming(ride.events, edits, edit.before, edit.after);
  invalidatePreview(); remember(); renderEvents(); renderEditor(); renderTimeline();
  video.pause(); isPlayingClip = false;
  if (activeClip()?.available) seekTimeline(activeClip().start);
  notice(`Applied ${edit.before}s before / ${edit.after}s after to ${count} selected clips.`);
});
function changeTrim(side, value) {
  const e = activeEvent();
  if (!e || busy) return;
  const number = Number(value),
    edit = editFor(e.id),
    other = side === "before" ? "after" : "before";
  if (!Number.isFinite(number) || number < 0 || number + edit[other] <= 0) {
    notice("Use non-negative seconds and keep a clip longer than zero.", true);
    renderEditor();
    return;
  }
  edit[side] = number;
  invalidatePreview();
  remember();
  renderEvents();
  renderEditor();
  isPlayingClip = false;
  video.pause();
  if (activeClip()?.available) seekTimeline(activeClip().start);
}
for (const side of ["before", "after"]) {
  $(side).onchange = (e) => changeTrim(side, e.target.value);
  $(`${side}-range`).oninput = (e) => {
    $(side).value = e.target.value;
  };
  $(`${side}-range`).onchange = (e) => changeTrim(side, e.target.value);
}
document.querySelectorAll("[data-trim]").forEach(
  (b) =>
    (b.onclick = () => {
      const [side, delta] = b.dataset.trim.split(":");
      changeTrim(side, Math.max(0, editFor(activeId)[side] + Number(delta)));
    }),
);
$("reset-trim").onclick = () => {
  if (!activeId) return;
  editFor(activeId).before = 15;
  changeTrim("after", 5);
};
$("reviewed").onchange = (e) => {
  editFor(activeId).reviewed = e.target.checked;
  remember();
  renderEvents();
};
$("filter").onchange = (e) => {
  filter = e.target.value;
  renderEvents();
};
$("select-all").onclick = () => {
  const events = filteredEvents().filter((e) => clipFor(e)?.available),
    selected = events.every((e) => editFor(e.id).selected);
  for (const e of events) editFor(e.id).selected = !selected;
  remember();
  renderEvents();
};
function loadRide(next) {
  ride = next;
  edits = Object.create(null);
  syncId = "";
  offset = 0;
  videoStart = "";
  pendingSources = [];
  activeId = ride.events[0]?.id || "";
  invalidatePreview();
  clearVideo();
  if (ride.syncs.length === 1) {
    syncId = ride.syncs[0].id;
    videoStart = ride.syncs[0].timestamp;
  }
  remember();
  renderAll();
  if (ride.warnings.length) notice(ride.warnings.join(" "), true);
  else
    notice(
      `${ride.events.length} reports loaded.${!ride.syncs.length ? " No video-sync marker found; set the start time manually." : ""}`,
    );
  if (activeClip()?.available) seekTimeline(activeClip().start);
}
async function replaceRide(next) {
  if (ride && isDirty) {
    dialog(
      "Switch rides?",
      '<p class="dialog-copy">Save your current project first if you want to keep these edits. Your linked source videos will stay available for the next ride.</p><div class="dialog-actions"><button id="switch-save">Save current project</button><button id="switch-confirm" class="primary">Open new ride</button></div>',
    );
    $("switch-save").onclick = saveProject;
    $("switch-confirm").onclick = () => {
      closeDialog();
      loadRide(next);
    };
  } else loadRide(next);
}
$("open-ride").onclick = () => $("ride-file").click();
$("ride-file").onchange = safely(async (e) => {
  const file = e.target.files[0];
  e.target.value = "";
  if (!file) return;
  if (file.size > 100_000_000)
    throw new Error("Ride JSON is larger than 100 MB.");
  await replaceRide(parseRide(JSON.parse(await file.text())));
});
$("cloud-rides").onclick = safely(async () => {
  dialog("Choose a ride", '<p class="dialog-copy">Reading ride details… Cloud-only files may need downloading first.</p>');
  const files = await api("/api/rides");
  dialog(
    "Choose a ride",
    '<p class="dialog-copy">Newest rides first, using the date recorded by BumpyRide. Hard brakes are excluded from report counts.</p><label class="form-field">Search rides<input id="ride-search" type="search" placeholder="Ride title or filename"></label><label class="form-field">Ride date<input id="ride-date" type="date"></label><label class="check-row"><input id="rides-with-reports" type="checkbox"> With reports only</label><div id="cloud-list" class="cloud-list"></div><p class="dialog-copy">To browse another folder, set BUMPYRIDE_RIDES_DIR before starting the server. You can also open an individual ride JSON from the main screen.</p>',
  );
  function showFiles() {
    const date = $("ride-date").value,
      query = $("ride-search").value.trim().toLocaleLowerCase(),
      visible = files.filter((f) =>
        (!date || (f.startedAt && new Date(f.startedAt).toLocaleDateString("en-CA") === date)) &&
        (!query || `${f.title} ${f.name}`.toLocaleLowerCase().includes(query)) &&
        (!$("rides-with-reports").checked || f.reports > 0));
    $("cloud-list").innerHTML = visible.length
      ? visible.map((f, i) =>
          `<button class="cloud-row" data-cloud="${i}" ${f.issue ? "disabled" : ""}><strong>${escape(f.title || "Untitled ride")}</strong><small>${f.issue ? escape(f.issue) : `${escape(dateTime(f.startedAt))} · ${formatTime(f.duration)} · ${f.reports} reports · ${f.syncs ? `${f.syncs} video sync` : "No video sync"}`}</small><small>${escape(f.name)}</small></button>`,
        ).join("")
      : '<p class="dialog-copy">No rides match. Try another search or turn off the filters.</p>';
    document.querySelectorAll("[data-cloud]").forEach((b) =>
      (b.onclick = safely(async () => {
        b.disabled = true;
        b.textContent = "Reading ride…";
        try {
          const next = await api("/api/ride", { path: visible[Number(b.dataset.cloud)].path });
          closeDialog();
          await replaceRide(next);
        } catch (error) { showFiles(); throw error; }
      })),
    );
  }
  showFiles();
  $("ride-search").oninput = showFiles;
  $("ride-date").onchange = showFiles;
  $("rides-with-reports").onchange = showFiles;
});
function matchesSource(expected, actual) {
  return (
    expected.name === actual.name &&
    expected.size === actual.size &&
    Math.abs(expected.duration - actual.duration) < 0.25 &&
    (!expected.mtimeMs || Math.abs(expected.mtimeMs - actual.mtimeMs) < 2000)
  );
}
function attachSources(added) {
  if (pendingSources.length) {
    // Keep the original project order even when files are selected in a different order.
    const candidates = added.filter(
        (s) => !sources.some((existing) => existing.id === s.id),
      ),
      ordered = [];
    const remaining = [];
    for (const expected of pendingSources) {
      const match = candidates.find(
        (s) =>
          !ordered.some((item) => item.id === s.id) &&
          matchesSource(expected, s),
      );
      if (match) {
        ordered.push({
          ...match,
          gapBefore: expected.gapBefore || 0,
          projectOrder: expected.projectOrder,
        });
      } else remaining.push(expected);
    }
    const known = [...sources, ...ordered]
      .filter((s, i, a) => a.findIndex((t) => t.id === s.id) === i)
      .sort((a, b) => (a.projectOrder ?? 0) - (b.projectOrder ?? 0));
    const unmatched = added.filter((s) => !known.some((k) => k.id === s.id));
    sources = known;
    pendingSources = remaining;
    if (unmatched.length)
      notice(
        `${unmatched.length} files did not match the saved project (name, size, duration, and modification time).`,
        true,
      );
    if (!remaining.length)
      notice("Original videos relinked. Your edits are ready.");
  } else {
    for (const source of added)
      if (!sources.some((s) => s.id === source.id))
        sources.push({ ...source, gapBefore: 0 });
  }
  invalidatePreview();
  remember();
  renderAll();
  if (activeClip()?.available) seekTimeline(activeClip().start);
}
$("add-videos").onclick = safely(async () => {
  if (session.platform === "darwin") {
    notice("Choose the original videos in the file dialog.");
    const { paths } = await api("/api/pick", { kind: "video" });
    if (paths.length) {
      notice("Reading video metadata…");
      attachSources(await api("/api/sources", { paths }));
    }
  } else showSources();
});
function showSources() {
  dialog(
    "Your source footage",
    `<p class="dialog-copy">Files play in the order below. Split camera files are assumed to be continuous. Enter a gap only when the recording actually stopped. Camera dates are never used for alignment.</p><div class="file-list">${sources.map((s, i) => `<div class="file-row"><span class="mono">${String(i + 1).padStart(2, "0")}</span><div class="file-info"><strong>${escape(s.name)}</strong><small>${formatTime(s.duration)} · ${humanSize(s.size)} · ${s.uploaded ? "Temporary local copy" : "Linked original"}</small>${i ? `<label class="file-gap">Gap before file <input type="number" min="0" step="0.1" data-gap="${i}" value="${s.gapBefore || 0}" aria-label="Gap before ${escape(s.name)}"> seconds</label>` : ""}</div><button data-move="${i}:-1" aria-label="Move ${escape(s.name)} earlier" ${i === 0 ? "disabled" : ""}>↑</button><button data-move="${i}:1" aria-label="Move ${escape(s.name)} later" ${i === sources.length - 1 ? "disabled" : ""}>↓</button><button data-remove="${i}" aria-label="Remove ${escape(s.name)}">✕</button></div>`).join("") || '<div class="subtle-box">No videos linked yet.</div>'}</div>${pendingSources.length ? `<div class="subtle-box warning-box">Still needed: ${pendingSources.map((s) => escape(s.name)).join(", ")}. Reattach the unchanged originals to preserve the saved sequence.</div>` : ""}<label class="form-field">Link files by absolute path<textarea id="video-paths" rows="2" placeholder="/Users/you/Movies/ride-part-1.MOV"></textarea><small>One path per line. Linked files are read in place, with no duplicate copy.</small></label><div class="button-row"><button id="link-paths">Link paths</button><button id="load-samples">Use sample videos</button><button id="upload-browser" class="quiet">Browser upload…</button></div><p class="dialog-copy">Browser uploads create temporary copies on this computer. “Finish session” removes them. Linking originals is recommended for large files.</p>`,
  );
  $("link-paths").onclick = safely(async () => {
    const paths = $("video-paths")
      .value.split("\n")
      .map((s) => s.trim())
      .filter(Boolean);
    if (!paths.length) return;
    notice("Reading video metadata…");
    attachSources(await api("/api/sources", { paths }));
    if (
      $("dialog").open &&
      $("dialog-title").textContent === "Your source footage"
    )
      showSources();
  });
  $("load-samples").onclick = safely(async () => {
    notice("Reading sample video metadata…");
    attachSources(await api("/api/samples", {}));
    if (
      $("dialog").open &&
      $("dialog-title").textContent === "Your source footage"
    )
      showSources();
  });
  $("upload-browser").onclick = () => $("video-files").click();
  document.querySelectorAll("[data-move]").forEach(
    (b) =>
      (b.onclick = () => {
        if (pendingSources.length)
          return notice(
            "Relink the remaining project videos before changing their order.",
            true,
          );
        const [i, d] = b.dataset.move.split(":").map(Number);
        [sources[i], sources[i + d]] = [sources[i + d], sources[i]];
        sources[0].gapBefore = 0;
        sourceChanged();
        showSources();
      }),
  );
  document.querySelectorAll("[data-remove]").forEach(
    (b) =>
      (b.onclick = () => {
        if (pendingSources.length)
          return notice(
            "Relink the remaining project videos before changing their order.",
            true,
          );
        sources.splice(Number(b.dataset.remove), 1);
        if (sources[0]) sources[0].gapBefore = 0;
        sourceChanged();
        showSources();
      }),
  );
  document.querySelectorAll("[data-gap]").forEach(
    (input) =>
      (input.onchange = () => {
        const value = Number(input.value);
        if (!Number.isFinite(value) || value < 0) {
          notice("A gap must be zero or more seconds.", true);
          return showSources();
        }
        sources[Number(input.dataset.gap)].gapBefore = value;
        sourceChanged();
      }),
  );
}
function sourceChanged() {
  clearVideo();
  invalidatePreview();
  remember();
  renderAll();
  if (activeClip()?.available) seekTimeline(activeClip().start);
}
$("source-settings").onclick = showSources;
$("video-files").onchange = safely(async (e) => {
  const files = [...e.target.files];
  e.target.value = "";
  if (!files.length) return;
  let cancelled = false;
  let request;
  dialog(
    "Copying videos locally",
    '<p class="dialog-copy">These temporary copies stay on this computer and are removed when you finish the session.</p><div class="progress-track"><div id="upload-progress" class="progress-fill"></div></div><p id="upload-state" class="render-state"></p><div class="dialog-actions"><button id="cancel-upload">Cancel upload</button></div>',
  );
  $("cancel-upload").onclick = () => {
    cancelled = true;
    request?.abort();
  };
  for (const file of files) {
    if (cancelled) break;
    if ($("upload-state"))
      $("upload-state").textContent =
        `Copying ${file.name} (${humanSize(file.size)})…`;
    const result = await new Promise((resolve, reject) => {
      request = new XMLHttpRequest();
      request.open(
        "POST",
        `/api/upload?name=${encodeURIComponent(file.name)}&modified=${file.lastModified}`,
      );
      request.setRequestHeader("x-session", session.id);
      request.upload.onprogress = (event) => {
        if ($("upload-progress") && event.lengthComputable)
          $("upload-progress").style.width =
            `${(event.loaded / event.total) * 100}%`;
        if ($("upload-state") && event.loaded === event.total)
          $("upload-state").textContent = `Checking ${file.name}…`;
      };
      request.onload = () => {
        try {
          const data = JSON.parse(request.responseText);
          request.status === 200
            ? resolve(data)
            : reject(new Error(data.error));
        } catch {
          reject(new Error("Could not read the upload response."));
        }
      };
      request.onerror = () =>
        reject(
          new Error(
            "Upload failed. Check that the local server is still running.",
          ),
        );
      request.onabort = () => resolve(null);
      request.send(file);
    });
    if (!result) break;
    attachSources([result]);
  }
  notice(
    cancelled
      ? "Upload cancelled. Completed files remain available until you finish the session."
      : "Local upload complete. Temporary copies will be removed when you finish.",
  );
  if ($("dialog").open) showSources();
});
function showSync() {
  const syncs = ride?.syncs || [],
    date = videoStart
      ? new Date(timestamp(videoStart) * 1000 - offset * 1000)
      : null;
  const localValue = date
    ? new Date(date.getTime() - date.getTimezoneOffset() * 60000)
        .toISOString()
        .slice(0, 19)
    : "";
  dialog(
    "Align the footage",
    `<p class="dialog-copy">The selected report marks frame zero of the <strong>first file</strong>. Later files follow in sequence. Video file dates and embedded camera clocks are ignored.</p><label class="form-field">Start-time reference<select id="sync-marker"><option value="">Enter the start time manually</option>${syncs.map((s) => `<option value="${escape(s.id)}" ${s.id === syncId ? "selected" : ""}>Video Sync · ${escape(dateTime(s.timestamp))}</option>`).join("")}</select></label>${!syncs.length ? '<div class="subtle-box warning-box">This ride has no Video Sync report. Enter the real-world time at which the first video started.</div>' : ""}<label class="form-field" id="manual-field">First frame’s real date and time<input id="manual-start" type="datetime-local" step="1" value="${localValue}"><small>Using your computer’s timezone: ${escape(Intl.DateTimeFormat().resolvedOptions().timeZone)}.</small></label><label class="form-field">Fine adjustment (seconds)<input id="sync-offset" type="number" step="0.1" value="${offset}"><small>Positive means the video started after the reference time. Example: +3 makes a report at +60 seconds appear at video +57 seconds.</small></label><div class="dialog-actions"><button id="apply-sync" class="primary">Apply alignment</button></div>`,
  );
  const toggle = () => {
    $("manual-field").hidden = Boolean($("sync-marker").value);
  };
  toggle();
  $("sync-marker").onchange = toggle;
  $("apply-sync").onclick = safely(() => {
    const chosen = $("sync-marker").value,
      adjustment = Number($("sync-offset").value),
      marker = syncs.find((s) => s.id === chosen);
    const base = marker
      ? timestamp(marker.timestamp) * 1000
      : new Date($("manual-start").value).getTime();
    if (!Number.isFinite(base) || !Number.isFinite(adjustment))
      throw new Error("Enter a valid start time and adjustment.");
    videoStart = new Date(base + adjustment * 1000).toISOString();
    syncId = chosen;
    offset = adjustment;
    sourceChanged();
    closeDialog();
  });
}
$("sync-settings").onclick = showSync;
function saveProject() {
  const data = projectData();
  if (!data) return;
  const blob = new Blob([JSON.stringify(data, null, 2)], {
      type: "application/json",
    }),
    url = URL.createObjectURL(blob),
    a = document.createElement("a");
  a.href = url;
  a.download = `${ride.title.replace(/[^\w-]+/g, "-")}.bumpyclip.json`;
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
  isDirty = false;
  notice(
    "Project saved with edits and source fingerprints. No video data is included.",
  );
}
$("save-project").onclick = saveProject;
function restoreProject(raw) {
  const data = validateProject(raw);
  ride = data.ride;
  sources = [];
  pendingSources = data.sources.map((s, i) => ({ ...s, projectOrder: i }));
  edits = data.edits;
  videoStart = data.videoStart;
  syncId = data.syncId;
  offset = data.offset;
  activeId = ride.events[0]?.id || "";
  invalidatePreview();
  clearVideo();
  remember();
  renderAll();
  notice("Project restored. Relink its original video files to continue.");
}
$("open-project").onclick = () => $("project-file").click();
$("project-file").onchange = safely(async (e) => {
  const file = e.target.files[0];
  e.target.value = "";
  if (!file) return;
  if (file.size > 20_000_000) throw new Error("Project metadata is too large.");
  const raw = JSON.parse(await file.text());
  validateProject(raw);
  if (ride && isDirty) {
    dialog(
      "Open another project?",
      '<p class="dialog-copy">Save the current project to keep its edits before switching.</p><div class="dialog-actions"><button id="project-save-first">Save current project</button><button id="project-replace" class="primary">Open project</button></div>',
    );
    $("project-save-first").onclick = saveProject;
    $("project-replace").onclick = () => {
      closeDialog();
      restoreProject(raw);
    };
  } else restoreProject(raw);
});
function clipKey() {
  return JSON.stringify({
    id: activeId,
    edit: activeId ? editFor(activeId) : null,
    videoStart,
    sources: sources.map((s) => [s.id, s.gapBefore]),
  });
}
async function runRender(events, preview = false) {
  if (busy) return notice("A render is already running.");
  if (!ready() || events.some((e) => !clipFor(e)?.available))
    throw new Error("Align the footage and check clip coverage first.");
  const key = clipKey(),
    eventId = activeId,
    exportDuration = events.reduce((n, e) => n + clipFor(e).duration, 0);
  busy = true;
  renderEditor();
  renderSelection();
  dialog(
    preview ? "Building a compatible preview" : "Exporting your ride",
    `<p class="dialog-copy">${preview ? "Making a small browser-friendly MP4 of this clip." : "Rendering H.264 video with audio at the first selected source’s dimensions and frame rate. Selected clips are joined in report order."}</p><div class="progress-track"><div id="render-progress" class="progress-fill"></div></div><p id="render-state" class="render-state">Starting local video processor…</p><div class="dialog-actions"><button id="cancel-render">Cancel render</button></div>`,
  );
  try {
    const result = await api("/api/jobs", {
      sources: sources.map((s) => ({ id: s.id, gapBefore: s.gapBefore || 0 })),
      videoStart,
      clips: events.map((event) => ({ event, edit: editFor(event.id) })),
      preview,
    });
    activeJobId = result.id;
    $("cancel-render").onclick = safely(async () => {
      await api(`/api/jobs/${result.id}`, undefined, "DELETE");
      notice("Render cancelled.");
    });
    let job;
    do {
      await new Promise((resolve) => setTimeout(resolve, 700));
      job = await api(`/api/jobs/${result.id}`);
      if ($("render-progress"))
        $("render-progress").style.width = `${Math.round(job.progress * 100)}%`;
      if ($("render-state"))
        $("render-state").textContent =
          `${Math.round(job.progress * 100)}% · Processing ${events.length} ${events.length === 1 ? "clip" : "clips"} locally. You can close this panel while it finishes.`;
    } while (job.status === "running");
    if (job.status !== "ready")
      throw new Error(job.error || "Render did not complete.");
    if (preview) {
      if (activeId === eventId && key === clipKey()) {
        previewJobId = job.id;
        previewKey = key;
        video.pause();
        isPlayingClip = false;
        playbackMode = "preview";
        currentSourceId = "";
        video.onloadedmetadata = null;
        playbackGeneration++;
        loadingVideo = false;
        video.src = jobURL(job.id, "video");
        video.load();
        video.hidden = false;
        $("video-empty").hidden = true;
        $("video-tag").hidden = true;
        closeDialog();
        setPreviewNote(
          "Compatible preview · Playback starts at the beginning of your trimmed clip.",
        );
        notice("Preview ready.");
      } else
        notice(
          "Preview completed for an earlier edit. Build a new preview for the current clip.",
        );
    } else {
      dialog(
        "Your video is ready",
        `<div class="subtle-box">${events.length} ${events.length === 1 ? "clip" : "clips"} · ${formatTime(exportDuration)} · H.264 / AAC MP4</div><p class="dialog-copy">Save your export before finishing the session. Temporary renders are removed when you finish.</p><a class="download-ready" href="${jobURL(job.id, "download")}" download>Download ${events.length === 1 ? "clip" : "reel"} ↗</a><div class="dialog-actions">${session.platform === "darwin" ? '<button id="save-video-as">Save to a folder…</button>' : ""}<button id="done-export" class="primary">Back to review</button></div>`,
      );
      if ($("save-video-as"))
        $("save-video-as").onclick = safely(async () => {
          const saved = await api(`/api/jobs/${job.id}/save`, {});
          if (saved.path) notice(`Saved to ${saved.path}`);
        });
      $("done-export").onclick = closeDialog;
    }
  } catch (error) {
    if ($("render-state"))
      $("render-state").textContent = error.message.includes("expired")
        ? "Render cancelled or expired."
        : error.message;
    if ($("cancel-render")) $("cancel-render").hidden = true;
    notice(
      error.message.includes("expired") ? "Render cancelled." : error.message,
      true,
    );
  } finally {
    activeJobId = "";
    busy = false;
    renderEditor();
    renderSelection();
  }
}
$("compatible-preview").onclick = safely(() =>
  runRender([activeEvent()], true),
);
$("export-clip").onclick = safely(() => runRender([activeEvent()]));
$("export-reel").onclick = () => {
  const events = selectedEvents();
  dialog(
    "Assemble your reel",
    `<p class="dialog-copy">Your selected clips will play in chronological report order. Overlapping clips remain separate so each report keeps its own context.</p>${events.map((e) => `<div class="reel-item">${escape(e.label)}<span>${escape(clockTime(e.timestamp))} · ${clipFor(e).duration.toFixed(1)}s</span></div>`).join("")}<div class="dialog-actions"><button id="confirm-reel" class="primary">Export ${events.length} clips</button></div>`,
  );
  $("confirm-reel").onclick = safely(() => runRender(events));
};
$("finish").onclick = () => {
  dialog(
    "Finish this session?",
    '<p class="dialog-copy">Save your project and download any exports you want to keep. Finishing deletes this session’s temporary uploads, previews, and rendered exports, and cancels any render in progress. Linked original videos and downloaded files stay untouched.</p><div class="dialog-actions"><button id="finish-save">Save project</button><button id="finish-confirm" class="primary">Clean up & finish</button></div>',
  );
  $("finish-save").disabled = !ride;
  $("finish-save").onclick = saveProject;
  $("finish-confirm").onclick = safely(async () => {
    clearVideo();
    await api("/api/session", undefined, "DELETE");
    localStorage.removeItem(STORAGE_KEY);
    isDirty = false;
    location.reload();
  });
};
window.addEventListener("beforeunload", (e) => {
  if (busy) {
    e.preventDefault();
    e.returnValue = "";
  }
});
async function start() {
  session = await api("/api/session", {});
  renderAll();
  setInterval(() => api("/api/heartbeat", {}).catch(() => {}), 30000);
  let saved;
  try {
    saved = JSON.parse(localStorage.getItem(STORAGE_KEY));
  } catch {}
  if (saved) {
    try {
      validateProject(saved);
    } catch {
      return;
    }
    dialog(
      "Pick up where you left off",
      `<p class="dialog-copy">A lightweight project for <strong>${escape(saved.ride.title)}</strong> is saved in this browser. Restore it, then relink the originals.</p><div class="dialog-actions"><button id="fresh-start">Start fresh</button><button id="restore-last" class="primary">Restore project</button></div>`,
    );
    $("fresh-start").onclick = () => {
      localStorage.removeItem(STORAGE_KEY);
      closeDialog();
    };
    $("restore-last").onclick = () => {
      closeDialog();
      restoreProject(saved);
    };
  }
}
start().catch((error) =>
  notice(`Could not connect to the local app: ${error.message}`, true),
);
