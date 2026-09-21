const { app, BrowserWindow, Tray, Menu, globalShortcut, screen, shell, nativeImage } = require('electron');
const fs = require('fs');
const path = require('path');
const cfg = require('./config.js');

// Reels must start on their own; without this every reel sits on a frozen first frame.
app.commandLine.appendSwitch('autoplay-policy', 'no-user-gesture-required');

const REELS = 'https://www.instagram.com/reels/';
const ACTIONS = ['next', 'like', 'save', 'showHide', 'startStop', 'savedMode'];

let win = null, tray = null, config = cfg.load(), stamp = 0;
let playerOn = true, muted = true, bound = {};

function bridgeSource() {
  for (const p of [path.join(__dirname, 'bridge.js'),
                   path.join(__dirname, '..', 'shared', 'bridge.js')]) {
    try { return fs.readFileSync(p, 'utf8'); } catch (e) { /* try the next */ }
  }
  cfg.log('FATAL: bridge.js not found - run "npm run sync"');
  return '';
}
const BRIDGE = bridgeSource() + '\n;0;';   // discard the completion value: it is
                                           // an object of functions and cannot be cloned

// ---------------------------------------------------------------- window

function place() {
  if (!win) return;
  const wa = screen.getPrimaryDisplay().workArea;
  const m = 14;
  win.setBounds({
    x: Math.round(wa.x + wa.width - config.width - m),
    y: Math.round(wa.y + wa.height - config.height - m),
    width: Math.round(config.width),
    height: Math.round(config.height),
  });
}

function createWindow() {
  win = new BrowserWindow({
    width: Math.round(config.width),
    height: Math.round(config.height),
    frame: false,
    transparent: false,
    backgroundColor: '#000000',
    resizable: true,
    alwaysOnTop: true,
    skipTaskbar: true,
    fullscreenable: false,
    // Never steal focus: the panel is something you glance at, and on macOS a focused
    // web view also swallows bare F-keys before the global shortcut sees them.
    focusable: process.platform !== 'darwin',
    show: false,
    webPreferences: {
      partition: 'persist:instagram',
      backgroundThrottling: false,
      contextIsolation: true,
      nodeIntegration: false,
    },
  });

  win.setAlwaysOnTop(true, 'floating');
  if (process.platform === 'darwin') win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  win.setMenuBarVisibility(false);

  const wc = win.webContents;
  wc.setUserAgent(wc.getUserAgent().replace(/Electron\/[^\s]+\s?/, ''));  // plain browser UA
  wc.setZoomFactor(config.zoom);

  wc.on('dom-ready', () => {
    wc.executeJavaScript(BRIDGE, true).catch(e => cfg.log('inject failed: ' + e.message));
    if (playerOn) setTimeout(() => call(`mute(${muted})`), 200);
  });

  // The page bridge logs through console so one source file works in both hosts.
  wc.on('console-message', (_e, _level, message) => {
    if (typeof message === 'string' && message.startsWith('[rc] ')) cfg.log('js: ' + message.slice(5));
  });

  wc.setWindowOpenHandler(({ url }) => { wc.loadURL(url); return { action: 'deny' }; });

  win.loadURL(REELS);
  place();
  win.showInactive();
  const b = win.getBounds();
  cfg.log(`panel at ${b.x},${b.y} ${b.width}x${b.height} (zoom ${config.zoom})`);
  screen.on('display-metrics-changed', place);
}

// ---------------------------------------------------------------- page calls

async function call(expr) {
  if (!win || win.isDestroyed()) return;
  const wc = win.webContents;
  const js = `(function(){ if (!window.__rc) return 'MISSING';
    try { window.__rc.${expr}; return 'ok'; } catch (e) { return 'ERR ' + e; } })()`;
  let res;
  try { res = await wc.executeJavaScript(js, true); }
  catch (e) { cfg.log('JS error in ' + expr + ': ' + e.message); return; }

  // A missing bridge means the script threw on this page load - every shortcut would
  // be silently dead. Reinject and take the call again rather than losing it.
  if (res === 'MISSING') {
    cfg.log('bridge missing on ' + wc.getURL() + ' - reinjecting, then ' + expr);
    await wc.executeJavaScript(BRIDGE, true).catch(e => cfg.log('reinject failed: ' + e.message));
    await wc.executeJavaScript(`window.__rc && window.__rc.${expr}`, true).catch(() => {});
  } else if (typeof res === 'string' && res.startsWith('ERR')) {
    cfg.log('JS threw in ' + expr + ': ' + res);
  }
}

// ---------------------------------------------------------------- actions

const actions = {
  next: () => call('next()'),
  like: () => call('like()'),
  save: () => call('save()'),
  savedMode: () => call('toggleMode()'),

  showHide: () => {
    if (!win) return;
    if (win.isVisible()) { call('active(false)'); win.hide(); }
    else { win.showInactive(); call('active(true)'); }
    cfg.log('toggle -> visible=' + win.isVisible());
    buildTray();
  },

  // Stopping releases the page entirely - nothing decoded, fetched or buffered. The
  // process stays resident because a global shortcut can only reach a running app.
  startStop: () => {
    if (!win) return;
    playerOn = !playerOn;
    if (playerOn) {
      win.showInactive();
      place();
      win.loadURL(REELS);
      cfg.log('player STARTED');
    } else {
      call('active(false)');
      win.hide();
      win.loadURL('about:blank');
      cfg.log('player STOPPED (page released)');
    }
    buildTray();
  },
};

// ---------------------------------------------------------------- shortcuts

function applyShortcuts() {
  globalShortcut.unregisterAll();
  bound = {};
  for (const name of ACTIONS) {
    const combo = config.keys[name] || cfg.DEFAULT_KEYS[name];
    const accel = cfg.toAccelerator(combo);
    if (!accel) { cfg.log(`config: '${combo}' is not a key I understand for '${name}' - skipped`); continue; }
    try {
      if (globalShortcut.register(accel, actions[name])) { bound[name] = combo; cfg.log(`shortcut: ${combo} -> ${name}`); }
      else cfg.log(`shortcut: ${combo} (${name}) was refused - another app probably owns it`);
    } catch (e) {
      cfg.log(`shortcut: ${combo} (${name}) failed - ${e.message}`);
    }
  }
  // On macOS a bare F-key sends a media action unless it has been remapped.
  if (process.platform === 'darwin') {
    const bare = Object.values(bound).filter(k => /^f([1-9]|1[0-2])$/i.test(k));
    if (bare.length) cfg.log(`config: bare F-keys in use (${bare.join(', ')}) - on macOS these need `
      + `the remap that install.sh sets up, or the system sends media keys instead`);
  }
  buildTray();
}

function watchConfig() {
  stamp = cfg.modified();
  setInterval(() => {
    const now = cfg.modified();
    if (now === stamp) return;
    stamp = now;
    config = cfg.load();
    cfg.log('config: reloaded');
    applyShortcuts();
    if (win) { win.webContents.setZoomFactor(config.zoom); place(); }
  }, 2000);
}

// ---------------------------------------------------------------- tray

function trayIcon() {
  // macOS wants a black template image it can invert; Windows and Linux trays are
  // usually dark, where a black icon is invisible.
  const file = process.platform === 'darwin' ? 'tray.png' : 'tray-light.png';
  const p = path.join(__dirname, 'assets', file);
  try {
    const img = nativeImage.createFromPath(p);
    if (!img.isEmpty()) { if (process.platform === 'darwin') img.setTemplateImage(true); return img; }
  } catch (e) { /* fall through */ }
  return nativeImage.createEmpty();
}

function key(name) { return bound[name] ? `   ${bound[name]}` : ''; }

function buildTray() {
  if (!tray) {
    tray = new Tray(trayIcon());
    tray.setToolTip('Reel Corner');
  }
  tray.setContextMenu(Menu.buildFromTemplate([
    { label: (playerOn ? 'Stop player' : 'Start player') + key('startStop'), click: actions.startStop },
    { type: 'separator' },
    { label: 'Like reel' + key('like'), click: actions.like },
    { label: 'Save reel' + key('save'), click: actions.save },
    { label: 'Next reel' + key('next'), click: actions.next },
    { label: 'Saved reels / Feed' + key('savedMode'), click: actions.savedMode },
    { type: 'separator' },
    { label: 'Open / Close panel' + key('showHide'), click: actions.showHide },
    { label: muted ? 'Turn sound on' : 'Mute',
      click: () => { muted = !muted; call(`mute(${muted})`); buildTray(); } },
    { type: 'separator' },
    { label: 'Start at login', type: 'checkbox',
      checked: app.getLoginItemSettings().openAtLogin,
      click: (item) => { app.setLoginItemSettings({ openAtLogin: item.checked }); } },
    { label: 'Change keys and size...', click: () => { cfg.load(); shell.openPath(cfg.FILE); } },
    { label: 'Open log', click: () => shell.openPath(cfg.LOG) },
    { type: 'separator' },
    { label: 'Log in to Instagram (wide window)', click: () => {
        if (!win) return;
        call('clean(false)');
        win.setFocusable(true);
        win.setBounds({ width: 1000, height: 760 });
        win.center();
        win.webContents.setZoomFactor(1);
        win.show();
        win.focus();
      } },
    { label: 'Back to corner', click: () => {
        if (!win) return;
        call('clean(true)');
        if (process.platform === 'darwin') win.setFocusable(false);
        win.webContents.setZoomFactor(config.zoom);
        place();
        win.showInactive();
      } },
    { label: 'Reload Instagram', click: () => win && win.loadURL(REELS) },
    { type: 'separator' },
    { label: 'Quit Reel Corner', click: () => { app.isQuitting = true; app.quit(); } },
  ]));
}

// ---------------------------------------------------------------- lifecycle

const single = app.requestSingleInstanceLock();
if (!single) {
  app.quit();
} else {
  app.on('second-instance', () => { if (win) win.showInactive(); });

  app.whenReady().then(() => {
    if (process.platform === 'darwin' && app.dock) app.dock.hide();
    muted = config.startMuted;
    cfg.log('=== Reel Corner (Electron) started on ' + process.platform + ' ===');
    // Start at login by default - the whole point is that it is already there.
    // Unticking it in the tray menu sticks.
    if (!app.getLoginItemSettings().openAtLogin && !fs.existsSync(path.join(cfg.dir(), '.loginitem'))) {
      try {
        app.setLoginItemSettings({ openAtLogin: true });
        fs.writeFileSync(path.join(cfg.dir(), '.loginitem'), 'asked once');
        cfg.log('start at login: enabled (turn it off in the tray menu)');
      } catch (e) { cfg.log('start at login: could not set - ' + e.message); }
    }
    createWindow();
    applyShortcuts();
    watchConfig();
  });

  app.on('window-all-closed', () => { /* stay resident for the shortcuts */ });
  app.on('will-quit', () => globalShortcut.unregisterAll());
}
