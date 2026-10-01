import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { ffmpeg, ffprobe, run, probe } from "../lib/media.js";
import { startServer, parseRange, listRides } from "../server.js";

test("ride selector uses ride dates and report metadata, isolates unreadable files", async () => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "bumpyride-catalog-"));
  try {
    const ride = { id: "ride", title: "Morning commute", startedAt: "2026-01-01T12:00:00Z", endedAt: "2026-01-01T13:00:00Z",
      closeCallEvents: [{ id: "close", timestamp: "2026-01-01T12:01:00Z" }],
      otherEvents: [{ id: "sync", kind: "Video Sync", timestamp: "2026-01-01T12:00:00Z" }],
      brakeEvents: [{ timestamp: "2026-01-01T12:02:00Z" }], points: [{ latitude: 1 }] };
    await fs.writeFile(path.join(dir, "renamed-ride.json"), JSON.stringify(ride));
    await fs.writeFile(path.join(dir, "newer.json"), JSON.stringify({ ...ride, title: "Later ride", startedAt: "2026-02-01T12:00:00Z", endedAt: "2026-02-01T13:00:00Z", closeCallEvents: [], otherEvents: [] }));
    await fs.utimes(path.join(dir, "newer.json"), new Date(0), new Date(0));
    await fs.writeFile(path.join(dir, "bad.json"), "{}");
    await fs.writeFile(path.join(dir, "ignore.mov"), "");
    await fs.mkdir(path.join(dir, "folder.json"));
    const entries = await listRides(dir);
    assert.equal(entries.length, 3);
    assert.equal(entries[0].title, "Later ride");
    assert.equal(entries[0].reports, 0);
    assert.equal(entries[0].syncs, 0);
    assert.equal(entries[1].duration, 3600);
    assert.equal(entries[1].reports, 1);
    assert.equal(entries[1].syncs, 1);
    assert.ok(entries[2].issue);
    assert.ok(!JSON.stringify(entries).includes("latitude"));
    await assert.rejects(listRides(path.join(dir, "missing")), /Rides folder unavailable/);
  } finally { await fs.rm(dir, { recursive: true, force: true }); }
});

test("byte ranges support seeking, suffixes and invalid-range rejection", () => {
  assert.deepEqual(parseRange("bytes=0-9", 100), { start: 0, end: 9 });
  assert.deepEqual(parseRange("bytes=90-", 100), { start: 90, end: 99 });
  assert.deepEqual(parseRange("bytes=-10", 100), { start: 90, end: 99 });
  assert.throws(() => parseRange("bytes=100-", 100));
  assert.throws(() => parseRange("bytes=0-1,3-4", 100));
  assert.throws(() => parseRange("bytes=-0", 100));
});

test(
  "local workflow exports across files with different audio and dimensions; cleans up without touching originals",
  { timeout: 120_000 },
  async () => {
    const dir = await fs.mkdtemp(
      path.join(os.tmpdir(), "bumpyride-clip-test-"),
    );
    let app;
    try {
      const first = path.join(dir, "first.mp4"),
        second = path.join(dir, "second.mp4");
      await run(ffmpeg, [
        "-v",
        "error",
        "-f",
        "lavfi",
        "-i",
        "color=c=red:s=320x180:r=30:d=3",
        "-f",
        "lavfi",
        "-i",
        "sine=frequency=440:duration=3",
        "-c:v",
        "libx264",
        "-pix_fmt",
        "yuv420p",
        "-c:a",
        "aac",
        "-shortest",
        first,
      ]);
      await run(ffmpeg, [
        "-v",
        "error",
        "-f",
        "lavfi",
        "-i",
        "color=c=blue:s=240x320:r=24:d=3",
        "-c:v",
        "libx264",
        "-pix_fmt",
        "yuv420p",
        second,
      ]);
      const before = [await fs.stat(first), await fs.stat(second)];
      app = await startServer(0);
      const call = async (
        route,
        data,
        method = data === undefined ? "GET" : "POST",
        id = session?.id,
      ) => {
        const res = await fetch(`${app.url}${route}`, {
          method,
          headers: {
            "Content-Type": "application/json",
            ...(id ? { "x-session": id } : {}),
          },
          body: data === undefined ? undefined : JSON.stringify(data),
        });
        return { status: res.status, data: await res.json() };
      };
      let session;
      session = (await call("/api/session", {}, "POST", null)).data;
      const unauth = await call(
        "/api/sources",
        { paths: [first] },
        "POST",
        null,
      );
      assert.equal(unauth.status, 401);
      const forbidden = await fetch(`${app.url}/api/session`, {
        method: "POST",
        headers: {
          Origin: "https://other.example",
          "Content-Type": "application/json",
        },
        body: "{}",
      });
      assert.equal(forbidden.status, 403);
      const registered = await call("/api/sources", { paths: [first, second] });
      assert.equal(registered.status, 200);
      const sources = registered.data;
      assert.equal(sources.length, 2);
      assert.equal(sources[0].audio, true);
      assert.equal(sources[1].audio, false);
      const range = await fetch(
        `${app.url}/media/${sources[0].id}?session=${session.id}`,
        { headers: { Range: "bytes=0-99" } },
      );
      assert.equal(range.status, 206);
      assert.equal((await range.arrayBuffer()).byteLength, 100);
      const payload = {
        videoStart: "2026-09-02T12:00:00Z",
        sources: sources.map((s) => ({ id: s.id })),
        clips: [
          {
            event: { id: "crossing", timestamp: "2026-09-02T12:00:03Z" },
            edit: { before: 1, after: 1 },
          },
        ],
      };
      const requested = await call("/api/jobs", payload);
      assert.equal(requested.status, 202);
      const wait = async (id) => {
        for (let i = 0; i < 150; i++) {
          const r = await call(`/api/jobs/${id}`);
          if (r.data.status !== "running") return r.data;
          await new Promise((resolve) => setTimeout(resolve, 150));
        }
        throw new Error("Render timed out");
      };
      const completed = await wait(requested.data.id);
      assert.equal(completed.status, "ready", completed.error);
      const download = await fetch(
        `${app.url}/api/jobs/${completed.id}/download?session=${session.id}`,
      );
      assert.equal(download.status, 200);
      const output = path.join(dir, "result.mp4");
      await fs.writeFile(output, Buffer.from(await download.arrayBuffer()));
      const outputInfo = await probe(output);
      assert.ok(
        Math.abs(outputInfo.duration - 2) < 0.15,
        `Duration: ${outputInfo.duration}`,
      );
      assert.ok(outputInfo.audio);
      assert.equal(outputInfo.width, 320);
      assert.equal(outputInfo.height, 180);
      // The two halves must actually contain the two different source pictures.
      for (const [time, color] of [
        [0.25, "red"],
        [1.5, "blue"],
      ]) {
        const image = path.join(dir, `${color}.ppm`);
        await run(ffmpeg, [
          "-v",
          "error",
          "-ss",
          String(time),
          "-i",
          output,
          "-vf",
          "scale=1:1",
          "-frames:v",
          "1",
          image,
        ]);
        const rgb = (await fs.readFile(image)).subarray(-3);
        assert.ok(
          color === "red" ? rgb[0] > rgb[2] * 2 : rgb[2] > rgb[0] * 2,
          `${color}: ${rgb}`,
        );
      }
      // Multiple selected clips retain order and each requested duration.
      const reel = await call("/api/jobs", {
        ...payload,
        clips: [
          payload.clips[0],
          {
            event: { id: "later", timestamp: "2026-09-02T12:00:05Z" },
            edit: { before: 0.5, after: 0.5 },
          },
        ],
      });
      const reelJob = await wait(reel.data.id);
      assert.equal(reelJob.status, "ready", reelJob.error);
      const reelFile = path.join(dir, "reel.mp4");
      await fs.writeFile(
        reelFile,
        Buffer.from(
          await (
            await fetch(
              `${app.url}/api/jobs/${reelJob.id}/download?session=${session.id}`,
            )
          ).arrayBuffer(),
        ),
      );
      assert.ok(Math.abs((await probe(reelFile)).duration - 3) < 0.2);
      // Uploads stream into a disposable session; originals are never removed.
      const uploadedResponse = await fetch(
        `${app.url}/api/upload?name=uploaded.mp4&modified=${before[0].mtimeMs}`,
        {
          method: "POST",
          headers: { "x-session": session.id },
          body: await fs.readFile(first),
        },
      );
      assert.equal(uploadedResponse.status, 200);
      const uploaded = await uploadedResponse.json();
      assert.ok(uploaded.uploaded);
      assert.equal(uploaded.sourcePath, null);
      assert.equal(uploaded.mtimeMs, before[0].mtimeMs);
      const aborted = await call("/api/jobs", {
        ...payload,
        clips: [
          {
            event: { id: "long", timestamp: "2026-09-02T12:00:03Z" },
            edit: { before: 3, after: 3 },
          },
        ],
      });
      assert.equal(
        (await call(`/api/jobs/${aborted.data.id}`, undefined, "DELETE"))
          .status,
        200,
      );
      assert.equal((await call(`/api/jobs/${aborted.data.id}`)).status, 404);
      const token = session.id;
      assert.equal(
        (await call("/api/session", undefined, "DELETE")).status,
        200,
      );
      assert.equal(
        (await call("/api/heartbeat", {}, "POST", token)).status,
        401,
      );
      const left = await fs.readdir(path.join(os.tmpdir(), "bumpyride-clip"));
      assert.ok(!left.some((n) => n.includes(token)));
      for (const [i, file] of [first, second].entries()) {
        const after = await fs.stat(file);
        assert.equal(after.size, before[i].size);
        assert.equal(after.mtimeMs, before[i].mtimeMs);
      }
    } finally {
      await app?.close();
      await fs.rm(dir, { recursive: true, force: true });
    }
  },
);
