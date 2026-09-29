// Shared by the browser and server. Times are seconds relative to video zero.
export function timestamp(value) {
  if (typeof value !== "string" || !/(Z|[+-]\d\d:\d\d)$/.test(value))
    throw new Error("Timestamps must include a timezone (ISO 8601).");
  const time = Date.parse(value);
  if (!Number.isFinite(time)) throw new Error("Invalid timestamp.");
  return time / 1000;
}
export function isVideoSync(kind) {
  return (
    typeof kind === "string" &&
    kind
      .trim()
      .toLowerCase()
      .replace(/[\s_-]+/g, "") === "videosync"
  );
}
export function parseRide(raw) {
  if (!raw || typeof raw.id !== "string" || typeof raw.title !== "string")
    throw new Error(
      "Choose a BumpyRide ride JSON file, not a log or metrics file.",
    );
  timestamp(raw.startedAt);
  timestamp(raw.endedAt);
  const events = [],
    syncs = [],
    warnings = [],
    ids = new Set();
  for (const field of ["closeCallEvents", "otherEvents"]) {
    if (raw[field] != null && !Array.isArray(raw[field]))
      throw new Error(`${field} must be an array.`);
    for (const [i, entry] of (raw[field] || []).entries()) {
      try {
        timestamp(entry.timestamp);
        const close = field === "closeCallEvents";
        if (!close && (typeof entry.kind !== "string" || !entry.kind.trim()))
          throw new Error("Missing event label");
        const id = String(entry.id || `${field}-${i}`);
        if (ids.has(id)) throw new Error("Duplicate event ID");
        ids.add(id);
        const event = {
          id,
          type: close ? "close-call" : "other",
          timestamp: entry.timestamp,
          kind: close ? "close-call" : entry.kind,
          label: close
            ? "Close call"
            : !entry.isCustom && entry.kind === "blocked-lane"
              ? "Blocked lane"
              : entry.kind,
          isCustom: !close && entry.isCustom === true,
          category: typeof entry.category === "string" ? entry.category : null,
        };
        (isVideoSync(event.kind) ? syncs : events).push(event);
      } catch {
        warnings.push(`Skipped invalid ${field} entry ${i + 1}.`);
      }
    }
  }
  const byTime = (a, b) => timestamp(a.timestamp) - timestamp(b.timestamp);
  return {
    id: raw.id,
    title: raw.title,
    startedAt: raw.startedAt,
    endedAt: raw.endedAt,
    events: events.sort(byTime),
    syncs: syncs.sort(byTime),
    warnings,
  };
}
export function segmentsFor(sources) {
  let cursor = 0;
  return sources.map((source, index) => {
    const gap = index === 0 ? 0 : Number(source.gapBefore || 0);
    if (
      !Number.isFinite(source.duration) ||
      source.duration <= 0 ||
      !Number.isFinite(gap) ||
      gap < 0
    )
      throw new Error("Invalid video duration or gap.");
    const start = cursor + gap;
    cursor = start + source.duration;
    return { ...source, start, end: cursor };
  });
}
export function resolveClip(event, edit, videoStart, sources) {
  const segments = segmentsFor(sources);
  const offset = timestamp(event.timestamp) - timestamp(videoStart);
  const before = Number(edit?.before ?? 15),
    after = Number(edit?.after ?? 15);
  if (
    ![before, after].every((n) => Number.isFinite(n) && n >= 0) ||
    before + after <= 0
  )
    throw new Error(
      "Clip handles must be non-negative and total more than zero.",
    );
  const requestedStart = offset - before,
    requestedEnd = offset + after;
  const endOfVideo = segments.at(-1)?.end || 0;
  const start = Math.max(0, requestedStart),
    end = Math.min(endOfVideo, requestedEnd);
  const parts = segments.flatMap((s) => {
    const from = Math.max(start, s.start),
      to = Math.min(end, s.end);
    return to - from > 0.0001
      ? [
          {
            sourceId: s.id,
            offset: from - s.start,
            duration: to - from,
            timelineStart: from,
          },
        ]
      : [];
  });
  const duration = parts.reduce((n, p) => n + p.duration, 0);
  const eventCovered = segments.some(
    (s) => offset >= s.start && offset < s.end,
  );
  const hasGap = end > start && duration < end - start - 0.01;
  const available = eventCovered && duration > 0 && !hasGap;
  return {
    eventId: event.id,
    offset,
    start,
    end,
    duration,
    parts,
    available,
    hasGap,
    clamped: requestedStart < 0 || requestedEnd > endOfVideo,
    reason: !eventCovered
      ? "Event is outside the available footage."
      : hasGap
        ? "This clip crosses a gap in the recording. Shorten its handles."
        : "",
  };
}
export function formatTime(seconds) {
  if (!Number.isFinite(seconds)) return "—";
  const sign = seconds < 0 ? "−" : "";
  seconds = Math.abs(seconds);
  const minutes = Math.floor(seconds / 60),
    sec = Math.floor(seconds % 60);
  return `${sign}${minutes.toString().padStart(2, "0")}:${sec.toString().padStart(2, "0")}`;
}
export function validateProject(raw) {
  if (!raw || raw.format !== "bumpyride-clip" || raw.version !== 1)
    throw new Error("Unsupported project file.");
  const ride = parseRide(raw.ride);
  if (raw.videoStart) timestamp(raw.videoStart);
  if (!Array.isArray(raw.sources) || raw.sources.length > 100)
    throw new Error("Invalid project sources.");
  const sources = raw.sources.map((s) => {
    if (
      typeof s.name !== "string" ||
      !Number.isFinite(s.size) ||
      s.size < 0 ||
      !Number.isFinite(s.duration) ||
      s.duration <= 0
    )
      throw new Error("Invalid source metadata.");
    const gapBefore = Number(s.gapBefore || 0);
    if (!Number.isFinite(gapBefore) || gapBefore < 0)
      throw new Error("Invalid source gap.");
    return {
      name: s.name,
      size: s.size,
      duration: s.duration,
      mtimeMs: s.mtimeMs,
      gapBefore,
    };
  });
  const edits = Object.create(null);
  for (const e of ride.events) {
    const saved = raw.edits?.[e.id] || {};
    const before = Number(saved.before ?? 15),
      after = Number(saved.after ?? 15);
    if (
      ![before, after].every((n) => Number.isFinite(n) && n >= 0) ||
      before + after <= 0
    )
      throw new Error("Invalid saved clip boundaries.");
    edits[e.id] = {
      before,
      after,
      selected: saved.selected === true,
      reviewed: saved.reviewed === true,
    };
  }
  return {
    ride,
    sources,
    edits,
    videoStart: raw.videoStart || "",
    syncId: typeof raw.syncId === "string" ? raw.syncId : "",
    offset: Number.isFinite(raw.offset) ? raw.offset : 0,
  };
}
export function rideForProject(ride) {
  return {
    id: ride.id,
    title: ride.title,
    startedAt: ride.startedAt,
    endedAt: ride.endedAt,
    closeCallEvents: ride.events
      .filter((e) => e.type === "close-call")
      .map((e) => ({ id: e.id, timestamp: e.timestamp, category: e.category })),
    otherEvents: [
      ...ride.events.filter((e) => e.type !== "close-call"),
      ...ride.syncs,
    ].map((e) => ({
      id: e.id,
      timestamp: e.timestamp,
      kind: e.kind,
      isCustom: e.isCustom,
    })),
  };
}
