# Reel Corner

**Doomscroll in the corner of your screen while you work.** Reel Corner is a tiny
always-on-top panel that plays the Instagram Reels feed in the corner of your
desktop — no browser tab, no window juggling, no clicking. You never touch the
mouse: one key for the next reel, one to like, one to save.

Your own private goon corner, pinned above everything else, on **macOS and Windows**.

```
F9   next reel          ⌘/Ctrl+F9   start / stop the player
F7   like               ⌘/Ctrl+F8   switch to your saved reels
F8   save               Ctrl+Alt+I  show / hide the panel
```

Every key is configurable, and changes apply while it runs.

- **Nothing but the reel.** The feed, the sidebar, the comments, the navigation bars
  — all stripped out. The video fills the panel edge to edge.
- **Instant.** A keypress costs 0–2 ms and the next two reels are pre-buffered, so
  there is no frozen first frame while it loads.
- **Stays out of the way.** Never takes focus, never steals your keyboard, floats
  above fullscreen apps, and hides with one key when someone walks past.
- **Saved reels mode.** Flip to your saved collection and scroll it the same way;
  anything that is not a video is skipped automatically.

---

## Install

### Windows

Download the installer from [Releases](../../releases), run it, done. It starts with
Windows and lives in your system tray.

Building it yourself instead:

```bash
cd electron
npm install
npm start
```

### macOS

```bash
git clone https://github.com/cubres/reel-corner.git
cd reel-corner
./install.sh
```

That builds a small native app (~5 MB, ~1% CPU), installs it to `/Applications`,
starts it at login, and sets up the function keys. Requires macOS 13+ and the Xcode
command line tools (`xcode-select --install`). No Xcode project, no dependencies.

Prefer the cross-platform build on macOS too? `cd electron && npm install && npm start`.

**Then log in once:** click the ▶ icon in the menu bar / tray → **Log in to
Instagram (wide window)**, sign in, then **Back to corner**. The session persists.

To remove everything on macOS: `./uninstall.sh` (add `--all` to drop settings too).

---

## Settings

One file. Edits take effect within two seconds — no restart:

| | |
|---|---|
| macOS | `~/Library/Application Support/ReelCorner/config.json` |
| Windows | `%APPDATA%\ReelCorner\config.json` |

```json
{
  "keys": {
    "next":      "F9",
    "like":      "F7",
    "save":      "F8",
    "showHide":  "ctrl+alt+I",
    "startStop": "cmd+F9",
    "savedMode": "cmd+F8"
  },
  "panel": { "width": 380, "height": 660, "zoom": 0.75 },
  "startMuted": true
}
```

Keys are `F1`–`F12`, a letter or a digit, optionally combined with `cmd`, `ctrl`,
`alt` and `shift` — for example `"cmd+shift+J"`. `cmd` means Command on macOS and
Ctrl on Windows, so one file works on both. The tray menu always shows what is
actually bound, so the menu and the file can never disagree. Get it wrong and it
writes a fresh file and says so in the log rather than silently ignoring you.

There is also **Change keys and size…** in the tray menu, which just opens the file.

---

## About the function keys (macOS only)

On a Mac with *"Use F1, F2, etc. as standard function keys"* switched **off**,
pressing F9 does not send F9 — the keyboard driver sends a media action instead, so
a shortcut bound to F9 would never fire.

Turning that setting on is the obvious fix and is usually the wrong one: it costs
you brightness and volume on a bare press. So `install.sh` remaps *only* the keys
you have actually bound, using the driver's own table of what each function key
emits. Everything else keeps working, and it merges with any `hidutil` remapping you
already have — `hidutil --set` replaces the whole table, so writing ours blindly
would silently break your other remapped keys. `uninstall.sh` removes exactly the
entries it added.

The cost: the keys you bind stop sending their media action. Media controls still
work from Now Playing in Control Centre.

Windows sends real function keys already, so none of this applies there.

---

## Two builds, one brain

| | macOS native | Electron |
|---|---|---|
| Platforms | macOS 13+ | macOS, Windows, Linux |
| Size / memory | ~5 MB, ~85 MB RAM | ~200 MB, ~700 MB RAM |
| CPU at rest | ~1% | higher |
| Setup | `./install.sh` | `npm install && npm start` |

Both inject the **same** page logic from [`shared/bridge.js`](shared/bridge.js) — the
native app compiles it in, Electron injects it directly — so a fix for an Instagram
markup change lands on both platforms at once.

## Troubleshooting

The log records everything: which shortcuts bound, how long each reel took to start,
where each press landed, and any failure to like or save.

```
macOS    ~/Library/Logs/ReelCorner.log
Windows  %APPDATA%\ReelCorner\reel-corner.log
```

Instagram changes its markup regularly. If like or save stops finding its button,
**Dump page labels to log** in the menu prints every control on the page; the label
lists are at the top of [`shared/bridge.js`](shared/bridge.js).

[NOTES.md](NOTES.md) explains why the implementation is the way it is. Several parts
are deliberately counter-intuitive — worth reading before changing them.

## Contributing

Issues and pull requests welcome, especially:

- Windows testing and polish (the Electron build is untested on real hardware)
- Support for other feeds — YouTube Shorts, TikTok, Reddit
- Keeping up with Instagram's markup changes

## Disclaimer

Unofficial and not affiliated with Instagram or Meta. It drives the ordinary
Instagram web page in a normal web view — no private APIs, no scraping, no stored
credentials. Your login lives in the app's own browser session and never leaves your
machine.

## License

MIT

---

<sub>**Keywords:** doomscroll · doomscrolling · goon corner · gooning · brainrot ·
infinite scroll · instagram reels · reels viewer · reels player · tiktok style ·
youtube shorts alternative · always on top · picture in picture · floating video ·
corner video player · second monitor · background video · desktop widget · menu bar
app · system tray app · global hotkeys · keyboard shortcuts · productivity ·
procrastination · macos app · windows app · electron app · swift · appkit · webkit ·
open source</sub>
