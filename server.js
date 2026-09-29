import http from "node:http";
import { createReadStream, createWriteStream, constants } from "node:fs";
import fs from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import { randomUUID } from "node:crypto";
import { pipeline } from "node:stream/promises";
import { Transform } from "node:stream";
import { fileURLToPath } from "node:url";
import {
  parseRide,
  segmentsFor,
  resolveClip,
  timestamp,
} from "./public/domain.js";
import { probe, render, run } from "./lib/media.js";

const root = path.dirname(fileURLToPath(import.meta.url));
const cloudDirectory =
  process.env.BUMPYRIDE_RIDES_DIR ||
  path.join(
    os.homedir(),
    "Library/Mobile Documents/iCloud~com~herbertindustries~BumpyRide/Documents/Rides",
  );
const cacheBase = path.join(os.tmpdir(), "bumpyride-clip");
const sessions = new Map();
const videoExtensions = new Set([
  ".mp4",
  ".mov",
  ".m4v",
  ".mkv",
  ".webm",
  ".avi",
]);
const MAX_UPLOAD = 20 * 1024 ** 3;
const json = (res, body, status = 200) => {
  res.writeHead(status, {
    "Content-Type": "application/json",
    "Cache-Control": "no-store",
  });
  res.end(JSON.stringify(body));
};
const fail = (message, status = 400) =>
  Object.assign(new Error(message), { status });
async function body(req) {
  if (!req.headers["content-type"]?.startsWith("application/json"))
    throw fail("Expected JSON.", 415);
  let data = "",
    size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > 20_000_000) throw fail("Request too large.", 413);
    data += chunk;
  }
  try {
    return JSON.parse(data || "{}");
  } catch {
    throw fail("Invalid JSON.");
  }
}
async function localPath(value, extension) {
  if (typeof value !== "string" || !path.isAbsolute(value))
    throw fail("Provide an absolute local file path.");
  const resolved = await fs.realpath(value);
  if (extension && !extension.has(path.extname(resolved).toLowerCase()))
    throw fail("Unsupported file type.");
  return resolved;
}
async function readRide(file) {
  file = await localPath(file, new Set([".json"]));
  const info = await fs.stat(file);
  if (info.size > 100_000_000) throw fail("Ride JSON is larger than 100 MB.");
  return parseRide(JSON.parse(await fs.readFile(file, "utf8")));
}
async function register(session, file, uploaded = false) {
  file = await localPath(file, videoExtensions);
  const existing = [...session.sources.values()].find((s) => s.path === file);
  if (existing) return existing;
  const source = {
    ...(await probe(file)),
    id: randomUUID(),
    path: file,
    uploaded,
  };
  session.sources.set(source.id, source);
  return source;
}
function publicSource({ path: sourcePath, originalMtimeMs, ...source }) {
  return {
    ...source,
    mtimeMs: originalMtimeMs ?? source.mtimeMs,
    sourcePath: source.uploaded ? null : sourcePath,
  };
}
async function cancelJob(job) {
  job.controller.abort();
  await job.promise;
  await fs.rm(job.dir, { recursive: true, force: true });
}
async function closeSession(session) {
  if (session.closing) return;
  session.closing = true;
  sessions.delete(session.id);
  for (const controller of session.uploads) controller.abort();
  await Promise.all([...session.jobs.values()].map(cancelJob));
  await fs.rm(session.dir, { recursive: true, force: true });
}
async function nativePick(kind) {
  if (process.platform !== "darwin")
    throw fail("Use the local path field or browser upload on this platform.");
  const script =
    kind === "video"
      ? `set picked to choose file with prompt "Choose your ride videos (originals stay in place)" with multiple selections allowed
set output to ""
repeat with itemPath in picked
set output to output & POSIX path of itemPath & linefeed
end repeat
return output`
      : `return POSIX path of (choose file with prompt "Choose a BumpyRide ride JSON" of type {"public.json"})`;
  try {
    return (await run("/usr/bin/osascript", ["-e", script]))
      .trim()
      .split("\n")
      .filter(Boolean);
  } catch (error) {
    if (error.message.includes("(-128)")) return [];
    throw error;
  }
}
export function parseRange(header, size) {
  if (!header) return null;
  const match = /^bytes=(\d*)-(\d*)$/.exec(header);
  if (!match || (!match[1] && !match[2]))
    throw fail("Invalid byte range.", 416);
  let start, end;
  if (!match[1]) {
    const suffix = Number(match[2]);
    if (suffix <= 0) throw fail("Invalid byte range.", 416);
    start = Math.max(0, size - suffix);
    end = size - 1;
  } else {
    start = Number(match[1]);
    end = match[2] ? Math.min(Number(match[2]), size - 1) : size - 1;
  }
  if (
    !Number.isSafeInteger(start) ||
    !Number.isSafeInteger(end) ||
    start >= size ||
    end < start
  )
    throw fail("Invalid byte range.", 416);
  return { start, end };
}
async function streamFile(req, res, file, type, download) {
  const info = await fs.stat(file);
  let range;
  try {
    range = parseRange(req.headers.range, info.size);
  } catch (error) {
    res.setHeader("Content-Range", `bytes */${info.size}`);
    throw error;
  }
  const headers = {
    "Content-Type": type,
    "Accept-Ranges": "bytes",
    "Content-Length": range ? range.end - range.start + 1 : info.size,
    "Cache-Control": "no-store",
  };
  if (download)
    headers["Content-Disposition"] =
      `attachment; filename="${download.replace(/[^\w.-]/g, "_")}"`;
  if (range)
    headers["Content-Range"] = `bytes ${range.start}-${range.end}/${info.size}`;
  res.writeHead(range ? 206 : 200, headers);
  if (req.method === "HEAD") return res.end();
  const stream = createReadStream(file, range || {});
  res.on("close", () => stream.destroy());
  stream.on("error", () => res.destroy());
  stream.pipe(res);
}
async function route(req, res) {
  const host = req.headers.host;
  if (!/^(127\.0\.0\.1|localhost):\d+$/.test(host || ""))
    throw fail("Local connections only.", 403);
  const origin = `http://${host}`;
  if (req.headers.origin && req.headers.origin !== origin)
    throw fail("Cross-origin request refused.", 403);
  if (
    req.headers["sec-fetch-site"] &&
    !["same-origin", "none"].includes(req.headers["sec-fetch-site"])
  )
    throw fail("Cross-site request refused.", 403);
  res.setHeader("X-Content-Type-Options", "nosniff");
  res.setHeader("Referrer-Policy", "no-referrer");
  const url = new URL(req.url, origin),
    pathname = url.pathname;
  if (pathname === "/api/session" && req.method === "POST") {
    await body(req);
    const id = randomUUID(),
      dir = path.join(cacheBase, `${process.pid}-${id}`);
    await fs.mkdir(dir, { recursive: true, mode: 0o700 });
    const session = {
      id,
      dir,
      sources: new Map(),
      jobs: new Map(),
      uploads: new Set(),
      lastSeen: Date.now(),
    };
    sessions.set(id, session);
    return json(res, {
      id,
      platform: process.platform,
      cloudDirectory,
      sampleDirectory: path.join(root, "sample_video"),
    });
  }
  if (pathname.startsWith("/api/") || pathname.startsWith("/media/")) {
    const session = sessions.get(
      req.headers["x-session"] || url.searchParams.get("session"),
    );
    if (!session || session.closing)
      throw fail(
        "Session expired. Reload the page and reopen your project.",
        401,
      );
    session.lastSeen = Date.now();
    if (pathname === "/api/heartbeat" && req.method === "POST")
      return json(res, { ok: true });
    if (pathname === "/api/session" && req.method === "DELETE") {
      await closeSession(session);
      return json(res, { ok: true });
    }
    if (pathname === "/api/pick" && req.method === "POST")
      return json(res, { paths: await nativePick((await body(req)).kind) });
    if (pathname === "/api/ride" && req.method === "POST")
      return json(res, await readRide((await body(req)).path));
    if (pathname === "/api/rides" && req.method === "GET") {
      let names;
      try {
        names = await fs.readdir(cloudDirectory);
      } catch {
        throw fail(
          "iCloud rides folder not found. Open a ride JSON from Finder instead.",
          404,
        );
      }
      const rides = await Promise.all(
        names
          .filter((n) => /^[\da-f-]{36}\.json$/i.test(n))
          .map(async (name) => {
            const file = path.join(cloudDirectory, name),
              info = await fs.stat(file);
            return {
              name,
              path: file,
              modifiedAt: info.mtime.toISOString(),
              size: info.size,
            };
          }),
      );
      return json(
        res,
        rides.sort((a, b) => b.modifiedAt.localeCompare(a.modifiedAt)),
      );
    }
    if (pathname === "/api/sources" && req.method === "POST") {
      const { paths } = await body(req);
      if (!Array.isArray(paths) || !paths.length || paths.length > 100)
        throw fail("Choose between 1 and 100 videos.");
      const oldIds = new Set(session.sources.keys());
      try {
        const added = [];
        for (const file of paths)
          added.push(publicSource(await register(session, file)));
        return json(res, added);
      } catch (error) {
        for (const id of session.sources.keys())
          if (!oldIds.has(id)) session.sources.delete(id);
        throw error;
      }
    }
    if (pathname === "/api/samples" && req.method === "POST") {
      const dir = path.join(root, "sample_video");
      const names = (await fs.readdir(dir))
        .filter((n) => videoExtensions.has(path.extname(n).toLowerCase()))
        .sort();
      const sources = [];
      for (const name of names)
        sources.push(
          publicSource(await register(session, path.join(dir, name))),
        );
      return json(res, sources);
    }
    if (pathname === "/api/upload" && req.method === "POST") {
      const name = path.basename(url.searchParams.get("name") || "video.mp4");
      if (!videoExtensions.has(path.extname(name).toLowerCase()))
        throw fail("Unsupported video file.");
      if (Number(req.headers["content-length"]) > MAX_UPLOAD)
        throw fail("Maximum upload size is 20 GB per file.", 413);
      const dir = path.join(session.dir, randomUUID());
      await fs.mkdir(dir);
      const file = path.join(dir, name),
        controller = new AbortController();
      session.uploads.add(controller);
      let size = 0;
      try {
        const limiter = new Transform({
          transform(chunk, encoding, callback) {
            size += chunk.length;
            session.lastSeen = Date.now();
            callback(
              size > MAX_UPLOAD
                ? fail("Maximum upload size is 20 GB.", 413)
                : null,
              chunk,
            );
          },
        });
        await pipeline(req, limiter, createWriteStream(file, { flags: "wx" }), {
          signal: controller.signal,
        });
        const source = await register(session, file, true);
        const originalMtimeMs = Number(url.searchParams.get("modified"));
        if (Number.isFinite(originalMtimeMs) && originalMtimeMs > 0) {
          source.originalMtimeMs = originalMtimeMs;
        }
        return json(res, publicSource(source));
      } catch (error) {
        await fs.rm(dir, { recursive: true, force: true });
        throw error;
      } finally {
        session.uploads.delete(controller);
      }
    }
    const mediaMatch = /^\/media\/([\w-]+)$/.exec(pathname);
    if (mediaMatch && ["GET", "HEAD"].includes(req.method)) {
      const source = session.sources.get(mediaMatch[1]);
      if (!source) throw fail("Video is no longer attached.", 404);
      const ext = path.extname(source.path).toLowerCase();
      return streamFile(
        req,
        res,
        source.path,
        ext === ".webm"
          ? "video/webm"
          : ext === ".mov"
            ? "video/quicktime"
            : "video/mp4",
      );
    }
    if (pathname === "/api/jobs" && req.method === "POST") {
      const input = await body(req);
      if ([...session.jobs.values()].some((j) => j.status === "running"))
        throw fail("Wait for the current render or cancel it first.", 409);
      if (
        !Array.isArray(input.sources) ||
        !input.sources.length ||
        input.sources.length > 100
      )
        throw fail("Attach videos first.");
      timestamp(input.videoStart);
      const sourceIds = new Set();
      const sources = input.sources.map((s) => {
        const source = session.sources.get(s.id);
        if (!source || sourceIds.has(s.id))
          throw fail("Video missing or repeated. Reattach your source files.");
        sourceIds.add(s.id);
        return { ...source, gapBefore: s.gapBefore };
      });
      segmentsFor(sources);
      if (
        !Array.isArray(input.clips) ||
        !input.clips.length ||
        input.clips.length > 500
      )
        throw fail("Select between 1 and 500 clips.");
      const clips = input.clips.map((c) =>
        resolveClip(c.event, c.edit, input.videoStart, sources),
      );
      const unavailable = clips.find((c) => !c.available);
      if (unavailable) throw fail(unavailable.reason);
      if (input.preview)
        for (const [id, old] of session.jobs)
          if (old.preview && old.status !== "running") {
            await cancelJob(old);
            session.jobs.delete(id);
          }
      const id = randomUUID(),
        dir = path.join(session.dir, id);
      await fs.mkdir(dir);
      const job = {
        id,
        dir,
        status: "running",
        progress: 0,
        preview: input.preview === true,
        controller: new AbortController(),
        createdAt: Date.now(),
        filename:
          input.clips.length === 1
            ? "bumpyride-clip.mp4"
            : "bumpyride-reel.mp4",
      };
      session.jobs.set(id, job);
      job.promise = render(
        clips.flatMap((c) => c.parts),
        session.sources,
        dir,
        {
          preview: job.preview,
          signal: job.controller.signal,
          onProgress: (p) => {
            job.progress = p;
          },
        },
      )
        .then((file) => {
          job.file = file;
          job.status = "ready";
        })
        .catch(async (error) => {
          job.status = job.controller.signal.aborted ? "cancelled" : "error";
          job.error =
            job.status === "cancelled" ? "Render cancelled." : error.message;
          await fs.rm(dir, { recursive: true, force: true });
        });
      return json(res, { id }, 202);
    }
    const jobMatch = /^\/api\/jobs\/([\w-]+)(?:\/(download|video|save))?$/.exec(
      pathname,
    );
    if (jobMatch) {
      const job = session.jobs.get(jobMatch[1]);
      if (!job) throw fail("Export expired. Render it again.", 404);
      if (req.method === "DELETE") {
        await cancelJob(job);
        session.jobs.delete(job.id);
        return json(res, { ok: true });
      }
      if (jobMatch[2]) {
        if (job.status !== "ready") throw fail("Video is not ready yet.", 409);
        if (jobMatch[2] === "save" && req.method === "POST") {
          await body(req);
          if (process.platform !== "darwin")
            throw fail(
              "Use Download to choose the destination in your browser.",
            );
          let destination;
          try {
            destination = (
              await run("/usr/bin/osascript", [
                "-e",
                `return POSIX path of (choose file name with prompt "Save exported video" default name "${job.filename}")`,
              ])
            ).trim();
          } catch (error) {
            if (error.message.includes("(-128)"))
              return json(res, { cancelled: true });
            throw error;
          }
          await fs.copyFile(job.file, destination, constants.COPYFILE_EXCL);
          return json(res, { path: destination });
        }
        if (["GET", "HEAD"].includes(req.method))
          return streamFile(
            req,
            res,
            job.file,
            "video/mp4",
            jobMatch[2] === "download" ? job.filename : null,
          );
      }
      if (req.method === "GET")
        return json(res, {
          id: job.id,
          status: job.status,
          progress: job.progress,
          error: job.error,
          filename: job.filename,
        });
    }
    throw fail("Not found.", 404);
  }
  if (!["GET", "HEAD"].includes(req.method)) throw fail("Not found.", 404);
  const files = {
    "/": ["index.html", "text/html"],
    "/app.js": ["app.js", "text/javascript"],
    "/domain.js": ["domain.js", "text/javascript"],
    "/style.css": ["style.css", "text/css"],
  };
  const item = files[pathname];
  if (!item) throw fail("Not found.", 404);
  res.setHeader(
    "Content-Security-Policy",
    "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' blob: data:; media-src 'self' blob:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'",
  );
  return streamFile(req, res, path.join(root, "public", item[0]), item[1]);
}
export async function startServer(port = Number(process.env.PORT || 4317)) {
  await fs.mkdir(cacheBase, { recursive: true, mode: 0o700 });
  // Only remove directories owned by this app whose process is no longer alive.
  for (const name of await fs.readdir(cacheBase)) {
    const match = /^(\d+)-[\da-f-]{36}$/.exec(name);
    if (!match) continue;
    try {
      process.kill(Number(match[1]), 0);
    } catch (error) {
      if (error.code === "ESRCH")
        await fs.rm(path.join(cacheBase, name), {
          recursive: true,
          force: true,
        });
    }
  }
  const server = http.createServer((req, res) =>
    route(req, res).catch((error) => {
      if (res.headersSent) return res.destroy();
      const message =
        error.code === "ENOENT"
          ? "File not found. Check that it is downloaded from iCloud and still in its original location."
          : error.code === "EEXIST"
            ? "That file already exists. Choose a new filename."
            : error.message;
      json(res, { error: message }, error.status || 400);
    }),
  );
  server.requestTimeout = 0; // Large local uploads may take longer than five minutes.
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, "127.0.0.1", resolve);
  });
  const sweep = setInterval(() => {
    for (const session of sessions.values())
      if (
        Date.now() - session.lastSeen > 120_000 &&
        ![...session.jobs.values()].some((j) => j.status === "running")
      )
        void closeSession(session);
  }, 30_000).unref();
  const close = async () => {
    clearInterval(sweep);
    await Promise.all([...sessions.values()].map(closeSession));
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
  };
  return { server, close, url: `http://127.0.0.1:${server.address().port}` };
}
if (
  process.argv[1] &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  const app = await startServer();
  console.log(
    `BumpyRide Clip is ready at ${app.url}\nAll processing stays on this computer. Ctrl+C cleans up temporary videos.`,
  );
  let stopping = false;
  for (const signal of ["SIGINT", "SIGTERM"])
    process.on(signal, async () => {
      if (stopping) return;
      stopping = true;
      await app.close();
      process.exit(0);
    });
}
