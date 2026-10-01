# Response to web feedback — 2026-10-01

Reviewed against the local source and verified in the 1.0.1 (build 2) app.

**1.0.2 follow-up:** source publication and a GitHub release are now authorized.
The release adds searchable ride selectors to both apps and prominent Windows/Linux
Node setup instructions. The Mac selector remembers the chosen folder with a
security-scoped bookmark. Publishing status below describes the earlier feedback
pass; the public source and downloads are available from the repository and its
[Releases page](https://github.com/direwolfvm/bumpyride-clip/releases).
The original feedback is preserved in `WEB_FEEDBACK.md`.

1. **Project opening:** added the exported project type, Finder/Dock URL handling
   (including requests arriving during startup or another operation), and recent
   documents. New native saves use `.bumpyclip`, still plain version-1 JSON.
   A distinct final extension gives Finder a reliable association without claiming
   all JSON files. Old `.bumpyclip.json` projects and ride JSON remain supported
   in the app and through Open With. The browser picker accepts both extensions.
   Verified a cold Finder launch of a saved project and reopening via Open Recent.

2. **Sample project:** added a welcome-screen action and File/More menu item.
   It generates a 70-second synthetic cycling animation on demand, with three
   illustrative reports. No video files are bundled. Generated video is temporary;
   saved sample projects regenerate it when reopened in the Mac app. The sample
   preserves the last real project's autosave. Verified generation, playback,
   event indication, saved-project reopening, and export. A populated screenshot
   is available locally at `output/native-sample-project.png`.

3. **Unpublished macOS source:** confirmed. GitHub reports this repository as
   public. No source was committed or pushed during this feedback pass; publishing
   the macOS implementation requires the owner's decision.

4. **Release hosting:** no GitHub release was published or website changed.
   A signed, notarized 1.0.1 (build 2) DMG is prepared locally for review and future
   publication. It is under `output/releases/20261001T165541Z.Y9OM0V/`, together
   with its checksum and notarization receipts. A binary-only public release is
   possible independently of publishing the macOS source.

5. **DMG signing identifier:** the build script now explicitly sets
   `com.herbertindustries.BumpyRide-Clip.dmg`. Verified that the new notarized image
   has this identifier and contains no pending-notarization label in its signature.

6. **Privacy at save time:** the native save panel now states that project files
   include report times and file references that may reveal local file locations,
   and asks users to treat projects as personal metadata when sharing.

7. **Video Sync compatibility:** both existing parsers already inspect `kind`,
   independently of `isCustom`. Added native and web regression tests for old
   custom markers and normalized built-in-style markers (`video-sync`, etc.),
   including saved-project round trips. All remain sync markers, not review clips.
   No changes were made to iOS event kinds or the website's publication registry;
   excluding workflow markers from public maps remains a separate server concern.

8. **Web-account ride import:** deferred. This pass adds no accounts, network
   permissions, or changes to the app's offline operation.

Validation: 19 web tests and 14 native tests passed; the native release builds for
Apple silicon and Intel. Both app and DMG passed notarization, stapled-ticket,
signature, and Gatekeeper checks. The mounted app's document declarations and
absence of bundled videos were verified separately.
