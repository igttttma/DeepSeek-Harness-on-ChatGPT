const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('dshTerminal', {
  start: (request) => ipcRenderer.invoke('dsh-terminal:start', request),
  write: (id, data) => ipcRenderer.send('dsh-terminal:write', { id, data }),
  readClipboard: () => ipcRenderer.invoke('dsh-terminal:clipboard-read'),
  writeClipboard: (text) => ipcRenderer.invoke('dsh-terminal:clipboard-write', text),
  resize: (id, size) => ipcRenderer.send('dsh-terminal:resize', { id, ...size }),
  stop: (id) => ipcRenderer.send('dsh-terminal:stop', id),
  onData: (callback) => {
    const listener = (_event, id, data) => callback(id, data);
    ipcRenderer.on('dsh-terminal:data', listener);
    return () => ipcRenderer.removeListener('dsh-terminal:data', listener);
  },
  onExit: (callback) => {
    const listener = (_event, id, code) => callback(id, code);
    ipcRenderer.on('dsh-terminal:exit', listener);
    return () => ipcRenderer.removeListener('dsh-terminal:exit', listener);
  }
});
