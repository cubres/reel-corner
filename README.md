# Reel Corner

A small always-on-top panel in the corner of your Mac screen that plays the
Instagram Reels feed continuously, stripped down to nothing but the reel — driven
entirely by keyboard shortcuts, so you never have to click into it.

```
F9   next reel          ⌘F9   start / stop the player
F7   like               ⌘F8   switch to your saved reels
F8   save               ⌃⌥I   show / hide the panel
```

Every key is configurable, and changes apply while it runs.

## Install

```bash
git clone https://github.com/cubres/reel-corner.git
cd reel-corner
./install.sh
```

That builds the app, installs it to `/Applications`, starts it at login, and sets
up the function keys (see below). Requires macOS 13+ and the Xcode command line
tools (`xcode-select --install`) — no Xcode project, no dependencies.

Then log in once: click the ▶ icon in the menu bar → **Log in to Instagram (wide
window)**, sign in, then **Back to corner**. The session persists.

To remove everything: `./uninstall.sh` (add `--all` to drop your settings too).

## Settings

One file, and edits take effect within two seconds — no restart:

```
~/Library/Application Support/ReelCorner/config.json
```

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

Keys are `F1`–`F12`, a letter, or a digit, optionally combined with `cmd`, `ctrl`,
`alt` and `shift` — for example `"cmd+shift+J"`. The menu always shows what is
actually bound, so the menu and the file can never disagree. Get it wrong and the
app writes a fresh file and tells you in the log rather than silently ignoring it.

**If you change a bare F-key, re-run `./install.sh`** so the remap below follows it.

## About the function keys

On a Mac with *"Use F1, F2, etc. as standard function keys"* switched **off**,
pressing F9 does not send F9 — the keyboard driver sends a media action instead, so
a shortcut bound to F9 would simply never fire.

Turning that setting on is the obvious fix and is usually the wrong one: it costs
you brightness and volume on a bare press. So `install.sh` remaps *only* the keys
you have actually bound, using the driver's own table of what each function key
emits. Everything else keeps working.

It merges with any `hidutil` remapping you already have — `hidutil --set` replaces
the whole table, so writing ours blindly would silently break your other remapped
keys. `uninstall.sh` removes exactly the entries it added and leaves the rest.

The cost: the keys you bind stop sending their media action (F7/F8/F9 are
previous / play-pause / next track by default). Media controls still work from
Now Playing in Control Centre.

## Saved reels

`⌘F8` switches to your saved collection and renders it exactly like the feed —
full-bleed, no Instagram chrome. Instagram has no reels-only saved view, so
anything without a video is skipped automatically. `⌘F8` switches back.

## Menu bar

Like / save / next, saved reels, panel size and zoom, sound, show the full
Instagram page again, a wide window for logging in, and **Change keys and size…**
which just opens the config file.

## Troubleshooting

```bash
tail -f ~/Library/Logs/ReelCorner.log
```

Everything is logged: which shortcuts bound, how long each reel took to start,
where each press landed, and any failure to like or save. A stalled start logs why
— whether it was the network or the player.

Instagram changes its markup regularly. If like or save stops finding its button,
`Dump page labels to log` in the menu prints every control on the page; the label
lists are at the top of [`src/Bridge.swift`](src/Bridge.swift).

[NOTES.md](NOTES.md) explains why the implementation is the way it is — several
parts are deliberately counter-intuitive and worth reading before changing them.

## License

MIT
