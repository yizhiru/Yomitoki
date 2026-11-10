const { contextBridge, ipcRenderer } = require('electron');
const job = process.argv.find(value => value.startsWith('--ebook-job='))?.slice(12);
if (!/^[0-9a-f-]{36}$/.test(job || '')) throw new Error('Invalid import job');
contextBridge.exposeInMainWorld('ebookImport', {
  input: () => ipcRenderer.invoke('ebook:input:' + job),
  result: result => ipcRenderer.send('ebook:result:' + job, result)
});
