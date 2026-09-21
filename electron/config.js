const fs = require('fs');
const os = require('os');
const path = require('path');

// Deliberately NOT app.getPath('userData'): on macOS this shares one config file
// with the native app, so the two stay in step if both are installed.
function dir() {
  if (process.platform === 'darwin') {
    return path.join(os.homedir(), 'Library', 'Application Support', 'ReelCorner');
  }
  if (process.platform === 'win32') {
    return path.join(process.env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming'), 'ReelCorner');
  }
  return path.join(process.env.XDG_CONFIG_HOME || path.join(os.homedir(), '.config'), 'ReelCorner');
}

const FILE = path.join(dir(), 'config.json');
const LOG = path.join(dir(), 'reel-corner.log');

const DEFAULT_KEYS = {
  next: 'F9',
  like: 'F7',
  save: 'F8',
  showHide: 'ctrl+alt+I',
  startStop: 'cmd+F9',
  savedMode: 'cmd+F8',
};

const TEMPLATE = `{
  "_comment": "Edit and save - Reel Corner picks up changes within 2 seconds, no restart.",
  "_keyFormat": "F1-F12, a letter, or a digit. Combine with cmd / ctrl / alt / shift, e.g. \\"cmd+F8\\". 'cmd' means Command on macOS and Ctrl on Windows.",

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
`;

function log(msg) {
  const line = new Date().toTimeString().slice(0, 8) + '  ' + msg + '\n';
  try {
    fs.mkdirSync(dir(), { recursive: true });
    fs.appendFileSync(LOG, line);
  } catch (e) { /* logging must never break the app */ }
  process.stdout.write(line);
}

// Missing, empty or unparseable all get the commented template back: silently
// running on defaults would leave someone editing a file nothing reads.
function load() {
  fs.mkdirSync(dir(), { recursive: true });
  let raw = null;
  try { raw = fs.readFileSync(FILE, 'utf8'); } catch (e) { /* absent */ }

  let parsed = null;
  if (raw && raw.trim()) {
    try { parsed = JSON.parse(raw); }
    catch (e) {
      try { fs.writeFileSync(path.join(dir(), 'config.broken.json'), raw); } catch (e2) {}
      log('config: could not read config.json - kept a copy as config.broken.json');
    }
  }
  if (!parsed) {
    fs.writeFileSync(FILE, TEMPLATE);
    log('config: wrote a fresh config.json at ' + FILE);
    parsed = JSON.parse(TEMPLATE);
  }

  const panel = parsed.panel || {};
  return {
    keys: Object.assign({}, DEFAULT_KEYS, parsed.keys || {}),
    width: Number(panel.width) || 380,
    height: Number(panel.height) || 660,
    zoom: Number(panel.zoom) || 0.75,
    startMuted: parsed.startMuted !== false,
  };
}

function modified() {
  try { return fs.statSync(FILE).mtimeMs; } catch (e) { return 0; }
}

/// "cmd+F8" -> "CommandOrControl+F8". 'cmd' maps to Command on macOS and Ctrl on
/// Windows, so one config file gives sensible shortcuts on both.
function toAccelerator(combo) {
  const parts = String(combo).split('+').map(p => p.trim()).filter(Boolean);
  if (!parts.length) return null;
  const key = parts.pop().toUpperCase();
  const mods = [];
  for (const m of parts) {
    switch (m.toLowerCase()) {
      case 'cmd': case 'command': mods.push('CommandOrControl'); break;
      case 'ctrl': case 'control': mods.push('Control'); break;
      case 'alt': case 'opt': case 'option': mods.push('Alt'); break;
      case 'shift': mods.push('Shift'); break;
      default: return null;
    }
  }
  if (!/^(F([1-9]|1[0-2])|[A-Z0-9])$/.test(key)) return null;
  return mods.concat(key).join('+');
}

module.exports = { FILE, LOG, dir, load, modified, log, toAccelerator, DEFAULT_KEYS };
