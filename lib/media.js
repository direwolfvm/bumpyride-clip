import { spawn } from "node:child_process";
import { stat, writeFile, rm } from "node:fs/promises";
import path from "node:path";
import ffmpegStatic from "ffmpeg-static";
import ffprobeInstaller from "@ffprobe-installer/ffprobe";

export const ffmpeg = process.env.FFMPEG_PATH || ffmpegStatic;
export const ffprobe = process.env.FFPROBE_PATH || ffprobeInstaller.path;
export function run(binary, args, { signal, onProgress, timeout = 0 } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(binary, args, {
      stdio: ["ignore", "pipe", "pipe"],
      signal,
      timeout,
    });
    let stdout = "",
      stderr = "",
      progress = "";
    child.stdout.on("data", (chunk) => {
      if (!onProgress) stdout = (stdout + chunk).slice(-2_000_000);
      else {
        progress += chunk;
        const lines = progress.split("\n");
        progress = lines.pop();
        for (const line of lines)
          if (line.startsWith("out_time_us="))
            onProgress(Number(line.split("=")[1]) / 1e6);
      }
    });
    child.stderr.on("data", (chunk) => {
      stderr = (stderr + chunk).slice(-4000);
    });
    let processError;
    child.on("error", (error) => {
      processError = error;
    });
    child.on("close", (code) =>
      code === 0 && !processError
        ? resolve(stdout)
        : reject(
            processError ||
              new Error(stderr || `Video processor exited with code ${code}.`),
          ),
    );
  });
}
export async function probe(file) {
  const info = await stat(file);
  if (!info.isFile()) throw new Error("Select a video file.");
  const data = JSON.parse(
    await run(
      ffprobe,
      [
        "-v",
        "error",
        "-protocol_whitelist",
        "file,pipe",
        "-show_format",
        "-show_streams",
        "-of",
        "json",
        file,
      ],
      { timeout: 60_000 },
    ),
  );
  const video = data.streams?.find((s) => s.codec_type === "video");
  const duration = Number(video?.duration || data.format?.duration);
  if (!video || !Number.isFinite(duration) || duration <= 0)
    throw new Error("This file does not contain a playable video.");
  const [rateNumerator, rateDenominator] = String(
    video.avg_frame_rate || "30/1",
  )
    .split("/")
    .map(Number);
  const frameRate = rateNumerator / rateDenominator;
  const rotation = Math.abs(
    Number(
      video.side_data_list?.find((s) => s.rotation != null)?.rotation ||
        video.tags?.rotate ||
        0,
    ),
  );
  return {
    name: path.basename(file),
    size: info.size,
    mtimeMs: info.mtimeMs,
    duration,
    width: rotation % 180 === 90 ? video.height : video.width,
    height: rotation % 180 === 90 ? video.width : video.height,
    codec: video.codec_name,
    fps: Number.isFinite(frameRate) && frameRate > 0 ? frameRate : 30,
    audio: data.streams.some((s) => s.codec_type === "audio"),
  };
}
// Normalize pieces for exact cuts and consistent concatenation, including silent sources.
export async function render(
  parts,
  sources,
  dir,
  { preview = false, signal, onProgress = () => {} } = {},
) {
  if (!parts.length) throw new Error("There is no footage in this selection.");
  const first = sources.get(parts[0].sourceId);
  const limit = preview ? 960 : Math.max(first.width, first.height);
  const fps = preview ? Math.min(30, first.fps || 30) : first.fps || 30;
  const scale = Math.min(1, limit / Math.max(first.width, first.height));
  const width = Math.max(2, Math.floor((first.width * scale) / 2) * 2);
  const height = Math.max(2, Math.floor((first.height * scale) / 2) * 2);
  const total = parts.reduce((n, p) => n + p.duration, 0);
  let done = 0;
  const files = [];
  for (const [i, part] of parts.entries()) {
    signal?.throwIfAborted();
    const source = sources.get(part.sourceId);
    const current = await stat(source.path);
    if (current.size !== source.size || current.mtimeMs !== source.mtimeMs)
      throw new Error(
        `${source.name} changed. Please reattach the source video.`,
      );
    const file = path.join(dir, `part-${i}.mp4`);
    const args = [
      "-hide_banner",
      "-loglevel",
      "error",
      "-nostdin",
      "-y",
      "-protocol_whitelist",
      "file,pipe",
      "-ss",
      String(part.offset),
      "-i",
      source.path,
    ];
    if (!source.audio)
      args.push("-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo");
    args.push(
      "-t",
      String(part.duration),
      "-map",
      "0:v:0",
      "-map",
      source.audio ? "0:a:0" : "1:a:0",
      "-vf",
      `scale=${width}:${height}:force_original_aspect_ratio=decrease,pad=${width}:${height}:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=${fps}`,
      "-af",
      "aresample=48000:async=1:first_pts=0,apad",
      "-c:v",
      "libx264",
      "-preset",
      preview ? "ultrafast" : "fast",
      "-crf",
      preview ? "25" : "20",
      "-pix_fmt",
      "yuv420p",
      "-c:a",
      "aac",
      "-b:a",
      "160k",
      "-ar",
      "48000",
      "-ac",
      "2",
      "-map_metadata",
      "-1",
      "-movflags",
      "+faststart",
      "-progress",
      "pipe:1",
      file,
    );
    await run(ffmpeg, args, {
      signal,
      onProgress: (time) =>
        onProgress(
          Math.min(
            0.97,
            ((done + Math.min(time, part.duration)) / total) * 0.97,
          ),
        ),
    });
    files.push(file);
    done += part.duration;
  }
  const output = path.join(dir, "output.mp4");
  if (files.length === 1) {
    const { rename } = await import("node:fs/promises");
    await rename(files[0], output);
  } else {
    const list = path.join(dir, "concat.txt");
    await writeFile(
      list,
      files.map((_, i) => `file 'part-${i}.mp4'`).join("\n"),
    );
    await run(
      ffmpeg,
      [
        "-hide_banner",
        "-loglevel",
        "error",
        "-nostdin",
        "-y",
        "-f",
        "concat",
        "-safe",
        "1",
        "-i",
        list,
        "-c",
        "copy",
        "-map_metadata",
        "-1",
        "-movflags",
        "+faststart",
        output,
      ],
      { signal },
    );
    await Promise.all(files.map((f) => rm(f, { force: true })));
    await rm(list);
  }
  onProgress(1);
  return output;
}
