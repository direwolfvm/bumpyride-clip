import test from "node:test";
import assert from "node:assert/strict";
import {
  parseRide,
  isVideoSync,
  resolveClip,
  segmentsFor,
  validateProject,
  rideForProject,
  timestamp,
  calibratedStart,
  applySelectedTiming,
  eventCue,
} from "../public/domain.js";
const at = (seconds) =>
  new Date(Date.UTC(2026, 8, 2, 12, 0, seconds)).toISOString();
const base = {
  id: "ride-1",
  title: "Test ride",
  startedAt: at(0),
  endedAt: at(180),
};
const event = { id: "event-1", timestamp: at(60) };
const sources = [
  { id: "a", duration: 65 },
  { id: "b", duration: 60 },
];

test("uses the BumpyRide schema and separates Video Sync from reports and brakes", () => {
  const ride = parseRide({
    ...base,
    closeCallEvents: [{ ...event, category: "vehicle" }],
    brakeEvents: [{ id: "brake", timestamp: at(5) }],
    otherEvents: [
      { id: "sync", timestamp: at(0), kind: "Video Sync", isCustom: true },
      {
        id: "blocked",
        timestamp: at(25),
        kind: "blocked-lane",
        isCustom: false,
      },
      { id: "scooter", timestamp: at(50), kind: "Scooter", isCustom: true },
    ],
  });
  assert.deepEqual(
    ride.events.map((e) => e.label),
    ["Blocked lane", "Scooter", "Close call"],
  );
  assert.equal(ride.events[2].category, "vehicle");
  assert.equal(ride.syncs.length, 1);
});
test("accepts legacy missing or null event arrays", () => {
  assert.deepEqual(parseRide({ ...base, otherEvents: null }).events, []);
});
test("recognizes only normalized Video Sync labels", () => {
  for (const name of ["Video Sync", " video-sync ", "VIDEO_SYNC", "VideoSync"])
    assert.ok(isVideoSync(name));
  assert.ok(!isVideoSync("Video sync test"));
  assert.ok(!isVideoSync("Sync"));
});
test("legacy custom and built-in sync kinds stay out of review clips after project round-trip", () => {
  for (const isCustom of [true, false]) {
    for (const kind of ["Video Sync", "video-sync", "VIDEO_SYNC", "VideoSync"]) {
      const ride = parseRide({ ...base, otherEvents: [{ id: "sync", timestamp: at(0), kind, isCustom }] });
      assert.equal(ride.events.length, 0);
      assert.equal(ride.syncs[0].id, "sync");
      const reopened = parseRide(rideForProject(ride));
      assert.equal(reopened.syncs[0].id, "sync");
      assert.equal(reopened.events.length, 0);
    }
  }
});
test("keeps multiple sync markers for explicit selection and skips malformed reports", () => {
  const ride = parseRide({
    ...base,
    otherEvents: [
      { id: "a", kind: "video sync", timestamp: at(1) },
      { id: "b", kind: "Video Sync", timestamp: at(2) },
      { id: "bad", kind: "Scooter", timestamp: "not a date" },
    ],
  });
  assert.equal(ride.syncs.length, 2);
  assert.equal(ride.warnings.length, 1);
});
test("resolves explicit handles across a camera split", () => {
  const clip = resolveClip(event, { before: 15, after: 15 }, at(0), sources);
  assert.equal(clip.start, 45);
  assert.equal(clip.end, 75);
  assert.equal(clip.duration, 30);
  assert.ok(clip.available);
  assert.deepEqual(
    clip.parts.map((p) => [p.sourceId, p.offset, p.duration]),
    [
      ["a", 45, 20],
      ["b", 0, 10],
    ],
  );
});
test("positive sync correction moves an event earlier in the video", () => {
  assert.equal(resolveClip(event, {}, at(3), sources).offset, 57);
});
test("clamps clip handles at footage edges, but does not invent coverage", () => {
  const first = resolveClip({ ...event, timestamp: at(5) }, {}, at(0), sources);
  assert.equal(first.duration, 10);
  assert.ok(first.clamped);
  assert.ok(first.available);
  const last = resolveClip(
    { ...event, timestamp: at(120) },
    {},
    at(0),
    sources,
  );
  assert.equal(last.duration, 20);
  assert.ok(
    !resolveClip({ ...event, timestamp: at(130) }, {}, at(0), sources)
      .available,
  );
});
test("rejects clips that cross missing footage and allows safe trims", () => {
  const gapped = [sources[0], { ...sources[1], gapBefore: 10 }];
  assert.equal(segmentsFor(gapped)[1].start, 75);
  assert.ok(resolveClip(event, { after: 15 }, at(0), gapped).hasGap);
  assert.ok(!resolveClip(event, { after: 15 }, at(0), gapped).available);
  assert.ok(
    resolveClip(event, { before: 15, after: 5 }, at(0), gapped).available,
  );
  assert.ok(
    !resolveClip(
      { ...event, timestamp: at(70) },
      { before: 1, after: 1 },
      at(0),
      gapped,
    ).available,
  );
});
test("rejects invalid numbers and unzoned timestamps", () => {
  assert.throws(() => timestamp("2026-09-02T12:00:00"));
  assert.throws(() => resolveClip(event, { before: NaN }, at(0), sources));
  assert.throws(() =>
    resolveClip(event, { before: 0, after: 0 }, at(0), sources),
  );
  assert.throws(() => segmentsFor([{ id: "bad", duration: Infinity }]));
  assert.throws(() =>
    segmentsFor([sources[0], { ...sources[1], gapBefore: -2 }]),
  );
});
test("metadata-only projects round trip without GPS traces or media data", () => {
  const ride = parseRide({
    ...base,
    points: [{ latitude: 1 }],
    closeCallEvents: [event],
    otherEvents: [
      { id: "sync", kind: "Video Sync", timestamp: at(0), isCustom: true },
    ],
  });
  const saved = {
    format: "bumpyride-clip",
    version: 1,
    ride: rideForProject(ride),
    sources: [{ name: "one.mov", size: 999, duration: 100, gapBefore: 0 }],
    videoStart: at(0),
    edits: {
      "event-1": { before: 12, after: 22, selected: true, reviewed: true },
    },
  };
  const restored = validateProject(saved);
  assert.deepEqual(restored.ride, ride);
  assert.equal(restored.edits["event-1"].after, 22);
  assert.ok(restored.edits["event-1"].reviewed);
  assert.ok(!("points" in saved.ride));
  assert.ok(!JSON.stringify(saved).includes("latitude"));
});
test("validates projects before replacing live state", () => {
  assert.throws(() =>
    validateProject({ format: "bumpyride-clip", version: 2 }),
  );
  const p = {
    format: "bumpyride-clip",
    version: 1,
    ride: { ...base, closeCallEvents: [event] },
    sources: [],
    edits: { "event-1": { before: -1, after: 3 } },
  };
  assert.throws(() => validateProject(p));
});
test("custom labels that resemble built-ins remain custom when projects are saved", () => {
  const ride = parseRide({
    ...base,
    otherEvents: [
      {
        id: "custom-close",
        kind: "close-call",
        isCustom: true,
        timestamp: at(20),
      },
    ],
  });
  const saved = rideForProject(ride);
  assert.equal(saved.closeCallEvents.length, 0);
  assert.equal(saved.otherEvents[0].kind, "close-call");
  assert.ok(parseRide(saved).events[0].isCustom);
});

test("new and partially saved clips default to 15 seconds before and 5 after", () => {
  const clip = resolveClip(event, {}, at(0), sources);
  assert.equal(clip.start, 45); assert.equal(clip.end, 65); assert.equal(clip.duration, 20);
  const project = validateProject({format: "bumpyride-clip", version: 1, ride: {...base, closeCallEvents:[event]}, sources:[], edits:{}});
  assert.deepEqual(project.edits[event.id], {before:15, after:5, selected:false, reviewed:false});
});
test("calibration changes every report consistently and preserves the sync reference", () => {
  const corrected = calibratedStart(at(0), 0, 0.3);
  assert.ok(Math.abs(timestamp(corrected) - timestamp(at(0)) - 0.3) < 0.001);
  assert.ok(Math.abs(resolveClip(event, {}, corrected, sources).offset - 59.7) < 0.001);
  const frame = 58.5, previous = resolveClip(event, {}, corrected, sources).offset;
  const matched = calibratedStart(corrected, 0.3, 0.3 + previous - frame);
  assert.ok(Math.abs(resolveClip(event, {}, matched, sources).offset - frame) < 0.001);
  assert.equal(calibratedStart(corrected, 0.3, 0), at(0));
  assert.throws(() => calibratedStart(at(0), 0, Infinity));
});
test("bulk timing changes only selected reports and preserves flags", () => {
  const events = [{id:"a"},{id:"b"},{id:"c"}], edits = {
    a:{before:1,after:2,selected:true,reviewed:true}, b:{before:8,after:9,selected:true,reviewed:false}, c:{before:3,after:4,selected:false,reviewed:true}};
  const result = applySelectedTiming(events, edits, 15, 5);
  assert.deepEqual(result.a, {before:15,after:5,selected:true,reviewed:true});
  assert.deepEqual(result.b, {before:15,after:5,selected:true,reviewed:false});
  assert.deepEqual(result.c, edits.c); assert.equal(edits.a.before, 1);
  assert.throws(() => applySelectedTiming(events, edits, 0, 0));
});
test("preview event cue uses actual clamped clip start and camera timeline", () => {
  const clip = resolveClip({...event,timestamp:at(5)}, {}, at(0), sources);
  const cue = eventCue(clip, 5);
  assert.equal(cue.eventTime, 5); assert.equal(cue.eventFraction, 0.5); assert.ok(cue.atEvent);
  assert.equal(eventCue(clip, 4).delta, -1); assert.equal(eventCue(clip, 7).delta, 2);
  const split = resolveClip(event, {after:15}, at(0), sources);
  assert.equal(eventCue(split, 66).playheadFraction, 0.7);
});
