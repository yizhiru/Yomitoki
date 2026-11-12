const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('yomitoki', {
  call: async (action, payload) => {
    const response = await ipcRenderer.invoke('yomitoki', action, payload);
    if (!response.ok) throw new Error(response.error);
    return response.value;
  },
  flushReadingProgress: input => ipcRenderer.sendSync('yomitoki:flush-reading-progress', input),
  onProgress: callback => {
    const handler = (_event, progress) => callback(progress);
    ipcRenderer.on('model-progress', handler);
    return () => ipcRenderer.removeListener('model-progress', handler);
  },
  onImport: callback => { ipcRenderer.on('import-request', () => callback()); },
  onModelDefinition: callback => { ipcRenderer.on('model-definition-request', () => callback()); }
});
