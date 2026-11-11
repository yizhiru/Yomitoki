const fs = require('node:fs/promises');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { randomUUID } = require('node:crypto');
let active;

async function readEbook(file, { signal, parent, timeoutMs = 30000 } = {}) {
  signal?.throwIfAborted();
  const { BrowserWindow, ipcMain } = require('electron');
  if (!BrowserWindow) throw new Error('电子书导入需要在应用内运行。');
  if (active) throw new Error('已有电子书正在导入，请等待或取消。');
  const id = randomUUID(), inputChannel = 'ebook:input:' + id, resultChannel = 'ebook:result:' + id;
  const kind = path.extname(file).slice(1).toUpperCase();
  const entry = path.join(__dirname, 'ebook-import/host.html');
  const allowed = new Set(['host.html', 'worker.mjs', 'zip.mjs', 'text.mjs', 'mdx.mjs', 'yomitan.mjs'].map(name => pathToFileURL(path.join(__dirname, 'ebook-import', name)).href));
  for (const relative of ['foliate/epub.js', 'foliate/epubcfi.js', 'foliate/mobi.js', 'fflate/fflate.mjs']) allowed.add(pathToFileURL(path.join(__dirname, 'vendor', relative)).href);
  const host = new BrowserWindow({ show: false, parent, webPreferences: {
    preload: path.join(__dirname, 'ebook-import/preload.cjs'), contextIsolation: true, sandbox: true, nodeIntegration: false,
    partition: 'ebook-import-' + id, additionalArguments: ['--ebook-job=' + id]
  } });
  active = host;
  return new Promise((resolve, reject) => {
    let settled = false;
    const finish = (error, sections) => {
      if (settled) return;
      settled = true; clearTimeout(timer); signal?.removeEventListener('abort', abort);
      ipcMain.removeHandler(inputChannel); ipcMain.removeListener(resultChannel, result);
      if (active === host) active = null;
      if (!host.isDestroyed()) host.destroy();
      error ? reject(error) : resolve(sections);
    };
    const abort = () => finish(new Error('已取消导入。'));
    const timer = setTimeout(() => finish(new Error('电子书导入超时，请拆分书籍或检查文件。')), timeoutMs);
    const trusted = event => !host.isDestroyed() && event.sender === host.webContents
      && event.senderFrame === host.webContents.mainFrame && event.senderFrame.url === pathToFileURL(entry).href;
    ipcMain.handle(inputChannel, async event => {
      if (!trusted(event)) throw new Error('无效导入来源。');
      const info = await fs.stat(file);
      if (!info.isFile() || info.size > 300000000) throw new Error('文件无效或超过 300 MB。');
      const bytes = await fs.readFile(file, { signal });
      if (settled) throw new Error('已取消导入。');
      return { bytes: new Uint8Array(bytes), kind, name: path.basename(file) };
    });
    const result = (event, value) => {
      if (!trusted(event)) return;
      if (!value?.ok) { finish(new Error(typeof value?.error === 'string' ? value.error.slice(0, 300) : '电子书导入失败。')); return; }
      if (!Array.isArray(value.sections) || !value.sections.length || value.sections.length > 10000
        || !value.sections.every(text => typeof text === 'string')
        || value.sections.reduce((sum, text) => sum + text.length, 0) > ((kind === 'MDX' || kind === 'ZIP') ? 100000000 : 10000000)) { finish(new Error('电子书正文无效或内容过多。')); return; }
      finish(null, value.sections);
    };
    ipcMain.on(resultChannel, result);
    signal?.addEventListener('abort', abort, { once: true });
    if (signal?.aborted) { abort(); return; }
    host.webContents.session.setPermissionRequestHandler((_webContents, _permission, callback) => callback(false));
    host.webContents.session.webRequest.onBeforeRequest((details, callback) => callback({ cancel: !allowed.has(details.url) }));
    host.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
    host.webContents.on('will-navigate', event => event.preventDefault());
    host.webContents.on('render-process-gone', () => finish(new Error('电子书解析进程已退出，请检查文件后重试。')));
    host.on('unresponsive', () => finish(new Error('电子书解析耗时过长，已停止导入。')));
    host.on('closed', () => finish(new Error('已取消导入。')));
    host.loadFile(entry).catch(() => finish(new Error('内置电子书解析模块无法加载，请重新安装完整应用。')));
  });
}
module.exports = { readEbook };
