# Notes from the web side (2026-10-01)

Written while building the `/clip` feature page on bumpyride.me. Everything
below was checked against the shipped `BumpyRide-Clip-1.0-1.dmg` or
`origin/main`, not inferred from the README — commands included so you can
re-run anything you disagree with.

Ordered by how much it matters, not by effort.

---

## First, the part that is already right

The release engineering is genuinely solid, and I say that having tried to
poke holes in it because the website now makes the claim publicly:

```sh
spctl -a -t exec -vv 'BumpyRide Clip.app'
#   accepted / source=Notarized Developer ID / Jordan Eccles (LAKT4757H4)
codesign -dv --verbose=2 'BumpyRide Clip.app'
#   flags=0x10000(runtime)   TeamIdentifier=LAKT4757H4
codesign -d --entitlements - 'BumpyRide Clip.app'
#   app-sandbox, files.bookmarks.app-scope, files.user-selected.read-write
```

Hardened runtime on, sandboxed, three entitlements and not one more, no
stray `get-task-allow`, ticket stapled so it works offline. The DMG also
survives a round trip through a web server byte-identically and still
passes `spctl`, which is what actually matters for a download button.

---

## 1. `.bumpyclip.json` cannot be opened by double-clicking it

**Verified on the shipped app:**

```sh
/usr/libexec/PlistBuddy -c "Print :CFBundleDocumentTypes" \
  'BumpyRide Clip.app/Contents/Info.plist'
#   Entry, ":CFBundleDocumentTypes", Does Not Exist
```

There is no `CFBundleDocumentTypes` and no exported UTI. For a
document-based app that saves and reopens project files, this costs more
than it looks:

- double-clicking a `.bumpyclip.json` in Finder does not open it
- the app never appears under **Open With**
- dragging a project onto the Dock icon does nothing
- `open -a 'BumpyRide Clip' project.bumpyclip.json` silently just focuses
  the app (this is how I found it — I was trying to script a screenshot)
- **Recent Documents** and Dock-icon recents stay empty

Declaring an exported UTI (something like
`com.herbertindustries.bumpyride.clipproject`, conforming to
`public.json`) plus a `CFBundleDocumentTypes` entry would fix all of them
at once. `.bumpyclip.json` conforming to `public.json` also means Quick
Look and text editors keep working on it.

Worth pairing with `NSDocumentClass`/`.handlesExternalEvents` or an
`onOpenURL` handler so a launched-with-document start actually loads it.

## 2. There is no way to try the app without your own footage

The browser version has **Use sample videos** (`public/app.js`,
`#load-samples`) and a committed demo project in `.playwright-cli/`. The
Mac app has no equivalent — `grep -li 'sample\|demo'` across the Swift
sources returns nothing.

That matters in three places:

- a new user cannot see what the app does before committing a ride and
  several GB of video to it
- you cannot produce a populated screenshot for the App Store, the repo,
  or the website without using real personal footage
- it is the reason the website currently illustrates the Mac app with an
  **empty window**. I could load the demo project into the browser app
  programmatically; on the Mac app the only path ran through a native
  open panel, which I was not willing to drive by taking over the screen
  for a marketing image

A "Load sample project" item in the More menu — reusing the demo ride JSON
that already exists, pointed at a tiny bundled clip or a generated colour
bars movie — would unblock all three. If you add it, tell me and I will
reshoot the website screenshot.

## 3. The macOS source is not pushed, and the public README describes the old app

```sh
git ls-tree --name-only origin/main
#   .gitignore README.md lib package-lock.json package.json public server.js test
```

No `BumpyRide Clip/`. The macOS work is staged locally but has never
reached `origin`. Consequences right now:

- the README a visitor sees still opens with *"A local browser app…"*,
  while your local README opens with *"A native macOS companion"*
- someone who downloads the DMG and clicks through to the repo finds no
  trace of the app they just installed
- the website's Windows/Linux section is the only part of this that is
  currently accurate against `origin`, and only because the browser app
  genuinely is there

Nothing on the website breaks either way — I deliberately pointed Mac
users at the DMG and everyone else at the repo — but the gap is worth
closing before the page drives traffic.

## 4. No GitHub release; the DMG is currently hosted on bumpyride.me

`gh release list` is empty, so the website serves the DMG from
`public/downloads/` with its SHA-256 published next to it. At 815 KB that
is fine and it works today.

It does not scale: every future version becomes another binary committed
to the **website's** git history forever, and shipping a new build means
deploying the website. A GitHub release is the better home — versioning,
download counts, release notes, and binaries out of both repos' history.
Cut one and I will repoint the button; it is a one-line change on my side.

## 5. The DMG's signing identifier still says `PENDING-NOTARIZATION`

```sh
codesign -dv BumpyRide-Clip-1.0-1.dmg
#   Identifier=BumpyRide-Clip-1.0-1-PENDING-NOTARIZATION
```

Cosmetic — the **app** inside is identified correctly as
`com.herbertindustries.BumpyRide-Clip`, and notarization plainly
succeeded. But it is a build-pipeline artifact that ships to users and
shows up in any signature inspection, so it reads like something was left
half-done when it was not. Probably a one-line fix in whatever names the
disk image.

## 6. Surface the project-file privacy note in the app, not only the README

Your README is admirably precise that security-scoped bookmarks can record
file locations and that `.bumpyclip.json` should be treated as personal
metadata. I had to correct the website over exactly this — the page
previously claimed project files contain "no file paths", which was wrong
once the native app existed.

Nobody reads a README before sharing a small JSON file. A line in the save
panel, or a one-time note the first time a project is saved, would put the
caveat where the decision is actually made.

---

## 7. Cross-repo: what happens if iOS makes "Video Sync" a built-in kind

This one needs coordinating across all three repos, and it is the item I
would most want on your radar.

Clip matches the sync marker **by label** — case-insensitively, after
stripping spaces, hyphens and underscores. That works because Video Sync
is a *custom* event today (`isCustom: true`).

On the web side, `other_events` now has a built-in kind registry
(`OTHER_EVENT_BUILTIN_KINDS`, currently just `blocked-lane`) and a
server-computed `is_public_eligible = registry(kind) ∧ NOT isCustom`. Only
eligible events reach the public map and the `lane-scout` achievement.

So if iOS ever promotes Video Sync to a built-in kind:

1. `isCustom` flips to `false` for new markers, and old rides keep
   `true` — clip would need to match on **kind** as well, keeping the
   label match as the fallback for existing rides. Projects saved before
   the change must keep resolving.
2. More importantly, **it would become publishable**. The moment the web
   registry learns the kind, every Video Sync marker from a sharing-on
   rider starts counting toward public map cells. That is wrong: it is a
   personal workflow marker, not an infrastructure report, and it would
   quietly pollute the community layer.

If Video Sync is ever promoted, the web side needs a way to mark a kind
*recognised but never published*. Easier for everyone if it simply stays
custom — but that is a decision worth making deliberately rather than
discovering after the fact.

## 8. Optional: rides could come from the web account instead of iCloud

Only if you want it, and it cuts against the offline-by-default design, so
I would weigh it carefully.

The web API already serves the exact schema clip parses:

- `GET /api/sync/rides` — paginated list, now including `contentHash`
- `GET /api/sync/ride/{id}` — one ride, same JSON the iOS app uploads

Both take the same bearer token the iOS app uses. That would let someone
clip a ride recorded on a phone that never synced to *this* Mac's iCloud,
which is currently impossible.

The cost is that an app whose main selling point is "needs no network
connection at all" would grow a network path. If you do it, it should be
clearly opt-in and never the default — the website leans hard on that
promise, and I would rather not have to soften it.
