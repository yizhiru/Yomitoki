const $ = id => document.getElementById(id);
const api = window.yomitoki;
let importing = false;
let state, view = 'reading', selection, chatSelection, messages = [], questionDraft = '', result, busy = false, uiGeneration = 0, noticeTimer;
function element(tag, text, className) { const node = document.createElement(tag); if (text !== undefined) node.textContent = text; if (className) node.className = className; return node; }
function notice(text) { $('status').textContent = text; $('status').style.display = 'block'; clearTimeout(noticeTimer); noticeTimer = setTimeout(() => { $('status').style.display = 'none'; }, 5500); }
async function attempt(action) { try { return await action(); } catch (error) { notice(error.message); return null; } }
function button(label, click, className) { const node = element('button', label, className); node.addEventListener('click', () => attempt(click)); return node; }
function currentBook() { return state.books.find(book => book.id === state.current) || state.books[0]; }
function selectionPayload(start, end) { const book = currentBook(); return { bookID: book.id, page: book.page, start, end }; }
function cancelQuery() { uiGeneration++; busy = false; api.call('cancel').catch(() => {}); }
function sync(next) {
  if (!next) return;
  state = next; const book = currentBook();
  $('version').textContent = `Yomitoki ${state.version}`;
  $('book-title').textContent = view === 'notebook' ? `生词本 · ${state.words.length} 个词` : book.name;
  $('book-location').textContent = view === 'notebook' ? '收藏词义与阅读中的原句' : `${book.kind} · 第 ${book.page + 1} / ${book.pages.length} ${book.kind === 'PDF' ? '页' : '节'}`;
  if ($('reader').textContent !== book.pages[book.page]) { $('reader').textContent = book.pages[book.page]; $('reading-scroll').scrollTop = 0; }
  $('page-number').value = book.page + 1; $('page-number').max = book.pages.length;
  $('previous').disabled = book.page <= 0; $('next').disabled = book.page >= book.pages.length - 1;
  $('books').replaceChildren(...state.books.map(item => button(item.name, () => navigate(item.id, item.page), `book-item${item.id === book.id ? ' active' : ''}`)));
  $('reading-scroll').hidden = view !== 'reading'; $('notebook').hidden = view !== 'notebook';
  document.querySelector('.header-actions').hidden = view !== 'reading';
  $('reading-tab').classList.toggle('active', view === 'reading'); $('notebook-tab').classList.toggle('active', view === 'notebook');
  applySettings(); if (view === 'notebook') renderWords();
}
function applySettings() {
  const settings = state.settings;
  const root = document.documentElement.style;
  root.setProperty('--side', `${settings.sidebarWidth}px`); root.setProperty('--detail', `${settings.detailWidth}px`);
  root.setProperty('--font', `${settings.fontSize}px`); root.setProperty('--definition', `${settings.definitionSize}px`);
}
function clearDetail() { result = null; chatSelection = null; $('detail-body').replaceChildren(element('p', '选中文字，开始读解。', 'empty')); }
async function navigate(bookID, page) {
  cancelQuery(); selection = null; $('selection-toolbar').hidden = true; clearDetail(); view = 'reading';
  sync(await api.call('navigate', { bookID, page }));
}
async function importBook() {
  if (importing) return;
  importing = true; $('import').disabled = true; $('import').textContent = '正在导入…'; $('cancel-import').hidden = false;
  try {
    const next = await api.call('import');
    if (next) { cancelQuery(); view = 'reading'; selection = null; clearDetail(); sync(next); }
  } finally {
    importing = false; $('import').disabled = false; $('import').textContent = '导入'; $('cancel-import').hidden = true;
  }
}
function section(title, text, className) {
  const wrapper = element('section'); wrapper.append(element('h3', title), element(className === 'diagram' ? 'pre' : 'p', text, className)); return wrapper;
}
function original(selected) { return section('原文', selected.text, 'original'); }
function definitionBody(definition) {
  const wrapper = element('div'); wrapper.append(element('h2', definition.head), element('p', definition.reading || '', 'reading'));
  if (definition.pos?.length) wrapper.append(element('p', definition.pos.join(' · '), 'pos'));
  if (definition.english) wrapper.append(section('英文释义', definition.english));
  if (definition.chinese) wrapper.append(section('中文释义', definition.chinese));
  if (!definition.english && !definition.chinese) wrapper.append(element('p', '离线词典未找到释义，可尝试大模型释义。'));
  if (definition.etymology) wrapper.append(section('词源', definition.etymology));
  if (definition.source) wrapper.append(element('p', definition.source, 'source'));
  const actions = element('div', undefined, 'button-row');
  actions.append(button('在 MOJi 中查询', () => api.call('moji', { word: definition.head })));
  wrapper.append(actions); return wrapper;
}
function renderResult(value) {
  const detail = $('detail-body'); detail.replaceChildren(); result = value;
  if (value.execution) state.translationRuntime = value.execution;
  if (value.cached) detail.append(element('small', '已从本地缓存读取'));
  if (value.definition) {
    detail.append(definitionBody(value.definition));
    const actions = element('div', undefined, 'button-row');
    actions.append(button('保存到生词本', async () => { sync(await api.call('save-word')); notice('已保存到生词本'); }, 'primary'));
    if (value.type === 'definition') actions.append(button('重新释义', () => runAction('definition', true, value.selection)));
    detail.append(actions);
  } else if (value.analysis) {
    const analysis = value.analysis;
    detail.append(element('h2', '长句分析'), section('中文译文', analysis.translation), section('主干结构', analysis.mainStructure));
    if (analysis.modifiers.length) detail.append(section('修饰层级', analysis.modifiers.join('\n\n')));
    detail.append(section('结构嵌套图解', analysis.diagram, 'diagram'));
    if (analysis.grammarPoints.length) detail.append(section('语法难点', analysis.grammarPoints.join('\n\n')));
    if (analysis.notes) detail.append(section('歧义与省略', analysis.notes));
    detail.append(button('重新分析', () => runAction('analysis', true, value.selection)));
  } else if (value.translation) {
    detail.append(element('h2', '本地翻译'), section('中文译文', value.translation), button('重新翻译', () => runAction('translate', true, value.selection)));
    if (value.execution) detail.append(element('small', runtimeDescription(value.execution)));
  }
  detail.append(original(value.selection));
}
async function runAction(action, refresh = false, selected = selection) {
  if (!selected) return;
  cancelQuery(); const id = uiGeneration; busy = true; $('selection-toolbar').hidden = true; chatSelection = null;
  const detail = $('detail-body');
  detail.replaceChildren(element('h2', action === 'analysis' ? '长句分析' : action === 'translate' ? '本地翻译' : '单词释义'),
    element('p', action === 'translate' ? '正在加载模型或翻译，首次加载可能需要等待…' : '正在查询…', 'busy'),
    button('停止', () => { cancelQuery(); detail.replaceChildren(element('p', '已停止。', 'muted')); }));
  try {
    const value = await api.call(action, { selection: selected, refresh });
    if (id === uiGeneration) renderResult(value);
  } catch (error) {
    if (id === uiGeneration) {
      detail.replaceChildren(element('p', error.message), button('重试', () => runAction(action, refresh, selected)), original({ text: currentBook().pages[currentBook().page].slice(selected.start, selected.end) }));
    }
  } finally { if (id === uiGeneration) busy = false; }
}
async function showChat(selected = selection) {
  if (!selected) return;
  cancelQuery(); const id = uiGeneration; chatSelection = structuredClone(selected); questionDraft = '';
  $('selection-toolbar').hidden = true;
  messages = await api.call('chat-history', selected);
  if (id === uiGeneration) renderChat();
}
function renderChat() {
  const detail = $('detail-body'); detail.replaceChildren(element('h2', '选文对话'));
  const source = currentBook().pages[currentBook().page].slice(chatSelection.start, chatSelection.end);
  detail.append(section('选文', source, 'original'));
  for (const message of messages) {
    const row = element('div', undefined, 'chat-message'); row.append(element('small', message.role === 'user' ? '你' : '读解'), element('p', message.content));
    if (message.truncated) row.append(element('small', '回复达到输出上限，可追问“请继续”。'));
    detail.append(row);
  }
  const question = element('textarea', undefined, 'chat-question'); question.id = 'chat-question'; question.placeholder = '关于这段文字，你想了解什么？'; question.maxLength = 4000; question.value = questionDraft;
  question.addEventListener('input', () => { questionDraft = question.value; });
  question.addEventListener('keydown', event => { if ((event.ctrlKey || event.metaKey) && event.key === 'Enter') { event.preventDefault(); if (!busy) attempt(sendChat); } });
  detail.append(question);
  const actions = element('div', undefined, 'button-row');
  if (busy) actions.append(button('停止', () => { cancelQuery(); renderChat(); }));
  else {
    actions.append(button('发送', sendChat, 'primary'));
    actions.append(button('清空对话', async () => { await api.call('clear-chat', chatSelection); messages = []; renderChat(); }));
  }
  detail.append(actions, element('small', '选文及附近原文会交由设置中的模型服务处理。Ctrl+Enter 发送。'));
}
async function sendChat() {
  if (busy || !questionDraft.trim()) return;
  cancelQuery(); const id = uiGeneration; busy = true; const question = questionDraft;
  renderChat();
  try {
    const value = await api.call('chat', { selection: chatSelection, question });
    if (id !== uiGeneration) return;
    messages = value.messages; questionDraft = '';
  } catch (error) { if (id === uiGeneration) notice(error.message); }
  finally { if (id === uiGeneration) { busy = false; renderChat(); } }
}
function filteredWords() {
  const search = $('word-search').value.trim().toLowerCase();
  return state.words.filter(word => [word.definition.head, word.definition.reading, word.definition.chinese, word.definition.english].join(' ').toLowerCase().includes(search));
}
function renderWords() {
  const words = filteredWords();
  $('words').replaceChildren(...words.map(word => {
    const row = button('', () => {
      const detail = $('detail-body'); detail.replaceChildren(definitionBody(word.definition));
      for (const example of word.examples) {
        detail.append(section(`${example.filename} · 第 ${example.page + 1} ${example.kind === 'PDF' ? '页' : '节'}`, example.sentence, 'original'));
        if (example.definition?.chinese && example.definition.chinese !== word.definition.chinese) detail.append(section('语境释义', example.definition.chinese));
      }
      detail.append(button('删除这个单词', async () => { sync(await api.call('delete-word', { id: word.id })); clearDetail(); }));
    }, 'word-card');
    row.append(element('strong', word.definition.head), element('small', word.definition.reading), element('p', (word.definition.chinese || word.definition.english || '').slice(0, 180)));
    return row;
  }));
  if (!words.length) $('words').append(element('p', state.words.length ? '没有匹配的单词。' : '在阅读中查询单词后，可以保存到这里。', 'muted'));
}
let selectionTimer, selectionRequest = 0;
async function updateSelection() {
  const browserSelection = window.getSelection(); const reader = $('reader');
  if (view !== 'reading' || !browserSelection?.rangeCount || browserSelection.isCollapsed || !reader.contains(browserSelection.anchorNode) || !reader.contains(browserSelection.focusNode)) {
    $('selection-toolbar').hidden = true; return;
  }
  const range = browserSelection.getRangeAt(0); const prefix = range.cloneRange();
  prefix.selectNodeContents(reader); prefix.setEnd(range.startContainer, range.startOffset);
  const start = prefix.toString().length, end = start + range.toString().length;
  const payload = selectionPayload(start, end); const id = ++selectionRequest;
  let level; try { level = await api.call('level', payload); } catch { return; }
  if (id !== selectionRequest) return;
  selection = payload;
  const toolbar = $('selection-toolbar'); toolbar.replaceChildren();
  if (level === 'word') {
    toolbar.append(button('词典释义', () => runAction('dictionary')), button('大模型释义', () => runAction('definition')));
  } else if (level === 'sentence') toolbar.append(button('本地翻译', () => runAction('translate')), button('长句分析', () => runAction('analysis')));
  else if (level === 'paragraph') toolbar.append(button('本地翻译', () => runAction('translate')));
  else if (level !== 'fragment') { toolbar.hidden = true; return; }
  toolbar.append(button('大模型对话', () => showChat()));
  toolbar.hidden = false;
  const rect = range.getBoundingClientRect(), box = toolbar.getBoundingClientRect();
  toolbar.style.left = `${Math.max(8, Math.min(window.innerWidth - box.width - 8, rect.left + rect.width / 2 - box.width / 2))}px`;
  toolbar.style.top = `${rect.top > box.height + 12 ? rect.top - box.height - 9 : rect.bottom + 9}px`;
}
document.addEventListener('selectionchange', () => { clearTimeout(selectionTimer); selectionTimer = setTimeout(updateSelection, 90); });
$('selection-toolbar').addEventListener('mousedown', event => event.preventDefault());
$('reading-scroll').addEventListener('scroll', () => { $('selection-toolbar').hidden = true; });
$('reader').addEventListener('click', event => attempt(async () => {
  if (!state?.settings.singleClick || event.detail !== 1 || !window.getSelection().isCollapsed) return;
  const caret = document.caretRangeFromPoint(event.clientX, event.clientY);
  if (!caret || !$('reader').contains(caret.startContainer)) return;
  const prefix = caret.cloneRange(); prefix.selectNodeContents($('reader')); prefix.setEnd(caret.startContainer, caret.startOffset);
  const word = await api.call('word-at', { offset: prefix.toString().length });
  if (word) await runAction('dictionary', false, selectionPayload(word.start, word.end));
}));
async function openSettings() {
  sync(await api.call('state'));
  const settings = state.settings;
  $('single-click').checked = settings.singleClick;
  $('font-size').value = settings.fontSize; $('font-value').value = settings.fontSize;
  $('definition-size').value = settings.definitionSize; $('definition-value').value = settings.definitionSize;
  $('provider').value = settings.provider; $('api-url').value = settings.url; $('model-name').value = settings.model;
  $('api-key').value = ''; $('clear-key').checked = false;
  $('key-status').textContent = state.hasKey ? '已保存加密的 API key。' : '尚未配置 API key。';
  $('mirror').value = settings.mirror; $('model-path').textContent = settings.modelPath || '尚未选择模型';
  $('translation-acceleration').value = settings.translationAcceleration;
  $('translation-runtime').textContent = runtimeDescription(state.translationRuntime);
  $('settings-dialog').showModal();
}
function runtimeDescription(runtime) {
  if (!runtime?.backend) return '尚未加载翻译模型。';
  if (runtime.backend === 'vulkan') return `正在使用 GPU · ${runtime.device} · ${runtime.gpuLayers} 层已加速`;
  return `正在使用 CPU。${runtime.reason || ''}`;
}
$('translation-acceleration').addEventListener('change', () => attempt(async () => {
  sync(await api.call('settings', { translationAcceleration: $('translation-acceleration').value }));
  $('translation-runtime').textContent = runtimeDescription(state.translationRuntime);
}));
$('detect-gpu').addEventListener('click', () => attempt(async () => {
  $('detect-gpu').disabled = true; $('gpu-detection').textContent = '正在检测显卡…';
  try {
    const detected = await api.call('detect-gpu');
    $('gpu-detection').textContent = detected.devices.length ? `检测到 GPU：${detected.devices.map(device => device.name).join('；')}` : detected.reason;
  } finally { $('detect-gpu').disabled = false; }
}));
for (const [id, key, output] of [['font-size', 'fontSize', 'font-value'], ['definition-size', 'definitionSize', 'definition-value']]) {
  $(id).addEventListener('input', () => { state.settings[key] = Number($(id).value); $(output).value = $(id).value; applySettings(); });
  $(id).addEventListener('change', () => attempt(async () => sync(await api.call('settings', { [key]: Number($(id).value) }))));
}
$('single-click').addEventListener('change', () => attempt(async () => sync(await api.call('settings', { singleClick: $('single-click').checked }))));
$('provider').addEventListener('change', () => { if ($('provider').value === 'deepseek') { $('api-url').value = 'https://api.deepseek.com'; $('model-name').value = 'deepseek-flash'; } });
$('save-model').addEventListener('click', () => attempt(async () => {
  sync(await api.call('settings', { provider: $('provider').value, url: $('api-url').value, model: $('model-name').value, apiKey: $('api-key').value, clearKey: $('clear-key').checked }));
  $('api-key').value = ''; $('key-status').textContent = state.hasKey ? 'API key 已加密保存。' : '尚未配置 API key。'; notice('模型设置已保存');
}));
$('mirror').addEventListener('change', () => attempt(async () => sync(await api.call('settings', { mirror: $('mirror').value }))));
for (const action of ['select-model', 'release-model']) $(action).addEventListener('click', () => attempt(async () => {
  const next = await api.call(action);
  if (next && typeof next === 'object') { sync(next); $('model-path').textContent = state.settings.modelPath; }
  else { sync(await api.call('state')); notice('已释放模型内存'); }
  $('translation-runtime').textContent = runtimeDescription(state.translationRuntime);
}));
$('download-model').addEventListener('click', () => attempt(async () => {
  $('download-model').disabled = true; $('select-model').disabled = true; $('cancel-download').hidden = false; $('download-progress').hidden = false;
  $('download-status').textContent = '正在连接下载源…';
  try { sync(await api.call('download-model')); $('model-path').textContent = state.settings.modelPath; $('download-status').textContent = '模型已下载并通过校验。'; }
  catch (error) { $('download-status').textContent = error.message; throw error; }
  finally { $('download-model').disabled = false; $('select-model').disabled = false; $('cancel-download').hidden = true; }
}));
$('cancel-download').addEventListener('click', () => attempt(() => api.call('cancel-download')));
api.onProgress(progress => {
  $('download-progress').value = progress.received / progress.total;
  $('download-status').textContent = progress.phase === 'verify' ? '正在校验模型完整性…' : `${Math.floor(progress.received / progress.total * 100)}% · ${(progress.received / 1e9).toFixed(2)} / ${(progress.total / 1e9).toFixed(2)} GB`;
});
function splitter(id, key, direction, min, max) {
  const handle = $(id); let dragging = false, start, initial;
  handle.addEventListener('pointerdown', event => { event.preventDefault(); dragging = true; start = event.clientX; initial = state.settings[key]; handle.setPointerCapture(event.pointerId); $('selection-toolbar').hidden = true; });
  handle.addEventListener('pointermove', event => { if (dragging) { state.settings[key] = Math.max(min, Math.min(max, initial + direction * (event.clientX - start))); applySettings(); } });
  handle.addEventListener('pointerup', () => { if (dragging) { dragging = false; attempt(async () => sync(await api.call('settings', { [key]: state.settings[key] }))); } });
  handle.addEventListener('keydown', event => { if (event.key === 'ArrowLeft' || event.key === 'ArrowRight') { event.preventDefault(); const next = Math.max(min, Math.min(max, state.settings[key] + direction * (event.key === 'ArrowRight' ? 10 : -10))); attempt(async () => sync(await api.call('settings', { [key]: next }))); } });
}
splitter('sidebar-split', 'sidebarWidth', 1, 160, 400); splitter('detail-split', 'detailWidth', -1, 260, 800);
$('cancel-import').addEventListener('click', () => attempt(() => api.call('cancel-import')));
$('import').addEventListener('click', () => attempt(importBook)); api.onImport(() => attempt(importBook));
$('previous').addEventListener('click', () => attempt(() => navigate(currentBook().id, currentBook().page - 1)));
$('next').addEventListener('click', () => attempt(() => navigate(currentBook().id, currentBook().page + 1)));
$('page-number').addEventListener('change', () => attempt(() => navigate(currentBook().id, Number($('page-number').value) - 1)));
$('reading-tab').addEventListener('click', () => { cancelQuery(); view = 'reading'; selection = null; clearDetail(); sync(state); });
$('notebook-tab').addEventListener('click', () => { cancelQuery(); view = 'notebook'; selection = null; $('selection-toolbar').hidden = true; clearDetail(); sync(state); });
$('settings-button').addEventListener('click', () => attempt(openSettings)); $('word-search').addEventListener('input', renderWords);
for (const [key, label] of [['reading', '读音'], ['chinese', '中文释义'], ['english', '英文释义'], ['source', '释义来源'], ['etymology', '词源'], ['sentence', '原句'], ['location', '文件与位置']]) {
  const labelNode = element('label', label); const input = element('input'); input.type = 'checkbox'; input.value = key; input.checked = true; labelNode.prepend(input); $('export-fields').append(labelNode);
}
$('export-button').addEventListener('click', () => $('export-dialog').showModal());
$('export-confirm').addEventListener('click', () => attempt(async () => {
  const fields = [...$('export-fields').querySelectorAll('input:checked')].map(input => input.value);
  const ids = ($('export-scope').value === 'filtered' ? filteredWords() : state.words).map(word => word.id);
  if (await api.call('export', { format: $('export-format').value, fields, ids })) { $('export-dialog').close(); notice('生词本已导出'); }
}));
attempt(async () => { sync(await api.call('state')); $('reader').focus(); });
