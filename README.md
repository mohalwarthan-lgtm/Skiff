<p align="center">
  <img src="assets/logo.png" width="140" alt="SkiffBox logo" />
</p>

<h1 align="center">SkiffBox</h1>

<p align="center">
  A lightweight, no-nonsense media hub for Windows.<br/>
  Powered by Stremio add-ons. Synced with Trakt. Yours to configure.
</p>

---

SkiffBox is a desktop app for people who want a fast, minimal alternative to Stremio: a clean library, a capable player, real offline downloads, and deep two-way Trakt sync — while **all content, labeling, and sources come from the add-ons you choose**. The app itself stays out of the way.

## Features

**Stremio add-on protocol**
- Install any Stremio-compatible add-on by URL (metadata add-ons like AIOMetadata, stream add-ons like AIOStreams with your debrid services).
- Catalogs, search, metadata, streams, and subtitles all flow from your add-ons, exactly as you configured them — SkiffBox adds no labels or re-ranking of its own.
- Search results stay grouped per catalog (Movies / Series / Anime…), mirroring your metadata add-on's own separation.
- Related-title chips (prequels, sequels, franchise entries) when your metadata add-on provides them.

**Library**
- Shelves: Watching, Plan to watch, Completed — plus per-episode watched flags.
- Continue Watching with live progress, episode release dates, and upcoming-episode markers.

**Trakt — full two-way sync**
- One-click connect. Playback scrobbles live; shelf changes and watched flags push instantly; your history pulls on launch and every 30 minutes.
- Partial episode positions carry over **both ways** — pause on another device, resume in SkiffBox at the same spot (and vice versa). Whoever watched most recently wins.
- Removing a title removes it everywhere on Trakt too: watchlist, history, and Continue Watching.
- "Clean up Trakt" makes Trakt mirror your local library exactly.
- Automatic episode-numbering translation for shows where Trakt and your metadata disagree (e.g. anime listed as one long season on Trakt but three seasons in TVDB order) — watched history and positions land on the right episode on both sides.
- Anime-friendly: mixed ID setups (IMDb-keyed shows with Kitsu-keyed episodes) are resolved automatically.

**Player**
- Full-codec engine bundled by the cloud build — TrueHD, DTS, everything plays. A one-click restore script falls back to the safe stock engine if ever needed.
- Fullscreen (F / double-click), keyboard shortcuts, speed control, audio & subtitle track pickers with clean language labels.
- Subtitle styling with live preview: size, position, outline, background box, and delay — all persisted.
- Graceful audio-codec fallback: if a track can't decode, playback continues on another track with a small dismissible notice instead of a blocking error.

**Downloads**
- Download any stream for offline watching, subtitles included.
- Multi-select episodes (long-press to start selecting) or queue a whole season; pick the quality from chips detected from what's actually available — within it, your add-on's own ranking (cached links first) decides.
- Downloads are grouped by show, episodes stacked under one card.
- Choose your download folder and your streaming-cache folder (keep big buffers off a tight C: drive). Previously downloaded titles keep playing from wherever they already live.

**Profiles**
- Export your whole setup — add-on URLs, library, watch progress, settings, Trakt login — to one small JSON file; import it on any other machine running SkiffBox and continue where you left off.
- Treat the file like a password: it contains your Trakt session and add-on tokens.

## Getting the app

Every push to this repository triggers a cloud build. Grab the newest one:

1. Open the **Actions** tab and click the latest green run.
2. Download the **skiffbox-windows** artifact.
3. Unzip anywhere and run `skiffbox.exe`. No installer, no dependencies.

## First-run setup

1. **Add-ons** tab → paste your add-on manifest URLs (your configured AIOMetadata and AIOStreams links, or any Stremio add-ons you use).
2. **Settings → Trakt → Connect** → enter the code at trakt.tv/activate. Sync is automatic from then on.
3. Optional: set your download and cache folders under **Settings → Storage**.

That's it — Home fills with your catalogs, and everything else follows from your add-on configuration.

## Building it yourself

The repository contains only the Dart/Flutter source; Windows platform files are generated fresh on every build.

1. Fork the repo.
2. Add two repository secrets (Settings → Secrets → Actions): `TRAKT_CLIENT_ID` and `TRAKT_CLIENT_SECRET` from your own [Trakt API app](https://trakt.tv/oauth/applications).
3. Push any change — the workflow compiles the app, stamps the icon, upgrades the media engine to the full-codec build, and publishes the artifact.

## Notes

- SkiffBox is a client. It ships with no content and no sources; everything you see comes from add-ons **you** install and configure, and you are responsible for what those add-ons access.
- Windows today. The codebase is Flutter, so other platforms are a build target away.
