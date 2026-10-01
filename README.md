# BumpyRide Clip

A companion to BumpyRide for documenting what you track along the way. Choose a ride, link your camera files, and turn close calls, blocked lanes, and custom reports into clips. All processing stays on your computer.

## Get the app

| Platform | How to run |
| --- | --- |
| **macOS 26.2+** (Apple silicon or Intel) | Download the signed, notarized DMG from [GitHub Releases](https://github.com/direwolfvm/bumpyride-clip/releases/latest), open it, and drag BumpyRide Clip into Applications. |
| **Windows and Linux** | Run the **local Node browser app** from this repository using the steps below. No native Windows or Linux installer is provided. |
| Other supported macOS versions | Use the Node browser app, or build the native app on macOS 26.2+. |

### Windows and Linux: local Node app

Install **Node.js 22 or newer**, download and extract this repository's source ZIP (or clone it), and open a terminal in the repository folder:

```sh
npm install
npm start
```

Open **http://127.0.0.1:4317** in your browser. Keep the terminal running while editing; use **Ctrl+C** to stop it. The first install downloads FFmpeg and FFprobe for your platform. Later editing and exports run locally, without an account or server outside your computer. If your platform lacks a bundled binary, set `FFMPEG_PATH` and `FFPROBE_PATH` to installed executables.

Use **Open ride JSON** for a downloaded BumpyRide ride. To browse a whole folder with **Choose ride**, set its absolute path before `npm start`:

```powershell
# Windows PowerShell
$env:BUMPYRIDE_RIDES_DIR = 'C:\Users\you\Documents\BumpyRide\Rides'
npm start
```

```sh
# Linux (or macOS)
BUMPYRIDE_RIDES_DIR="$HOME/Documents/BumpyRide/Rides" npm start
```

On Windows and Linux, use **Manage files → Link paths** to read the original videos in place. Browser upload also works, but creates temporary local copies. The Mac-only native file picker and default iCloud folder are optional conveniences. See [the browser app guide](docs/browser-app.md) for setup, exports, storage, and troubleshooting.


## Run the macOS app

Open `BumpyRide Clip/BumpyRide Clip.xcodeproj` in **Xcode 26.2 or later**, select the **BumpyRide Clip** scheme and **My Mac**, then Run. The shell targets **macOS 26.2+**. Use your development signing team if Xcode requests one.

The native app uses SwiftUI and AVFoundation. It has no package dependencies and needs no Node server, FFmpeg installation, or network connection. It follows macOS light/dark appearance with BumpyRide’s green accents and a navy/mint clip icon.

For a local ad-hoc signed build:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project 'BumpyRide Clip/BumpyRide Clip.xcodeproj' \
  -scheme 'BumpyRide Clip' -configuration Release \
  -derivedDataPath output/native \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO build
```

The result is `output/native/Build/Products/Release/BumpyRide Clip.app`. This is a local build, not a notarized distribution.

## Build a DMG

Run `scripts/build-dmg.sh --local` for an isolated, universal local-test package.
For a Developer ID signed and notarized release, see [distribution instructions](docs/distribution.md).
The script excludes sample footage, checks bundle contents, and preserves running development builds.

## Review a ride

1. **Choose Ride** (⌘O). Choose your BumpyRide Rides folder once to grant access; it is remembered on this Mac. The selector lists titles, actual ride dates, durations, report counts, and Video Sync counts, newest first. Search by title or filename, or show only rides with reports. **Open a File…** remains available for individual ride JSON or saved projects. Download cloud-only files in Finder and Refresh if needed. Hard brakes and GPS points are discarded.
2. **Link Videos**. Select the original MOV/MP4 files. **Manage Videos** sets recording order and any actual gaps between files. Split camera files normally have zero gap. Camera filenames and embedded dates never determine alignment.
3. **Video Sync** sets the first frame’s real-world time. A single Video Sync report is selected automatically; choose a marker if there are several, or enter a manual time if none exists. A positive adjustment moves the recording start later.
4. Select a report to preview its clip. Default handles are **15 seconds before and 5 seconds after**. Edit either handle with numbers, sliders, or steppers. **Jump to Report** seeks to the marked moment. Previews cross file boundaries without creating video copies.
5. **Export Clip** (⌘E) saves an MP4 at your chosen location. Select several reports and **Export Selected Clips** to combine them chronologically. Overlapping clips retain their separate context. The first clip determines output dimensions and frame rate; other segments are scaled and letterboxed. Audio is retained where present. Existing exports are not overwritten.
6. **Save Project** (⌘S) saves a small `.bumpyclip` JSON file with edits, sync, selection/review state, source fingerprints, and sandbox file bookmarks. Finder double-click, Open With, Dock drops, and **File → Open Recent** open these projects. Older `.bumpyclip.json` projects and ride JSON can still be opened through the app or Finder’s Open With. The app is an alternate JSON handler and does not claim every `.json` file. Version 1 projects from the browser app can be opened; relink their originals once. Native projects retain the same format with optional bookmark fields, and the browser picker accepts both extensions.
7. **Finish Project** in the toolbar’s More menu clears the current autosave and releases video references, offering to save edits first. Original videos and exported clips are preserved. Quitting autosaves metadata and cancels unfinished exports.

An event outside the footage cannot be exported. Handles are clamped at the beginning/end of footage. Clips spanning a declared recording gap require shorter handles or a corrected gap.

### Try a sample

Choose **Try a sample project** on the welcome screen, or **Load Sample Project**
in the File or More menu. The app generates a short 640×360 synthetic cycling
animation with close-call, blocked-lane, and custom reports. Trim, calibrate, and
export it using the regular controls. The UI and video identify it as synthetic.
No camera footage, GPS data, download, or bundled video is needed.

Generated footage lives in this session’s temporary directory and is removed when
you leave the sample or quit. The sample never replaces the last real project's
autosave. You may save sample edits as a metadata-only project; the Mac app
regenerates its video when reopened. This generation marker is a native extension;
sample projects need the Mac app to recreate their footage. Real projects remain
compatible with the browser app.

## Storage and privacy

- Originals are **referenced in place**, never copied into a project or the app bundle. Files over 4 GB are supported.
- Security-scoped bookmarks restore access on this Mac when possible. Missing or changed files require relinking; name, size, duration, and modification time are checked. Native bookmarks may contain local file-location information, so project files should be treated as personal metadata.
- The save panel calls out the report times and local file-location information before you save or share a project.
- Autosave lives in the app’s sandbox Application Support directory. Only the latest project is restored on launch; save separate project files to retain multiple rides.
- Previews use in-memory compositions. Exports render to a temporary file, copy to the chosen destination, then remove the temporary video. Cancellation/quit removes unfinished renders; abandoned render directories are reclaimed after a crash on the next launch.
- **`sample_video/` is external test material only.** It is git-ignored, outside the Xcode source/resource group, and absent from the app bundle. No videos, browser assets, Node modules, or FFmpeg binaries are bundled.

## Tests

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path 'BumpyRide Clip'

# Optional: also test an audio-preserving cut across the two external camera files.
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  BUMPYRIDE_SAMPLE_VIDEO_DIR="$PWD/sample_video" \
  swift test --package-path 'BumpyRide Clip'
```

Tests cover ride parsing, sync choice, timeline boundaries/gaps, project compatibility, source identity, and actual AVFoundation exports across generated video files with different sizes/frame rates. Generated media is temporary and cleaned up. The optional camera test reads the originals without copying them.

The app icon can be regenerated with `swift scripts/generate-macos-icon.swift` from the repository root.

The Node browser app is maintained alongside the native app for Windows, Linux, and macOS. See [browser setup and data-contract notes](docs/browser-app.md). Its tests run with `npm test`.

### Calibration and batch timing

**Calibrate video sync** lives beside the clip preview in both apps. Use 0.1-second earlier/later nudges, enter a start correction, or pause on the matching frame and choose **Match event to this frame** (web: **Match event to paused frame**). Calibration updates the whole ride and is saved in the project. Positive correction means the camera started later than the sync reference; events move earlier in the recording. Reset correction returns to the original sync reference. The preview keeps the current recording position when it remains inside the adjusted clip; otherwise it clamps to the nearest clip edge.

A clip-relative bar marks the event and the current playback position. A countdown changes to **EVENT RECORDED** at the marker, then shows elapsed time since the event. The cue is for review only and is not burned into exports. On the web, a rendered compatible preview must be rebuilt after calibration changes if the original codec cannot play directly.

Check two or more reports, set before/after values on the current report, and choose **Apply timing to N selected clips**. This applies to all checked reports, including ones hidden by a filter, and preserves selection and review flags. New clips and Reset use **15s before / 5s after**; reopening a project preserves explicit saved timings.
