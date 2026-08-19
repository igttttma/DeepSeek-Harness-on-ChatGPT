(() => {
  if (document.getElementById('dsh-terminal-launch')) return;
  const terminalIcon = '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="3.5" y="4.5" width="17" height="15" rx="2"></rect><path d="m7.5 9 3 2.5-3 2.5"></path><path d="M12.5 15h4"></path></svg>';
  const closeIcon = '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="m4 4 8 8M12 4l-8 8"></path></svg>';
  const addIcon = '<svg viewBox="0 0 20 20" aria-hidden="true"><path d="M10 4v12M4 10h12"></path></svg>';
  const button = document.createElement('button');
  button.id = 'dsh-terminal-launch'; button.type = 'button'; button.innerHTML = terminalIcon;
  button.title = 'Open DSH terminal'; button.setAttribute('aria-label', button.title); button.setAttribute('aria-pressed', 'false');
  const panel = document.createElement('aside'); panel.id = 'dsh-terminal-panel'; panel.hidden = true; panel.setAttribute('aria-label', 'DSH terminals');
  const resizer = document.createElement('div'); resizer.id = 'dsh-terminal-resizer'; resizer.setAttribute('role', 'separator'); resizer.title = 'Resize terminal';
  const header = document.createElement('div'); header.id = 'dsh-terminal-header';
  const tabList = document.createElement('div'); tabList.id = 'dsh-terminal-tabs'; tabList.setAttribute('role', 'tablist');
  const addButton = document.createElement('button'); addButton.id = 'dsh-terminal-add'; addButton.type = 'button'; addButton.title = 'New terminal'; addButton.setAttribute('aria-label', addButton.title); addButton.innerHTML = addIcon;
  header.append(tabList, addButton);
  const views = document.createElement('div'); views.id = 'dsh-terminal-views'; panel.append(resizer, header, views); document.documentElement.append(panel, button);
  const savedWidth = Number(localStorage.getItem('dsh-terminal-panel-width'));
  if (Number.isFinite(savedWidth) && savedWidth >= 320) document.documentElement.style.setProperty('--dsh-terminal-panel-width', `${savedWidth}px`);
  const colorScheme = window.matchMedia('(prefers-color-scheme: dark)');
  const theme = () => colorScheme.matches ? { background: '#1f2023', foreground: '#f1f1f1', cursor: '#f1f1f1', selectionBackground: '#4a4b50', black: '#1f2023', brightBlack: '#77787d' } : { background: '#f7f7f8', foreground: '#242424', cursor: '#242424', selectionBackground: '#c9d7ee', black: '#242424', brightBlack: '#676767' };
  const tabs = new Map(); let activeId = null; let sequence = 0; let open = false; let dragging = false;
  const setOpen = (value) => { open = value; panel.hidden = !open; document.documentElement.classList.toggle('dsh-terminal-open', open); button.setAttribute('aria-pressed', String(open)); button.title = open ? 'Close DSH terminal' : 'Open DSH terminal'; button.setAttribute('aria-label', button.title); if (open) requestAnimationFrame(fitActive); };
  const fitActive = () => { const tab = tabs.get(activeId); if (!open || !tab) return; try { tab.fit.fit(); } catch (error) {} };
  const copy = async (tab) => { if (!tab?.terminal.hasSelection()) return; try { await window.dshTerminal.writeClipboard(tab.terminal.getSelection()); } catch (error) {} };
  const paste = async (tab) => { if (!tab) return; try { const text = await window.dshTerminal.readClipboard(); if (text) tab.terminal.paste(text); } catch (error) {} };
  const activate = (id) => { if (!tabs.has(id)) return; activeId = id; for (const [tabId, tab] of tabs) { const active = tabId === id; tab.tab.classList.toggle('active', active); tab.tab.setAttribute('aria-selected', String(active)); tab.view.hidden = !active; } requestAnimationFrame(fitActive); };
  const close = (id) => { const tab = tabs.get(id); if (!tab) return; const ids = [...tabs.keys()]; const index = ids.indexOf(id); window.dshTerminal.stop(id); tab.terminal.dispose(); tab.tab.remove(); tab.view.remove(); tabs.delete(id); if (!tabs.size) { activeId = null; setOpen(false); } else if (activeId === id) activate(ids[index + 1] || ids[index - 1]); };
  const waitForRenderer = async () => { for (let attempt = 0; attempt < 80; attempt++) { if (window.Terminal && window.FitAddon && window.dshTerminal) return true; await new Promise((resolve) => setTimeout(resolve, 100)); } return false; };
  const create = async () => {
    if (tabs.size >= 8) return; setOpen(true); if (!await waitForRenderer()) { setOpen(false); return; }
    const id = `terminal_${Date.now()}_${++sequence}`; const tab = document.createElement('div'); tab.className = 'dsh-terminal-tab'; tab.setAttribute('role', 'tab'); tab.setAttribute('aria-selected', 'false');
    const activateButton = document.createElement('button'); activateButton.type = 'button'; activateButton.className = 'dsh-terminal-tab-activate'; activateButton.innerHTML = `${terminalIcon}<span>Terminal</span>`;
    const closeButton = document.createElement('button'); closeButton.type = 'button'; closeButton.className = 'dsh-terminal-tab-close'; closeButton.title = 'Close terminal'; closeButton.setAttribute('aria-label', closeButton.title); closeButton.innerHTML = closeIcon; tab.append(activateButton, closeButton);
    const view = document.createElement('div'); view.className = 'dsh-terminal-view'; view.hidden = true; views.append(view); tabList.append(tab);
    const terminal = new window.Terminal({ cursorBlink: true, cursorStyle: 'bar', cursorWidth: 2, fontFamily: 'Cascadia Mono, Consolas, monospace', fontSize: 13, lineHeight: 1.18, scrollback: 3000, theme: theme() }); const fit = new window.FitAddon.FitAddon(); terminal.loadAddon(fit); terminal.open(view);
    const record = { id, terminal, fit, tab, view }; tabs.set(id, record); activateButton.onclick = () => activate(id); closeButton.onclick = (event) => { event.stopPropagation(); close(id); };
    terminal.attachCustomKeyEventHandler((event) => { const command = event.ctrlKey || event.metaKey; const key = event.key.toLowerCase(); if (command && key === 'c' && terminal.hasSelection()) { event.preventDefault(); void copy(record); return false; } if (command && key === 'v') { event.preventDefault(); void paste(record); return false; } return true; });
    view.addEventListener('contextmenu', (event) => { event.preventDefault(); if (terminal.hasSelection()) void copy(record); else void paste(record); terminal.focus(); }, true);
    terminal.onData((data) => window.dshTerminal.write(id, data)); terminal.onResize(({ cols, rows }) => window.dshTerminal.resize(id, { cols, rows })); activate(id);
    try { const result = await window.dshTerminal.start({ id, cols: terminal.cols, rows: terminal.rows }); const cwd = result?.cwd || 'Terminal'; activateButton.querySelector('span').textContent = cwd.length > 30 ? `...${cwd.slice(-27)}` : cwd; tab.title = cwd; } catch (error) { terminal.writeln(`Unable to start terminal: ${error.message || error}`); }
  };
  window.dshTerminal.onData((id, data) => tabs.get(id)?.terminal.write(data)); window.dshTerminal.onExit((id, code) => { const tab = tabs.get(id); if (tab) tab.terminal.writeln(`\r\n[process exited with code ${code}]`); });
  const resizeObserver = new ResizeObserver(fitActive); resizeObserver.observe(panel); colorScheme.addEventListener('change', () => { for (const tab of tabs.values()) tab.terminal.options.theme = theme(); fitActive(); });
  resizer.onpointerdown = (event) => { dragging = true; resizer.setPointerCapture(event.pointerId); document.documentElement.classList.add('dsh-terminal-resizing'); };
  resizer.onpointermove = (event) => { if (!dragging) return; const width = Math.max(320, Math.min(window.innerWidth - 320, window.innerWidth - event.clientX)); document.documentElement.style.setProperty('--dsh-terminal-panel-width', `${width}px`); fitActive(); };
  const finishResize = (event) => { if (!dragging) return; dragging = false; try { resizer.releasePointerCapture(event.pointerId); } catch (error) {} document.documentElement.classList.remove('dsh-terminal-resizing'); localStorage.setItem('dsh-terminal-panel-width', String(Math.round(panel.getBoundingClientRect().width))); fitActive(); };
  resizer.onpointerup = finishResize; resizer.onpointercancel = finishResize;
  addButton.onclick = () => void create(); button.onclick = () => { if (!open && !tabs.size) void create(); else setOpen(!open); };
  window.addEventListener('beforeunload', () => { for (const id of tabs.keys()) window.dshTerminal.stop(id); }, { once: true });
})();
