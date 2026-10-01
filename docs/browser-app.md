# Local Node browser app — Windows, Linux, and macOS

A local browser app for turning BumpyRide reports into ride-video clips. It reads ride JSON from iCloud Documents, links large camera files in place, and uses a **Video Sync report** as the video’s real start time. No ride data or footage is sent to an external service.

## Run

Requires Node.js 22 or newer. On first install, npm downloads platform-specific FFmpeg and FFprobe binaries; subsequent use is offline.

```sh
npm install
npm start
```

Open **http://127.0.0.1:4317**. Keep the terminal running while editing. `Ctrl+C` stops the server and removes its temporary videos. `npm run dev` restarts the server on source changes (reopen the project and relink videos after a restart).

If your npm policy blocks dependency install scripts, allow the install scripts for `ffmpeg-static` and your platform’s `@ffprobe-installer/*` package. You can also point `FFMPEG_PATH` and `FFPROBE_PATH` at existing binaries.

## Workflow

1. **Open a ride JSON**, or use **Choose ride** for a searchable selector with titles, actual ride dates, duration, report counts, and sync markers. Filter by ride date or show only rides with reports. The default Mac folder is `~/Library/Mobile Documents/iCloud~com~herbertindustries~BumpyRide/Documents/Rides/`; set `BUMPYRIDE_RIDES_DIR` to a downloaded rides folder on Windows or Linux (examples in the [README](../README.md)). Unreadable files are listed separately without blocking valid rides. A cloud-only file may need downloading first.
2. **Add videos**. On macOS this opens a native picker and reads originals in place, including files larger than 4 GB. **Manage files** supports absolute local paths on any platform and the repository’s sample videos. Browser upload is an alternative: it streams each file to a temporary local copy (20 GB per file), without buffering the entire file in memory.
3. **Check alignment**. One Video Sync marker is selected automatically; multiple markers require choosing one. If none exists, explicitly enter the first video’s real start time in your computer’s timezone. The camera’s embedded timestamps and filename dates are never used. A positive correction means the video started later than the reference time.
4. **Review reports**. Each begins with 15 seconds before and 5 seconds after the report. Change the numbers, sliders, or ±5-second buttons to trim or extend either handle. Clips can cross camera-file boundaries. Review checkboxes and selection checkboxes are independent.
5. **Export** one clip, or select reports and **Export reel**. Reels follow chronological report order; overlapping report clips retain their separate context. Exports use H.264/AAC MP4, at the first selected source’s dimensions and frame rate. Other pieces are scaled and letterboxed to match; files without audio receive silence. Accurate cuts are re-encoded, so rendering takes time. Use Download or the Mac **Save to a folder** dialog. Existing files are never overwritten.
6. **Save project** to keep a small `.bumpyclip.json` file. It contains report timestamps, sync settings, clip handles, review/selection state, and source fingerprints. It contains no video data, absolute source paths, or ride GPS trace. Reopen it and relink the originals in any selection order; the saved sequence is restored. File name, size, duration, and modification time must match.
7. **Finish session** removes temporary uploads, previews, and rendered exports, and clears the browser’s project autosave. Save/download anything you want to keep first. Original linked files and downloaded exports are never deleted.

Project metadata is also autosaved in this browser. Reloading offers to restore it; original videos still need relinking. Multiple tabs are independent editing sessions but share the latest browser autosave, so use project files to keep separate projects.

## Alignment and coverage

The shared timeline uses seconds relative to frame zero of the first video:

```text
videoStart = chosen Video Sync timestamp + correctionSeconds
eventPosition = reportTimestamp - videoStart
clip = [eventPosition - beforeSeconds, eventPosition + afterSeconds]
nextFileStart = previousFileStart + previousFileDuration + gapBeforeNextFile
```

Files are sequential by default. Check their order in **Manage files**, and enter a gap if recording actually stopped. The app does not infer real-world gaps from camera timestamps. It clamps handles at the first/last footage edge and labels shortened clips. An event outside the recording, or a clip crossing a known gap, cannot be exported until the alignment or handles are corrected.

Native browser playback is used without generating duplicate videos. If a codec/container cannot play in your browser, **Build compatible preview** creates only the selected clip at up to 960 pixels. The exported video still uses the original sources. Playback may briefly pause when switching source files; an exported clip is joined into one MP4. Precision is limited by the source’s frame rate and the precision of the ride’s timestamps.

## BumpyRide data contract

Derived from the sibling `bumpy-ride` repository:

- `BumpyRide/BumpyRide/Models.swift`: `Ride`, `CloseCall`, and `OtherEvent`.
- `BumpyRide/BumpyRide/RideStore.swift`: one `<UUID>.json` file per ride, ISO-8601 date encoding.
- `BumpyRide/BumpyRide/CloudStorage.swift`: iCloud `Documents/Rides/` storage.

`closeCallEvents` contains close calls with `id`, `timestamp`, and optional `category`. `otherEvents` contains `id`, `timestamp`, `kind`, and `isCustom`; the built-in blocked-lane kind is `blocked-lane`, while custom labels are stored verbatim. Optional/missing event arrays are supported. `brakeEvents` and `points` are ignored. Invalid individual reports are skipped with a visible warning.

**Video Sync** is recognized by its `kind`, whether recorded as a custom event or a built-in event. Labels are matched case-insensitively after removing spaces, hyphens, and underscores. Sync markers align footage and are not exported as report clips.

Sample camera footage is optional local test material and is not included in the repository or release. **Use sample videos** only works when you supply files in `sample_video/`. No personal ride JSON is bundled or committed.

## Storage and local service

- The server binds only to `127.0.0.1`, validates host/origin, and requires a random per-session token for file/media operations.
- Large source videos are served with byte ranges for seeking. Linking does not copy them.
- Uploads and generated media live under the OS temporary directory in `bumpyride-clip/<process>-<session>/`.
- Finished render intermediates are removed. Only the most recent compatible preview is retained per session.
- Finish session or normal server shutdown cancels processing and deletes session temp directories.
- After a browser stops sending heartbeats, an idle session expires after about 2 minutes (plus up to 30 seconds for the cleanup sweep). Background-tab throttling can also expire a session; save the project before leaving it unattended. Active exports are allowed to finish before expiry.
- After a crash or forced kill, the next server start removes this app’s directories whose owning process is no longer running. Files under an unrelated process or directory are not touched.
- Processing is serial per browser session. There is no cloud account, external font, analytics, database, or frontend build step.

Configuration:

| Variable              | Default                                |
| --------------------- | -------------------------------------- |
| `PORT`                | `4317`                                 |
| `BUMPYRIDE_RIDES_DIR` | Mac iCloud BumpyRide `Documents/Rides` |
| `FFMPEG_PATH`         | npm-provided FFmpeg                    |
| `FFPROBE_PATH`        | npm-provided FFprobe                   |

## Development and validation

```sh
npm test
```

Node’s built-in test runner covers the ride parser, custom labels, sync math, absent/multiple syncs, segment boundaries and gaps, clip validation, project round trips, byte ranges, local API access checks, and an end-to-end FFmpeg export. The integration test generates tiny videos with different dimensions and audio layouts, verifies frame colors on each side of a split and output duration, builds a reel, streams an upload, cancels a job, and checks cleanup and unchanged originals.

`public/domain.js` contains the shared pure timeline/project logic. `public/app.js` and `public/style.css` implement the UI. `server.js` handles local file access and lifecycle; `lib/media.js` runs FFprobe and FFmpeg without shell interpolation.

The only runtime npm dependencies provide the two media binaries. FFmpeg is independently licensed; see the bundled binary/package notices and [FFmpeg licensing](https://ffmpeg.org/legal.html) before redistributing a packaged application.

### Calibration and batch timing

**Calibrate video sync** lives beside the clip preview in both apps. Use 0.1-second earlier/later nudges, enter a start correction, or pause on the matching frame and choose **Match event to this frame** (web: **Match event to paused frame**). Calibration updates the whole ride and is saved in the project. Positive correction means the camera started later than the sync reference; events move earlier in the recording. Reset correction returns to the original sync reference. The preview keeps the current recording position when it remains inside the adjusted clip; otherwise it clamps to the nearest clip edge.

A clip-relative bar marks the event and the current playback position. A countdown changes to **EVENT RECORDED** at the marker, then shows elapsed time since the event. The cue is for review only and is not burned into exports. On the web, a rendered compatible preview must be rebuilt after calibration changes if the original codec cannot play directly.

Check two or more reports, set before/after values on the current report, and choose **Apply timing to N selected clips**. This applies to all checked reports, including ones hidden by a filter, and preserves selection and review flags. New clips and Reset use **15s before / 5s after**; reopening a project preserves explicit saved timings.
