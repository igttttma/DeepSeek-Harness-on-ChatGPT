const fs = require('fs');
const path = require('path');
const { app, BrowserWindow, Tray, Menu, nativeImage } = require('electron');

const owlHostDir = path.dirname(process.resourcesPath);
const runtimeDir = path.dirname(owlHostDir);
const rootDir = path.dirname(runtimeDir);
const iconHelper = path.join(runtimeDir, 'dsh-taskbar-icon.exe');
const launcher = path.join(rootDir, 'DeepSeek Harness (on ChatGPT).exe');
const customIcon = path.join(rootDir, 'icon', 'deepseek.png');
const HOME = 'http://127.0.0.1:3080';

function readUrl() {
  const cfg = path.join(process.resourcesPath, 'app', 'dsh-desktop.json');
  try {
    const parsed = JSON.parse(fs.readFileSync(cfg, 'utf8'));
    if (parsed && parsed.url) return parsed.url.replace(/\/$/, '');
  } catch (e) {}
  return HOME;
}

function iconFile(name) {
  return path.join(process.resourcesPath, 'app', name);
}

function loadIcon() {
  const ico = iconFile('icon.ico');
  const png = iconFile('icon.png');
  let img = nativeImage.createFromPath(fs.existsSync(customIcon) ? customIcon : (fs.existsSync(ico) ? ico : png));
  if (img.isEmpty() && fs.existsSync(png)) img = nativeImage.createFromPath(png);
  return img;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function originOf(url) {
  try { return new URL(url).origin; } catch (e) { return ''; }
}

function isHome(url, home) {
  return originOf(url) === originOf(home);
}

let overlayOn = false;
function runIconHelper(cmd) {
  try {
    require('child_process').spawn(iconHelper, [cmd === 'restore' ? 'restore' : 'hold'], {
      stdio: 'ignore',
      windowsHide: true
    }).unref();
  } catch (e) {}
}

function setTaskbarBadge(on) {
  if (on) {
    if (overlayOn) return;
    overlayOn = true;
    runIconHelper('hold');
    return;
  }
  overlayOn = false;
  runIconHelper('restore');
}

function stopDshBackend() {
  try {
    require('child_process').execFileSync(launcher, ['stop-backend'], { windowsHide: true, timeout: 8000 });
  } catch (e) {}
}

function quitAll() {
  allowQuit = true;
  setTaskbarBadge(false);
  stopDshBackend();
  app.quit();
}

let mainWindow = null;
let tray = null;
let allowQuit = false;
let appReady = false;

try { app.setName('DSH'); } catch (e) {}

function showWindow() {
  if (!mainWindow || mainWindow.isDestroyed()) return;
  if (mainWindow.isMinimized()) mainWindow.restore();
  mainWindow.show();
  mainWindow.focus();
}

function createTray(icon) {
  if (tray) return;
  tray = new Tray(icon.isEmpty() ? nativeImage.createEmpty() : icon);
  tray.setToolTip('DSH');
  tray.setContextMenu(Menu.buildFromTemplate([
    { label: 'Open DSH', click: showWindow },
    { type: 'separator' },
    { label: 'Quit DSH', click: quitAll }
  ]));
  tray.on('click', showWindow);
}

function goHome(win, home) {
  if (!win || win.isDestroyed()) return;
  if (isHome(win.webContents.getURL(), home)) return;
  win.loadURL(home).catch(() => {});
}

function lockHome(win, home) {
  win.on('app-command', (e, cmd) => {
    if (cmd === 'browser-backward' || cmd === 'browser-forward') {
      e.preventDefault();
      if (appReady) goHome(win, home);
    }
  });
  win.webContents.on('will-navigate', (e, target) => {
    if (!isHome(target, home)) e.preventDefault();
  });
  win.webContents.on('will-redirect', (e, target) => {
    if (!isHome(target, home)) e.preventDefault();
  });
  win.webContents.on('did-navigate', (_e, target) => {
    if (appReady && !isHome(target, home)) goHome(win, home);
  });
  win.webContents.on('did-navigate-in-page', (_e, target) => {
    if (appReady && !isHome(target, home)) goHome(win, home);
  });
  win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
}

async function loadApp(win, url) {
  for (let i = 0; i < 40; i++) {
    try {
      await win.loadURL(url);
      appReady = true;
      try { win.webContents.clearHistory(); } catch (e) {}
      return;
    } catch (e) {
      await sleep(500);
    }
  }
}

app.on('window-all-closed', (e) => {
  if (!allowQuit && e && e.preventDefault) e.preventDefault();
});
app.on('before-quit', () => {
  allowQuit = true;
  setTaskbarBadge(false);
  stopDshBackend();
});

app.whenReady().then(async () => {
  const url = readUrl();
  const icon = loadIcon();
  createTray(icon);
  const win = new BrowserWindow({
    width: 1280,
    height: 840,
    show: true,
    autoHideMenuBar: true,
    title: 'DSH',
    backgroundColor: '#071018',
    icon: icon.isEmpty() ? undefined : icon,
    webPreferences: { sandbox: false, contextIsolation: true }
  });
  mainWindow = win;
  lockHome(win, url);
  win.webContents.on('did-finish-load', () => {
    const current = win.webContents.getURL();
    if (appReady && !isHome(current, url)) goHome(win, url);
    else if (appReady) {
      try { win.webContents.clearHistory(); } catch (e) {}
    }
  });
  win.on('ready-to-show', () => { win.show(); win.focus(); setTaskbarBadge(true); });
  win.on('show', () => setTaskbarBadge(true));
  win.on('hide', () => setTaskbarBadge(false));
  win.on('close', (e) => {
    if (allowQuit) return;
    e.preventDefault();
    win.hide();
  });
  await loadApp(win, url);
});
