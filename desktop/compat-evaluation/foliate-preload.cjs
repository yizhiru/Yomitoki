const {contextBridge, ipcRenderer} = require('electron');
contextBridge.exposeInMainWorld('evaluation', {
  cases: () => ipcRenderer.invoke('eval:cases'),
  bytes: id => ipcRenderer.invoke('eval:bytes', id),
  result: (id, result) => ipcRenderer.invoke('eval:result', id, result),
  done: () => ipcRenderer.send('eval:done')
});
