const fs = require('fs');
const path = require('path');
const { app, BrowserWindow, Tray, Menu, nativeImage, nativeTheme, ipcMain, clipboard } = require('electron');

const owlHostDir = path.dirname(process.resourcesPath);
const runtimeDir = path.dirname(owlHostDir);
const rootDir = path.dirname(runtimeDir);
const iconHelper = path.join(runtimeDir, 'dsh-taskbar-icon.exe');
const customIcon = path.join(rootDir, 'icon', 'deepseek.png');
const activationSignal = path.join(runtimeDir, 'dsh-activate.signal');
const HOME = 'http://127.0.0.1:3080';

function readConfig() {
  const cfg = path.join(process.resourcesPath, 'app', 'dsh-desktop.json');
  try {
    const parsed = JSON.parse(fs.readFileSync(cfg, 'utf8'));
    if (parsed && parsed.url) {
      parsed.url = parsed.url.replace(/\/$/, '');
      return parsed;
    }
  } catch (e) {}
  return { url: HOME };
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

function loadTrayIcon() {
  const ico = iconFile('icon.ico');
  const png = iconFile('icon.png');
  let img = nativeImage.createFromPath(fs.existsSync(ico) ? ico : (fs.existsSync(png) ? png : customIcon));
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

function quitAll() {
  allowQuit = true;
  stopTerminal();
  if (tray) {
    tray.destroy();
    tray = null;
  }
  app.quit();
}

let mainWindow = null;
let tray = null;
let allowQuit = false;
let appReady = false;
let activationTimer = null;
let lastActivationSignal = '';
const terminalProcesses = new Map();
let desktopConfig = null;

try { app.setName('DSH'); } catch (e) {}

function showWindow() {
  if (!mainWindow || mainWindow.isDestroyed()) return;
  if (mainWindow.isMinimized()) mainWindow.restore();
  mainWindow.show();
  mainWindow.focus();
  setTaskbarBadge(true);
}

function readActivationSignal() {
  try { return fs.readFileSync(activationSignal, 'utf8'); } catch (e) { return ''; }
}

function startActivationWatcher() {
  if (activationTimer) return;
  lastActivationSignal = readActivationSignal();
  activationTimer = setInterval(() => {
    const signal = readActivationSignal();
    if (!signal || signal === lastActivationSignal) return;
    lastActivationSignal = signal;
    showWindow();
  }, 200);
  activationTimer.unref();
}

function stopActivationWatcher() {
  if (!activationTimer) return;
  clearInterval(activationTimer);
  activationTimer = null;
}

function terminalSize(value) {
  const number = Number(value);
  return Number.isFinite(number) ? Math.max(1, Math.min(500, Math.floor(number))) : 80;
}

function isMainSender(sender) {
  return mainWindow && !mainWindow.isDestroyed() && sender === mainWindow.webContents;
}

function validTerminalId(id) {
  return typeof id === 'string' && /^[a-zA-Z0-9_-]{1,64}$/.test(id);
}

function stopTerminal(id) {
  const ids = validTerminalId(id) ? [id] : Array.from(terminalProcesses.keys());
  for (const terminalId of ids) {
    const record = terminalProcesses.get(terminalId);
    terminalProcesses.delete(terminalId);
    if (!record) continue;
    const pid = record.process.pid;
    try { record.process.kill(); } catch (e) {}
    if (pid) {
      try {
        require('child_process').execFileSync('taskkill.exe', ['/PID', String(pid), '/T', '/F'], {
          windowsHide: true,
          stdio: 'ignore',
          timeout: 3000
        });
      } catch (e) {}
    }
  }
}

function terminalNode() {
  const localAppData = process.env.LOCALAPPDATA;
  const runtimeRoot = localAppData && path.join(localAppData, 'OpenAI', 'Codex', 'runtimes', 'cua_node');
  if (runtimeRoot && fs.existsSync(runtimeRoot)) {
    const candidates = fs.readdirSync(runtimeRoot, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => path.join(runtimeRoot, entry.name, 'bin', 'node.exe'))
      .filter((candidate) => fs.existsSync(candidate))
      .sort((left, right) => fs.statSync(right).mtimeMs - fs.statSync(left).mtimeMs);
    if (candidates.length > 0) return candidates[0];
  }
  return desktopConfig && desktopConfig.node;
}

function terminalEnvironment() {
  const dsh = path.join(rootDir, 'dsh-runtime');
  const dshHome = path.join(dsh, '.dshhome');
  const toolsBin = path.join(dsh, 'tools', 'bin');
  // The WindowsApps Node is executable only from an Appx package context.
  // The embedded terminal runs in owl-host, so use ChatGPT's user-runtime copy.
  const node = terminalNode();
  if (!node || !fs.existsSync(node)) throw new Error('ChatGPT Node is unavailable.');
  fs.mkdirSync(path.join(dshHome, 'corepack'), { recursive: true });
  const env = Object.assign({}, process.env);
  for (const key of Object.keys(env)) {
    if (key.toUpperCase() === 'PATH') delete env[key];
  }
  Object.assign(env, {
    DSH_HOME: dshHome,
    DSH_ENTRY: path.join(dsh, 'apps', 'cli', 'lib', 'bin.js'),
    DSH_NODE: node,
    DSH_RUNTIME: dsh,
    COREPACK_HOME: path.join(dshHome, 'corepack'),
    COREPACK_ENABLE_DOWNLOAD_PROMPT: '0',
    COREPACK_NPM_REGISTRY: 'https://registry.npmmirror.com',
    PATH: [toolsBin, path.dirname(node), process.env.Path || process.env.PATH || ''].join(';')
  });
  return {
    cwd: process.env.USERPROFILE && fs.existsSync(process.env.USERPROFILE) ? process.env.USERPROFILE : dsh,
    env
  };
}

ipcMain.handle('dsh-terminal:start', (event, request) => {
  if (!isMainSender(event.sender)) throw new Error('Terminal request denied.');
  const id = request && request.id;
  if (!validTerminalId(id)) throw new Error('Invalid terminal id.');
  const existing = terminalProcesses.get(id);
  if (existing && existing.owner === event.sender) return { running: true, cwd: existing.cwd };
  if (terminalProcesses.size >= 8) throw new Error('Terminal tab limit reached.');
  const runtime = terminalEnvironment();
  const pty = require(path.join(rootDir, 'dsh-runtime', 'node_modules', 'node-pty'));
  const shell = process.env.ComSpec || path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'cmd.exe');
  const shellPath = [path.join(rootDir, 'dsh-runtime', 'tools', 'bin'), path.dirname(runtime.env.DSH_NODE)];
  const child = pty.spawn(shell, `/D /K set "PATH=${shellPath.join(';')};%PATH%"`, {
    name: 'xterm-256color',
    cols: terminalSize(request && request.cols),
    rows: terminalSize(request && request.rows),
    cwd: runtime.cwd,
    env: runtime.env,
    useConptyDll: true
  });
  const record = { process: child, owner: event.sender, cwd: runtime.cwd };
  terminalProcesses.set(id, record);
  child.onData((data) => {
    if (!record.owner.isDestroyed()) record.owner.send('dsh-terminal:data', id, data);
  });
  child.onExit(({ exitCode }) => {
    if (terminalProcesses.get(id) === record) {
      terminalProcesses.delete(id);
      if (!record.owner.isDestroyed()) record.owner.send('dsh-terminal:exit', id, exitCode);
    }
  });
  return { running: true, cwd: runtime.cwd };
});

ipcMain.on('dsh-terminal:write', (event, request) => {
  if (!isMainSender(event.sender) || !request || !validTerminalId(request.id) || typeof request.data !== 'string') return;
  const record = terminalProcesses.get(request.id);
  if (record && record.owner === event.sender && request.data.length <= 65536) record.process.write(request.data);
});

ipcMain.handle('dsh-terminal:clipboard-read', (event) => {
  if (!isMainSender(event.sender)) return '';
  return clipboard.readText();
});

ipcMain.handle('dsh-terminal:clipboard-write', (event, text) => {
  if (!isMainSender(event.sender) || typeof text !== 'string' || text.length > 1048576) return false;
  clipboard.writeText(text);
  return true;
});

ipcMain.on('dsh-terminal:resize', (event, request) => {
  if (!isMainSender(event.sender) || !request || !validTerminalId(request.id)) return;
  const record = terminalProcesses.get(request.id);
  if (!record || record.owner !== event.sender) return;
  try { record.process.resize(terminalSize(request.cols), terminalSize(request.rows)); } catch (e) {}
});

ipcMain.on('dsh-terminal:stop', (event, id) => {
  const record = validTerminalId(id) && terminalProcesses.get(id);
  if (isMainSender(event.sender) && record && record.owner === event.sender) stopTerminal(id);
});

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

async function injectTerminalPanel(contents) {
  if (!contents || contents.isDestroyed()) return;
  const appDir = path.join(process.resourcesPath, 'app');
  try {
    const css = fs.readFileSync(path.join(appDir, 'terminal.css'), 'utf8');
    await contents.executeJavaScript(`(() => {
      let style = document.getElementById('dsh-terminal-style');
      if (!style) {
        style = document.createElement('style');
        style.id = 'dsh-terminal-style';
        (document.head || document.documentElement).appendChild(style);
      }
      style.textContent = ${JSON.stringify(css)};
    })()`);
  } catch (e) {
    console.error('Failed to inject terminal styles:', e);
  }
  try {
    await contents.executeJavaScript(fs.readFileSync(path.join(appDir, 'terminal-ui.js'), 'utf8'));
  } catch (e) {
    console.error('Failed to inject terminal button:', e);
  }
  try {
    const xtermCss = fs.readFileSync(path.join(appDir, 'terminal-assets', 'xterm.css'), 'utf8');
    await contents.executeJavaScript(`(() => {
      let style = document.getElementById('dsh-xterm-style');
      if (!style) {
        style = document.createElement('style');
        style.id = 'dsh-xterm-style';
        (document.head || document.documentElement).appendChild(style);
      }
      style.textContent = ${JSON.stringify(xtermCss)};
    })()`);
    await contents.executeJavaScript(fs.readFileSync(path.join(appDir, 'terminal-assets', 'xterm.js'), 'utf8') + '\n;undefined;');
    await contents.executeJavaScript(fs.readFileSync(path.join(appDir, 'terminal-assets', 'addon-fit.js'), 'utf8') + '\n;undefined;');
  } catch (e) {
    console.error('Failed to load terminal renderer:', e);
  }
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
  stopActivationWatcher();
  stopTerminal();
});

app.whenReady().then(async () => {
  desktopConfig = readConfig();
  const url = desktopConfig.url;
  const icon = loadIcon();
  createTray(loadTrayIcon());
  const win = new BrowserWindow({
    width: 1280,
    height: 840,
    show: true,
    autoHideMenuBar: true,
    title: 'DSH',
    backgroundColor: nativeTheme.shouldUseDarkColors ? '#202124' : '#ffffff',
    icon: icon.isEmpty() ? undefined : icon,
    webPreferences: {
      sandbox: false,
      contextIsolation: true,
      preload: path.join(process.resourcesPath, 'app', 'preload.js')
    }
  });
  mainWindow = win;
  startActivationWatcher();
  win.webContents.once('destroyed', stopTerminal);
  lockHome(win, url);
  win.webContents.on('did-finish-load', () => {
    const current = win.webContents.getURL();
    if (appReady && !isHome(current, url)) goHome(win, url);
    else if (appReady) {
      try { win.webContents.clearHistory(); } catch (e) {}
    }
    injectTerminalPanel(win.webContents);
  });
  win.on('ready-to-show', () => { win.show(); win.focus(); setTaskbarBadge(true); });
  win.on('show', () => setTaskbarBadge(true));
  win.on('hide', () => {
    if (!allowQuit) setTaskbarBadge(false);
  });
  win.on('close', (e) => {
    if (allowQuit) return;
    e.preventDefault();
    win.hide();
  });
  await loadApp(win, url);
});
