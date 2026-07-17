# Skiff (Flutter edition)

A Stremio-compatible media hub with the things Stremio lacks: real library management (Watching / Plan to watch / Completed / On hold / Dropped, per-episode watched flags, resume), hands-off two-way Trakt sync, and **offline downloads** (episodes + subtitles saved for travel, in their own Downloads tab).

Everything content-related comes from the add-ons you install (AIOMetadata, AIOStreams, anything protocol-compliant). Torrent-only streams are handled by **TorBox server-side** — this app contains no torrent engine at all. Playback uses media_kit, which bundles its own video engine (MKV/HEVC/embedded tracks just work; nothing to install).

## Build it WITHOUT installing anything on your PC

Your computer never compiles this. GitHub's servers do:

1. Go to **github.com** and sign in (or create a free account).
2. Top-right **+** → **New repository** → name it `skiff` → set it to **Private** → **Create repository**.
3. On the new repo page, click **uploading an existing file**. Drag **everything inside this folder** (including the `.github` folder — if your unzipper hid it, enable "show hidden files") into the page. Click **Commit changes**.
4. Click the **Actions** tab. A build called **Build Skiff** starts by itself. Wait for the green check (5–15 minutes).
5. Click the finished run → scroll to **Artifacts** → download **skiff-windows** → unzip anywhere → run **skiff.exe**.

That's the whole loop, forever: change code → push → download a fresh app.

### Optional: one-click Trakt login for the app
In the repo: **Settings → Secrets and variables → Actions → New repository secret**. Add `TRAKT_CLIENT_ID` and `TRAKT_CLIENT_SECRET` (from a free API app you create once at trakt.tv/oauth/applications). Re-run the build; the app's Settings will then show a single **Connect Trakt** button.

## Using the app

1. **Add-ons** — paste your configured AIOMetadata / AIOStreams manifest URLs.
2. **Discover** — browse/search every catalog your add-ons provide.
3. Any title → set a shelf, browse episodes, tap an episode → stream list appears. **Play** streams instantly; the **download icon** saves the episode plus all add-on subtitles for offline.
4. **Downloads** — your offline shelf: play without internet (with subtitle picker), delete to free space.
5. **Settings** — connect Trakt (fully automatic sync after that) and add your TorBox API key (only needed for torrent-only P2P streams).

## Project layout

```
lib/services/   addons (Stremio protocol) · db (Hive) · trakt · torbox · downloads
lib/screens/    library · discover · details · player · downloads · addons · settings
.github/        cloud build workflow (Windows artifact)
```

Notes: the `windows/` platform folder is intentionally absent — the cloud build generates it. Written offline; if the first cloud build fails, the full error log is on the Actions run page — paste it to Claude and iterate without touching your machine.

## Roadmap
- [ ] Storage cap + auto-cleanup for downloads; download whole seasons in one tap
- [ ] Catalog paging and genre filters (`extra.options`)
- [ ] Android build job in the same workflow (Flutter makes this nearly free)
- [ ] Trakt conflict resolution beyond "local shelf choice wins"
