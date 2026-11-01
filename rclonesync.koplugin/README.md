# Settings sync (rclonesync.koplugin)

Pushes and pulls KOReader settings to a cloud remote with
[rclone](https://rclone.org), so several devices can share them. It
replaces the `PushSettings.sh` / `PullSettings.sh` / `PushTweaks.sh` /
`PullTweaks.sh` scripts and uses the same rclone folder and remote layout,
so devices still on the scripts stay in step.

## Install

1. Copy `rclonesync.koplugin` into KOReader's `plugins/` folder.
2. Keep (or create) the rclone folder next to KOReader's, as the scripts
   had it: `rclone` (the binary for the device), `rclone.conf` and
   `settings.txt`.
   - Kobo: `.adds/rclone/` (next to `.adds/koreader/`)
   - Kindle: `/mnt/us/rclone/`
   - Linux: `~/.config/rclone/` (a system `rclone` on the PATH is used if
     the folder has no binary)
   - Android: `/sdcard/rclone/` (see below)

   `koreader/rclone/` and the plugin's own folder are also looked in, or
   choose any folder in the menu.
3. Restart KOReader.

The menu is in Tools → "Settings sync", in both the file browser and the
reader. The four actions can also be assigned to gestures (under General:
"Settings sync: Push settings" and so on).

## What's synced

| Remote (`<root>` = `/KOReader/Settings`) | Device | Direction |
|---|---|---|
| `rclone/settings.txt` | rclone folder | both, first |
| `settings/` | the files `settings.txt` lists, relative to KOReader's folder | both |
| `fonts/` | `fonts/` | pull only |
| `patches/` | `patches/` (except `1-knuthplass-engine.lua`) | both |
| `icons/` | `icons/` | both |
| `dict/` | `data/dict/` | both |
| `styletweaks/` | `styletweaks/` | both |

"Style tweaks only" syncs just `settings.txt` and `styletweaks/`. As with
the scripts, everything is `rclone sync --checksum`: the destination ends
up matching the source, deletions included.

- **Fonts** are only pulled, so fonts installed on one device stay there.
- **Plugins** aren't synced (some are large; ZenPM keeps them updated).
- **`1-knuthplass-engine.lua`** is left out because the Knuth–Plass plugin
  writes it for each device itself.
- **A folder missing on the device** is skipped on push instead of emptying
  the remote copy.
- Write the entries in `settings.txt` with a leading `/` (as now), so they
  match only at the top of KOReader's folder.

## Differences from the scripts

- **Pushing saves first.** KOReader writes its in-memory settings to disk
  before the push, so what's pushed is what's in use.
- **Pulled settings files go in place at the next start.** KOReader keeps
  files like `gestures.lua` in memory and would write the old values over
  freshly pulled ones. So a pull puts them in `koreader/rclonesync/staging/`
  and asks to restart. As KOReader starts, before any plugin reads its
  settings, the plugin copies them into place. Until then, "Push settings"
  is refused (it would send the old ones back), and the menu offers to
  discard them. Fonts, patches, icons, dictionaries and style tweaks are
  pulled straight into place.
- **Wi-Fi** is turned on if needed (KOReader asks as usual).
- **Certificates:** rclone uses KOReader's own `data/ca-bundle.crt`, so
  there's no download from curl.se.
- **Output:** a summary when a sync finishes, the log when one fails, and
  "Show last log" in the menu (`koreader/rclonesync/last.log`). "Dry run"
  shows what would change without changing anything.
- **Remote:** chosen from the remotes in `rclone.conf` (the first by
  default). The folder on the remote can be changed too.
- **Not included:** `InstallPatch.sh`, which copied an engine over
  `libs/libkoreader-cre.so`. The Knuth–Plass plugin's updater now installs
  and updates the engine without replacing KOReader's own. The `.sh`
  scripts on the remote are left as they are.

## Android

Android won't run programs from shared storage. So the plugin copies
`rclone` (an `android-arm64` build) into the app's private storage, next
to the Knuth–Plass engine, and runs it from there. It copies it again when
the file changes. This is untested; if it fails, the log says so.
