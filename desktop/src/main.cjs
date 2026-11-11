const { app, BrowserWindow, ipcMain, dialog, shell, safeStorage, Menu } = require('electron');
const fs = require('node:fs/promises');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { randomUUID } = require('node:crypto');
const { Store, exportWords } = require('./store.cjs');
const { Dictionary, ImportedDictionary, selectionLevel } = require('./dictionary.cjs');
const { readBook } = require('./imports.cjs');
const { readEbook } = require('./ebook-import.cjs');
const { endpoint, completion, decodeAnalysis, decodeDefinition, prompts } = require('./models.cjs');
const { LocalEngine, MODEL, validateModel, downloadModel } = require('./translation.cjs');

app.setName('Yomitoki');
if (process.platform === 'win32') app.setAppUserModelId('org.yizhiru.yomitoki');
if (process.env.YOMITOKI_DATA_DIRECTORY) app.setPath('userData', process.env.YOMITOKI_DATA_DIRECTORY);
let window, store, dictionary, engine, ready, request, download, generation = 0, lastLookup, importing, quitting = false;
let importedDictionary, dictionaryMessage, updatingDictionaries = false;
const entryFile = path.join(__dirname, 'renderer/index.html');
const resources = () => app.isPackaged ? path.join(process.resourcesPath, 'reading') : path.join(__dirname, '../.build/resources');
const state = () => ({ ...store.publicState(), version: app.getVersion(), platform: process.platform, translationRuntime: engine.status(),
  selectedDictionary: importedDictionary?.info.id || '', dictionaryMessage });
const cancel = () => { generation++; request?.abort(); request = null; };
function selected(input) {
  const book = store.book, text = book.pages[book.page];
  if (!input || input.bookID !== book.id || input.page !== book.page) throw new Error('阅读位置已改变，请重新选中文字。');
  const level = selectionLevel(text, input.start, input.end, dictionary.tokenizer, form => Boolean(importedDictionary?.meaning([form])) || dictionary.entries(form).length > 0);
  if (level === 'none' || input.end - input.start > 8000) throw new Error('请选中有效文字（最多 8000 字符）。');
  return { text: text.slice(input.start, input.end), before: text.slice(Math.max(0, input.start - 1600), input.start),
    after: text.slice(input.end, input.end + 1600), level, bookID: book.id, page: book.page,
    start: input.start, end: input.end, filename: book.name, kind: book.kind };
}
function sourceKey(selection) { return [selection.bookID, selection.page, selection.start, selection.end, selection.text].join('|'); }
async function apiKey() {
  const blob = store.data.settings.keyBlob;
  if (!blob) throw new Error('请先在设置中保存 API key。');
  return safeStorage.decryptString(Buffer.from(blob, 'base64'));
}
async function saveSettings(input) {
  const current = store.data.settings;
  const numeric = (key, min, max) => {
    const value = Number(input[key] ?? current[key]);
    if (!Number.isFinite(value) || value < min || value > max) throw new Error('显示设置数值无效。');
    return value;
  };
  const next = { fontSize: numeric('fontSize', 16, 40), definitionSize: numeric('definitionSize', 14, 30),
    sidebarWidth: numeric('sidebarWidth', 160, 400), detailWidth: numeric('detailWidth', 260, 800),
    singleClick: input.singleClick === undefined ? current.singleClick : Boolean(input.singleClick),
    provider: input.provider ?? current.provider, model: input.model ?? current.model, url: input.url ?? current.url,
    mirror: input.mirror ?? current.mirror, translationAcceleration: input.translationAcceleration ?? current.translationAcceleration };
  if (!['deepseek', 'custom'].includes(next.provider) || typeof next.model !== 'string' || next.model.length > 200
    || typeof next.url !== 'string' || next.url.length > 2000 || !['hf', 'modelscope'].includes(next.mirror)
    || !['auto', 'gpu', 'cpu'].includes(next.translationAcceleration)) throw new Error('模型配置无效。');
  if (input.provider || input.url) endpoint(next);
  if (typeof input.apiKey === 'string' && input.apiKey.trim()) {
    if (input.apiKey.length > 4000 || /[\r\n]/.test(input.apiKey)) throw new Error('API key 格式无效。');
    if (!safeStorage.isEncryptionAvailable()) throw new Error('系统凭据加密不可用，未保存 API key。');
    next.keyBlob = safeStorage.encryptString(input.apiKey.trim()).toString('base64');
  }
  if (input.clearKey) next.keyBlob = '';
  store.change(data => Object.assign(data.settings, next));
  if (next.translationAcceleration !== current.translationAcceleration) { cancel(); await engine.stop(); }
  return state();
}
async function query(action, input) {
  cancel(); const version = generation;
  request = new AbortController(); const signal = request.signal;
  const selection = selected(input.selection);
  const { level, text, before, after } = selection;
  const check = () => { signal.throwIfAborted(); if (version !== generation) throw new Error('已取消。'); };
  if (['dictionary', 'definition'].includes(action) && level !== 'word') throw new Error('词典释义仅用于单词选区。');
  if (action === 'analysis' && level !== 'sentence') throw new Error('长句分析仅用于完整单句。');
  if (action === 'translate' && !['sentence', 'paragraph'].includes(level)) throw new Error('请选中完整句子或段落后翻译。');
  if (['analysis', 'translate'].includes(action) && text.length > 2000) throw new Error('一次最多选择 2000 字符。');
  if (action === 'dictionary' || action === 'definition') {
    const definition = dictionary.lookup(text, before, after);
    if (action === 'dictionary') {
      const local = importedDictionary ? importedDictionary.lookup(text, definition) : definition;
      lastLookup = { definition: local, selection };
      return { type: action, definition: local, selection };
    }
    const settings = store.data.settings;
    const key = store.cacheKey('definition-v1', settings.provider, endpoint(settings).href, settings.model, definition.head, definition.reading);
    let result = !input.refresh && store.cached(key), cached = Boolean(result);
    if (!result) {
      result = decodeDefinition(await completion(settings, await apiKey(), [{ role: 'system', content: prompts.definition },
        { role: 'user', content: JSON.stringify({ before, word: text, after }) }], { signal, maxTokens: 1024 }));
      check();
      const dictionaryValue = dictionary.lookup(result.head);
      result = { ...result, english: dictionaryValue.english || definition.english, pos: dictionaryValue.pos,
        source: `${settings.provider === 'deepseek' ? 'DeepSeek' : '自定义模型'} · ${settings.model}` };
      store.cache(key, result);
    }
    check(); lastLookup = { definition: result, selection };
    return { type: action, definition: result, selection, cached };
  }
  if (action === 'analysis') {
    const settings = store.data.settings;
    const key = store.cacheKey('analysis-v1', settings.provider, endpoint(settings).href, settings.model, text);
    let result = !input.refresh && store.cached(key), cached = Boolean(result);
    if (!result) {
      result = decodeAnalysis(await completion(settings, await apiKey(), [{ role: 'system', content: prompts.sentence },
        { role: 'user', content: JSON.stringify({ text }) }], { signal, maxTokens: 6144 }));
      check(); store.cache(key, result);
    }
    check();
    const id = store.cacheKey(key, sourceKey(selection));
    const serviceName = `${settings.provider === 'deepseek' ? 'DeepSeek' : '自定义模型'} · ${settings.model}`;
    store.change(data => {
      data.analyses = [{ id, selection, analysis: result, serviceName }, ...data.analyses.filter(entry => entry.id !== id)];
    });
    return { type: action, analysis: result, selection, cached };
  }
  if (action === 'translate') {
    const model = store.data.settings.modelPath;
    if (!model) throw new Error('请先在设置中下载或选择本地翻译模型。');
    const info = await fs.stat(model);
    const identity = `${model}|${info.size}|${info.mtimeMs}`;
    const key = store.cacheKey('ja-zh-v1', identity, text);
    let result = !input.refresh && store.cached(key), cached = Boolean(result);
    if (!result) { result = await engine.translate(model, text, signal, store.data.settings.translationAcceleration); check(); store.cache(key, result); }
    check(); return { type: action, translation: result, selection, cached, execution: cached ? null : engine.status() };
  }
  if (action === 'chat') {
    if (typeof input.question !== 'string' || !input.question.trim() || input.question.length > 4000) throw new Error('请输入问题（最多 4000 字符）。');
    const id = sourceKey(selection);
    const existing = store.data.chats.find(chat => chat.id === id);
    const messages = [...(existing?.messages || []), { role: 'user', content: input.question.trim() }];
    if (messages.reduce((sum, item) => sum + item.content.length, 0) > 60000) throw new Error('对话过长，请清空后重新开始。');
    const reply = await completion(store.data.settings, await apiKey(), [{ role: 'system', content: prompts.chat + JSON.stringify({ selectedText: text, before, after }) }, ...messages], { signal });
    check(); messages.push({ role: 'assistant', content: reply.text, truncated: reply.truncated });
    store.change(data => { data.chats = data.chats.filter(chat => chat.id !== id); data.chats.push({ id, selection, messages }); });
    return { type: action, messages, selection };
  }
  throw new Error('未知查询。');
}
const dictionaryDirectory = () => path.join(store.directory, 'dictionaries');
function dictionaryFile(id) {
  if (!/^[a-f0-9-]{36}$/i.test(id)) throw new Error('词典编号无效。');
  return path.join(dictionaryDirectory(), id + '.json');
}
async function loadDictionary(id) {
  const info = store.data.settings.dictionaries?.find(item => item.id === id);
  if (!info) throw new Error('找不到所选词典。');
  const chunks = JSON.parse(await fs.readFile(dictionaryFile(id), 'utf8'));
  return new ImportedDictionary(info, chunks);
}
function applyDictionary(index) {
  importedDictionary = index;
  dictionaryMessage = '';
  if (lastLookup?.definition.dictionaryName || lastLookup?.definition.source === '离线词典') lastLookup = null;
  return state();
}
async function changeDictionary(action, input) {
  if (updatingDictionaries) throw new Error('正在更新词典，请稍候。');
  updatingDictionaries = true;
  try {
    if (action === 'select-dictionary') {
      const index = input.id === '' ? undefined : await loadDictionary(input.id);
      store.change(data => { data.settings.dictionaryID = input.id; });
      return applyDictionary(index);
    }
    const chosen = await dialog.showOpenDialog(window, { title: '导入本地词典', properties: ['openFile'],
      filters: [{ name: 'MDict / Yomitan 词典', extensions: ['mdx', 'zip'] }] });
    if (chosen.canceled) return null;
    const file = chosen.filePaths[0];
    const format = path.extname(file).toLowerCase();
    if (!['.mdx', '.zip'].includes(format)) throw new Error('请选择 MDX 或 Yomitan ZIP 词典。');
    const chunks = await readEbook(file, { parent: window, timeoutMs: 120000 });
    const name = format === '.zip' ? chunks.shift() : path.basename(file, path.extname(file));
    const info = { id: randomUUID(), name };
    const index = new ImportedDictionary(info, chunks);
    const target = dictionaryFile(info.id);
    await fs.mkdir(dictionaryDirectory(), { recursive: true });
    try {
      await fs.writeFile(target, JSON.stringify(chunks), { flag: 'wx', mode: 0o600 });
      store.change(data => {
        (data.settings.dictionaries ??= []).push(info);
        data.settings.dictionaryID = info.id;
      });
    } catch (error) {
      if (error.code !== 'EEXIST') await fs.rm(target, { force: true });
      throw error;
    }
    return applyDictionary(index);
  } finally { updatingDictionaries = false; }
}
function readingOffset(book, page, offset) {
  if (!Number.isSafeInteger(offset) || offset < 0) throw new Error('阅读位置无效。');
  return Math.min(offset, Math.max(0, book.pages[page].length - 1));
}
function saveReadingProgress({ bookID, page, offset }) {
  const book = store.book;
  if (book.id !== bookID || book.page !== page) return false;
  const position = readingOffset(book, page, offset);
  if ((book.readingOffset ?? 0) !== position) {
    store.change(data => { data.books.find(item => item.id === bookID).readingOffset = position; });
  }
  return true;
}
async function dispatch(action, input = {}) {
  if (action === 'cancel') { cancel(); return true; }
  await ready;
  switch (action) {
    case 'state': return state();
    case 'settings': return saveSettings(input);
    case 'import-dictionary': case 'select-dictionary': return changeDictionary(action, input);
    case 'detect-gpu': return engine.detect(true);
    case 'import': {
      if (importing) throw new Error('已有文档正在导入，请等待或取消。');
      const controller = new AbortController(); importing = controller;
      try {
        const result = await dialog.showOpenDialog(window, { title: '导入日语文档', properties: ['openFile'], filters: [{ name: '阅读文档', extensions: ['pdf', 'epub', 'mobi', 'txt'] }] });
        if (result.canceled) return null;
        controller.signal.throwIfAborted();
        const book = await readBook(result.filePaths[0], { signal: controller.signal, parent: window });
        controller.signal.throwIfAborted(); cancel(); lastLookup = null;
        store.change(data => {
          const existing = data.books.find(item => item.name === book.name && item.kind === book.kind
            && item.pages.length === book.pages.length && item.pages.every((page, index) => page === book.pages[index]));
          if (!existing) data.books.push(book);
          data.current = existing?.id ?? book.id;
        });
        return state();
      } catch (error) {
        if (controller.signal.aborted) throw new Error('已取消导入。');
        throw error;
      } finally { if (importing === controller) importing = null; }
    }
    case 'cancel-import': importing?.abort(); return true;
    case 'reading-progress': return saveReadingProgress(input);
    case 'navigate': {
      importing?.abort();
      const book = store.data.books.find(book => book.id === input.bookID);
      if (!book || !Number.isInteger(input.page) || input.page < 0 || input.page >= book.pages.length) throw new Error('阅读位置无效。');
      cancel(); lastLookup = null;
      const offset = input.offset === undefined
        ? (book.page === input.page ? book.readingOffset ?? 0 : 0)
        : readingOffset(book, input.page, input.offset);
      if (store.data.current !== book.id || book.page !== input.page || (book.readingOffset ?? 0) !== offset) {
        store.change(data => {
          data.current = book.id;
          Object.assign(data.books.find(item => item.id === book.id), { page: input.page, readingOffset: offset });
        });
      }
      return state();
    }
    case 'level': { const selection = selected(input); return selection.level; }
    case 'save-note': store.saveNote(input); return state();
    case 'delete-note': store.deleteNote(input.id); return state();
    case 'word-at': {
      const text = store.book.pages[store.book.page];
      if (!Number.isInteger(input.offset) || input.offset < 0 || input.offset >= text.length) return null;
      return dictionary.wordAt(text, input.offset);
    }
    case 'dictionary': case 'definition': case 'analysis': case 'translate': case 'chat': return query(action, input);
    case 'save-word': {
      if (!lastLookup) throw new Error('请先查询单词。');
      const { definition, selection } = lastLookup, id = definition.head + '\n' + definition.reading;
      store.change(data => {
        let word = data.words.find(word => word.id === id);
        if (!word) { word = { id, definition, examples: [] }; data.words.push(word); }
        if (!definition.dictionaryName && definition.source !== '离线词典') word.definition = definition;
        const example = { filename: selection.filename, kind: selection.kind, page: selection.page,
          start: selection.start, bookID: selection.bookID, sentence: selection.before.slice(-250) + selection.text + selection.after.slice(0, 250), definition };
        const index = word.examples.findIndex(item => item.bookID === selection.bookID && item.page === selection.page && item.start === selection.start);
        if (index < 0) word.examples.push(example); else word.examples[index] = example;
      });
      return state();
    }
    case 'delete-word': store.change(data => { data.words = data.words.filter(word => word.id !== input.id); }); return state();
    case 'export': {
      const format = input.format === 'txt' ? 'txt' : 'csv';
      const words = Array.isArray(input.ids) ? store.data.words.filter(word => input.ids.includes(word.id)) : store.data.words;
      const result = await dialog.showSaveDialog(window, { defaultPath: `读解生词本.${format}`, filters: [{ name: format.toUpperCase(), extensions: [format] }] });
      if (!result.canceled) await fs.writeFile(result.filePath, exportWords(words, format, Array.isArray(input.fields) ? input.fields : undefined), 'utf8');
      return !result.canceled;
    }
    case 'moji': {
      if (typeof input.word !== 'string' || input.word.length > 100) throw new Error('查询词无效。');
      await shell.openExternal(`https://www.mojidict.com/searchText/${encodeURIComponent(input.word)}`); return true;
    }
    case 'chat-history': {
      const selection = selected(input);
      return store.data.chats.find(chat => chat.id === sourceKey(selection))?.messages || [];
    }
    case 'delete-analysis':
      store.change(data => { data.analyses = data.analyses.filter(entry => entry.id !== input.id); });
      return state();
    case 'delete-chat':
      cancel();
      store.change(data => { data.chats = data.chats.filter(chat => chat.id !== input.id); });
      return state();
    case 'clear-chat': {
      const selection = selected(input); cancel();
      store.change(data => { data.chats = data.chats.filter(chat => chat.id !== sourceKey(selection)); }); return true;
    }
    case 'select-model': {
      if (download) throw new Error('请先取消模型下载。');
      const chosen = await dialog.showOpenDialog(window, { title: '选择 Hy-MT2 Q4 模型', properties: ['openFile'], filters: [{ name: 'GGUF 模型', extensions: ['gguf'] }] });
      if (chosen.canceled) return state();
      const model = await validateModel(chosen.filePaths[0]);
      cancel(); await engine.stop(); store.change(data => { data.settings.modelPath = model; }); return state();
    }
    case 'download-model': {
      if (download) throw new Error('模型正在下载。');
      download = new AbortController();
      try {
        const model = await downloadModel(path.join(store.directory, 'models'), store.data.settings.mirror,
          progress => { if (!window.isDestroyed()) window.webContents.send('model-progress', progress); }, download.signal);
        cancel(); await engine.stop(); store.change(data => { data.settings.modelPath = model; }); return state();
      } finally { download = null; }
    }
    case 'cancel-download': download?.abort(); return true;
    case 'release-model': cancel(); await engine.stop(); return true;
    default: throw new Error('未知操作。');
  }
}
app.whenReady().then(async () => {
  store = new Store(app.getPath('userData')); dictionary = new Dictionary(); engine = new LocalEngine(resources());
  ready = dictionary.load(resources()).then(async () => {
    const id = store.data.settings.dictionaryID;
    if (id) {
      try { importedDictionary = await loadDictionary(id); }
      catch { dictionaryMessage = '无法载入上次使用的词典，已启用内置词典。'; }
    }
  });
  // Keep startup failures observable to IPC without an unhandled rejection.
  ready.catch(() => {});
  window = new BrowserWindow({ width: 1220, height: 800, minWidth: 900, minHeight: 600,
    title: '读解', icon: path.join(resources(), 'AppIcon.png'),
    webPreferences: { preload: path.join(__dirname, 'preload.cjs'), contextIsolation: true, nodeIntegration: false, sandbox: true } });
  Menu.setApplicationMenu(Menu.buildFromTemplate([{ label: '文件', submenu: [
    { label: '导入文档…', accelerator: 'CmdOrCtrl+O', click: () => window.webContents.send('import-request') }, { role: 'quit', label: '退出' }] },
    { label: '编辑', submenu: [{ role: 'undo', label: '撤销' }, { role: 'redo', label: '重做' }, { type: 'separator' },
      { role: 'cut', label: '剪切' }, { role: 'copy', label: '复制' }, { role: 'paste', label: '粘贴' }, { role: 'selectAll', label: '全选' }] }]));
  window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  window.webContents.on('will-navigate', event => event.preventDefault());
  window.webContents.session.setPermissionRequestHandler((_contents, _permission, callback) => callback(false));
  const trusted = event => event.senderFrame === window.webContents.mainFrame
    && event.senderFrame?.url === pathToFileURL(entryFile).href;
  ipcMain.on('yomitoki:flush-reading-progress', (event, input) => {
    try { event.returnValue = trusted(event) && saveReadingProgress(input); }
    catch { event.returnValue = false; }
  });
  ipcMain.handle('yomitoki', async (event, action, input) => {
    if (!trusted(event)) throw new Error('无效调用来源。');
    try { return { ok: true, value: await dispatch(action, input) }; }
    catch (error) { return { ok: false, error: error.message || '操作失败。' }; }
  });
  await window.loadFile(entryFile);
}).catch(error => { dialog.showErrorBox('读解无法启动', error.message + '\n原有数据不会被覆盖。'); app.quit(); });
app.on('window-all-closed', () => app.quit());
app.on('before-quit', event => {
  if (quitting) return;
  event.preventDefault(); quitting = true; cancel(); importing?.abort(); download?.abort();
  Promise.resolve(engine?.stop()).finally(() => app.quit());
});
