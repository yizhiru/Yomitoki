const $ = id => document.getElementById(id);
const api = window.yomitoki;
let importing = false;
let state, view = 'reading', selection, chatSelection, messages = [], questionDraft = '', result, busy = false, uiGeneration = 0, noticeTimer;
let notesBookID, noteDraft;
let readingSection, readingOffset = 0, visiblePage = 0, visiblePageCount = 1;
let restoreReadingPosition = false, lastScrollTop = 0, pendingReadingProgress, readingProgressTimer;
let searchBookID, readingSearchOpen = false, readingMatches = [], matchIndex = -1, searchCompleted = false, jumpingToMatch = false;
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
  if (searchBookID !== book.id) {
    searchBookID = book.id;
    $('reading-query').value = '';
    resetReadingSearch();
  }
  $('version').textContent = `Yomitoki ${state.version}`;
  $('book-title').textContent = view === 'notes' ? '笔记本' : view === 'notebook' ? `生词本 · ${state.words.length} 个词` : book.name;
  $('book-location').textContent = view === 'notes' ? '' : view === 'notebook' ? '收藏词义与阅读中的原句' : `${book.kind} · 第 ${book.page + 1} / ${book.pages.length} ${book.kind === 'PDF' ? '页' : '节'}`;
  const section = `${book.id}:${book.page}`;
  if (readingSection !== section) {
    readingSection = section;
    $('reader').textContent = book.pages[book.page];
    readingOffset = book.readingOffset ?? 0;
    restoreReadingPosition = true;
  }
  $('reading-scroll').classList.toggle('paged', book.kind === 'EPUB');
  $('page-number').value = book.page + 1; $('page-number').max = book.pages.length;
  $('books').replaceChildren(...state.books.map(item => button(item.name, () => navigate(item.id, item.page), `book-item${item.id === book.id ? ' active' : ''}`)));
  $('reading-scroll').hidden = view !== 'reading'; $('notebook').hidden = view !== 'notebook';
  $('notes').hidden = view !== 'notes';
  $('workspace').classList.toggle('show-notes', view === 'notes');
  $('detail').hidden = $('detail-split').hidden = view === 'notes';
  document.querySelector('.header-actions').hidden = view !== 'reading';
  $('reading-search').hidden = view !== 'reading' || !readingSearchOpen;
  $('reading-tab').classList.toggle('active', view === 'reading'); $('notebook-tab').classList.toggle('active', view === 'notebook');
  $('notes-tab').classList.toggle('active', view === 'notes');
  applySettings();
  if (view === 'notebook') renderWords();
  if (view === 'notes') renderNotes();
}
function applySettings() {
  const settings = state.settings;
  const root = document.documentElement.style;
  root.setProperty('--side', `${settings.sidebarWidth}px`); root.setProperty('--detail', `${settings.detailWidth}px`);
  root.setProperty('--font', `${settings.fontSize}px`); root.setProperty('--definition', `${settings.definitionSize}px`);
  layoutReadingPages();
}
function characterBounds(offset) {
  const text = $('reader').firstChild;
  if (!text?.length) return null;
  const range = document.createRange();
  const start = Math.max(0, Math.min(offset, text.length - 1));
  range.setStart(text, start);
  range.setEnd(text, start + 1);
  return range.getBoundingClientRect();
}
function columnAt(offset, width) {
  const bounds = characterBounds(offset);
  return bounds ? Math.max(0, Math.floor((bounds.left - $('reader').getBoundingClientRect().left) / width)) : 0;
}
function queueReadingProgress(offset) {
  const book = currentBook();
  readingOffset = offset;
  pendingReadingProgress = { bookID: book.id, page: book.page, offset };
  if (!readingProgressTimer) readingProgressTimer = setTimeout(() => attempt(flushReadingProgress), 350);
}
function captureReadingScroll() {
  if (!state || view !== 'reading' || restoreReadingPosition || currentBook().kind === 'EPUB') return;
  const viewport = $('reading-scroll');
  if (viewport.scrollTop === lastScrollTop) return;
  lastScrollTop = viewport.scrollTop;
  if (lastScrollTop <= 0) { queueReadingProgress(0); return; }
  const top = viewport.getBoundingClientRect().top;
  let low = 0, high = Math.max(0, currentBook().pages[currentBook().page].length - 1);
  while (low < high) {
    const middle = Math.floor((low + high) / 2);
    if (characterBounds(middle).bottom <= top) low = middle + 1;
    else high = middle;
  }
  queueReadingProgress(low);
}
function takeReadingProgress() {
  clearTimeout(readingProgressTimer);
  readingProgressTimer = undefined;
  const progress = pendingReadingProgress;
  pendingReadingProgress = undefined;
  return progress;
}
async function flushReadingProgress() {
  const progress = takeReadingProgress();
  if (progress) await api.call('reading-progress', progress);
}
window.addEventListener('beforeunload', () => {
  captureReadingScroll();
  const progress = takeReadingProgress();
  if (progress) api.flushReadingProgress(progress);
});
function layoutReadingPages() {
  if (!state || view !== 'reading') return;
  const book = currentBook(), viewport = $('reading-scroll');
  const width = viewport.clientWidth;
  const paged = book.kind === 'EPUB' && width > 0;
  visiblePageCount = paged ? Math.max(1, Math.round(viewport.scrollWidth / width)) : 1;
  visiblePage = paged ? Math.min(visiblePageCount - 1, columnAt(readingOffset, width)) : 0;
  viewport.scrollLeft = visiblePage * width;
  if (restoreReadingPosition && width > 0) {
    if (!paged) {
      const bounds = readingOffset > 0 ? characterBounds(readingOffset) : null;
      viewport.scrollTop = bounds ? viewport.scrollTop + bounds.top - viewport.getBoundingClientRect().top : 0;
    }
    lastScrollTop = viewport.scrollTop;
    restoreReadingPosition = false;
  }
  $('previous').disabled = book.page <= 0 && visiblePage === 0;
  $('next').disabled = book.page >= book.pages.length - 1 && visiblePage >= visiblePageCount - 1;
  $('book-location').textContent = `${book.kind} · 第 ${book.page + 1} / ${book.pages.length} ${book.kind === 'PDF' ? '页' : '节'}`
    + (paged ? ` · 页 ${visiblePage + 1} / ${visiblePageCount}` : '');
}
function turnPage(direction) {
  const book = currentBook(), target = visiblePage + direction;
  if (target < 0 || target >= visiblePageCount) {
    const section = book.page + direction;
    if (section < 0 || section >= book.pages.length) return;
    return navigate(book.id, section, book.kind === 'EPUB' && direction < 0 ? Number.MAX_SAFE_INTEGER : 0);
  }
  const width = $('reading-scroll').clientWidth;
  let low = 0, high = book.pages[book.page].length - 1;
  while (low < high) {
    const middle = Math.floor((low + high) / 2);
    if (columnAt(middle, width) < target) low = middle + 1;
    else high = middle;
  }
  queueReadingProgress(low);
  CSS.highlights.delete('reading-match');
  cancelQuery(); selection = null; $('selection-toolbar').hidden = true; clearDetail();
  window.getSelection()?.removeAllRanges();
  layoutReadingPages();
}
new ResizeObserver(layoutReadingPages).observe($('reading-scroll'));
function clearDetail() { result = null; chatSelection = null; $('detail-body').replaceChildren(element('p', '选中文字，开始读解。', 'empty')); }
async function navigate(bookID, page, offset) {
  captureReadingScroll();
  await flushReadingProgress();
  CSS.highlights.delete('reading-match');
  cancelQuery(); selection = null; $('selection-toolbar').hidden = true; clearDetail(); view = 'reading';
  const next = await api.call('navigate', { bookID, page, offset });
  takeReadingProgress();
  readingOffset = next.books.find(book => book.id === bookID).readingOffset ?? 0;
  restoreReadingPosition = true;
  window.getSelection()?.removeAllRanges();
  sync(next);
}
function updateReadingSearch() {
  $('reading-search-status').textContent = matchIndex >= 0 ? `${matchIndex + 1} / ${readingMatches.length}`
    : searchCompleted && !readingMatches.length ? '没有匹配' : '';
  $('previous-match').disabled = jumpingToMatch || matchIndex <= 0;
  $('next-match').disabled = jumpingToMatch || matchIndex + 1 >= readingMatches.length;
}
function resetReadingSearch() {
  readingMatches = [];
  matchIndex = -1;
  searchCompleted = false;
  CSS.highlights.delete('reading-match');
  updateReadingSearch();
}
async function jumpToMatch(index) {
  const match = readingMatches[index];
  if (!match || jumpingToMatch) return;
  jumpingToMatch = true;
  updateReadingSearch();
  try {
    await navigate(currentBook().id, match.page, match.start);
    if (readingMatches[index] !== match || !readingSearchOpen || view !== 'reading') return;
    matchIndex = index;
    const range = document.createRange();
    const text = $('reader').firstChild;
    range.setStart(text, match.start);
    range.setEnd(text, match.end);
    CSS.highlights.set('reading-match', new Highlight(range));
    if (currentBook().kind !== 'EPUB') {
      const viewport = $('reading-scroll');
      viewport.scrollTop += range.getBoundingClientRect().top - viewport.getBoundingClientRect().top - viewport.clientHeight / 3;
    }
  } finally {
    jumpingToMatch = false;
    updateReadingSearch();
  }
}
function findInBook() {
  if (!state || jumpingToMatch) return;
  resetReadingSearch();
  const query = $('reading-query').value.trim();
  if (!query) return;
  const pattern = new RegExp(RegExp.escape(query), 'giu');
  currentBook().pages.forEach((text, page) => {
    for (const match of text.matchAll(pattern)) {
      readingMatches.push({ page, start: match.index, end: match.index + match[0].length });
    }
  });
  searchCompleted = true;
  updateReadingSearch();
  return jumpToMatch(0);
}
function setReadingSearchOpen(open) {
  readingSearchOpen = open;
  $('reading-search').hidden = !open;
  $('open-reading-search').setAttribute('aria-expanded', open);
  if (open) $('reading-query').focus();
  else {
    resetReadingSearch();
    $('open-reading-search').focus();
  }
}
async function importBook() {
  if (importing) return;
  importing = true; $('import').disabled = true; $('import').textContent = '正在导入…'; $('cancel-import').hidden = false;
  try {
    captureReadingScroll();
    await flushReadingProgress();
    const next = await api.call('import');
    if (next) { cancelQuery(); view = 'reading'; selection = null; readingOffset = 0; clearDetail(); sync(next); }
  } finally {
    importing = false; $('import').disabled = false; $('import').textContent = '导入'; $('cancel-import').hidden = true;
  }
}
function section(title, text, className) {
  const wrapper = element('section'); wrapper.append(element('h3', title), element(className === 'diagram' ? 'pre' : 'p', text, className)); return wrapper;
}
function original(selected) { return section('原文', selected.text, 'original'); }
function dictionaryLanguage(label, text, language) {
  const block = element('div', undefined, `dictionary-language dictionary-language-${language}`);
  const paragraph = element('p', text);
  paragraph.lang = language;
  const marker = element('span', label);
  marker.setAttribute('aria-label', language === 'zh' ? '中文释义' : '日文释义');
  block.append(marker, paragraph);
  return block;
}
function importedDictionarySection(name, text) {
  if (!/^(?:[①-⑳㉑-㉟㊱-㊿◯]$|▲[ \t]*「|\/[^\S\n]+\S)/m.test(text)) return section(name, text);
  const wrapper = element('section', undefined, 'dictionary-content');
  wrapper.append(element('h3', name));
  const lines = text.split('\n');
  let prose = [], examples, sense;
  const target = () => sense || wrapper;
  const flushProse = () => {
    if (prose.length) target().append(element('p', prose.join('\n'), 'dictionary-prose'));
    prose = [];
  };
  const finishSense = () => {
    flushProse();
    sense = examples = undefined;
  };
  const startSense = label => {
    finishSense();
    sense = element('section', undefined, 'dictionary-sense');
    sense.append(element('h4', label));
    wrapper.append(sense);
  };

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const next = lines[i + 1]?.trim() || '';
    const japanese = /^▲\s*(「.*」)$/.exec(line)?.[1];
    // The saved Meikyo text retains source sense numbers, slash-prefixed glosses and example markers.
    if (!line) {
      finishSense();
    } else if (/^(?:[①-⑳㉑-㉟㊱-㊿◯]|5[1-9])$/.test(line)) {
      startSense(line === '◯' ? '释义' : `义项 ${line}`);
    } else if (/^（[一二三四五六七八九十]+）/.test(line)) {
      finishSense();
      wrapper.append(element('h4', line, 'dictionary-sense-group'));
    } else if (japanese && next && !next.startsWith('▲')) {
      flushProse();
      if (!examples) {
        const group = element('div', undefined, 'dictionary-example-group');
        examples = element('ul', undefined, 'dictionary-examples');
        group.append(element('h5', '例句'), examples);
        target().append(group);
      }
      const pair = element('li');
      const original = element('p', japanese, 'example-japanese');
      original.lang = 'ja';
      const translation = element('p', next, 'example-chinese');
      translation.lang = 'zh';
      pair.append(original, translation);
      examples.append(pair);
      i++;
    } else if (/^\/\s+\S/.test(next)) {
      if (!sense) startSense('释义');
      flushProse();
      examples = undefined;
      const meaning = element('div', undefined, 'dictionary-meaning');
      meaning.append(dictionaryLanguage('日', line, 'ja'),
        dictionaryLanguage('中', next.slice(1).trim(), 'zh'));
      sense.append(meaning);
      i++;
    } else {
      examples = undefined;
      prose.push(line);
    }
  }
  finishSense();
  return wrapper;
}
function definitionBody(definition) {
  const wrapper = element('div');
  const heading = element('div', undefined, 'definition-heading');
  heading.append(element('h2', definition.head),
    button('moji 词典', () => api.call('moji', { word: definition.head }), 'dictionary-link'));
  wrapper.append(heading);
  if (definition.reading) wrapper.append(element('p', definition.reading, 'reading'));
  if (definition.pos?.length) wrapper.append(element('p', definition.pos.join(' · '), 'pos'));
  if (definition.english) wrapper.append(section('英文释义', definition.english));
  if (definition.chinese) wrapper.append(section('中文释义', definition.chinese));
  if (definition.dictionaryText) wrapper.append(importedDictionarySection(definition.dictionaryName, definition.dictionaryText));
  if (!definition.english && !definition.chinese && !definition.dictionaryText) wrapper.append(element('p', '离线词典未找到释义，可尝试大模型释义。'));
  if (definition.etymology) wrapper.append(section('词源', definition.etymology));
  if (definition.source || (definition.dictionaryName && !definition.dictionaryText)) {
    wrapper.append(element('p', definition.source || definition.dictionaryName, 'source'));
  }
  return wrapper;
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
    if (value.serviceName) detail.append(element('small', value.serviceName));
    if (!value.saved) detail.append(button('重新分析', () => runAction('analysis', true, value.selection)));
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
  return state.words.filter(word => [word.definition.head, word.definition.reading, word.definition.chinese, word.definition.english, word.definition.dictionaryText].join(' ').toLowerCase().includes(search));
}
function renderWords() {
  const words = filteredWords();
  $('words').replaceChildren(...words.map(word => {
    const row = button('', () => {
      const detail = $('detail-body'); detail.replaceChildren(definitionBody(word.definition));
      for (const example of word.examples) {
        detail.append(section(`${example.filename} · 第 ${example.page + 1} ${example.kind === 'PDF' ? '页' : '节'}`, example.sentence, 'original'));
        if (example.definition?.chinese && example.definition.chinese !== word.definition.chinese) detail.append(section('语境释义', example.definition.chinese));
        if (example.definition?.dictionaryText && example.definition.dictionaryText !== word.definition.dictionaryText) {
          detail.append(importedDictionarySection(example.definition.dictionaryName, example.definition.dictionaryText));
        }
      }
      detail.append(button('删除这个单词', async () => { sync(await api.call('delete-word', { id: word.id })); clearDetail(); }));
    }, 'word-card');
    row.append(element('strong', word.definition.head), element('small', word.definition.reading), element('p', (word.definition.chinese || word.definition.english || word.definition.dictionaryText || '').slice(0, 180)));
    return row;
  }));
  if (!words.length) $('words').append(element('p', state.words.length ? '没有匹配的单词。' : '在阅读中查询单词后，可以保存到这里。', 'muted'));
}
function notesBook() {
  return state.books.find(book => book.id === notesBookID) || currentBook();
}
function noteLocation(book, page) {
  return `第 ${page + 1} ${book.kind === 'PDF' ? '页' : '节'}`;
}
function renderNotes() {
  const book = notesBook();
  const kind = $('notes-kind').value;
  $('new-note').hidden = $('notes-search').hidden = kind !== 'notes';
  const query = kind === 'notes' ? $('notes-search').value.trim().toLowerCase() : '';
  const notesByBook = new Map();
  const records = kind === 'chats' ? state.chats.slice().reverse() : state[kind];
  for (const record of records) {
    const bookID = kind === 'notes' ? record.bookID : record.selection.bookID;
    if (!notesByBook.has(bookID)) notesByBook.set(bookID, []);
    notesByBook.get(bookID).push(record);
  }
  $('notes-books').replaceChildren(...state.books.map(item => {
    const label = `${item.name} · ${notesByBook.get(item.id)?.length ?? 0}`;
    const row = button(label, () => { notesBookID = item.id; $('notes-search').value = ''; renderNotes(); }, `book-item${item.id === book.id ? ' active' : ''}`);
    row.setAttribute('aria-pressed', item.id === book.id);
    return row;
  }));
  $('notes-book-title').textContent = query ? '搜索结果' : book.name;
  if (kind !== 'notes') {
    renderBookHistory(book, notesByBook.get(book.id) ?? [], kind === 'analyses');
    return;
  }
  const notes = query ? state.notes.filter(note =>
    note.body.toLowerCase().includes(query) || note.excerpt?.toLowerCase().includes(query)
  ) : notesByBook.get(book.id) ?? [];
  const booksByID = new Map(state.books.map(item => [item.id, item]));
  $('note-list').replaceChildren(...notes.map(note => {
    const sourceBook = booksByID.get(note.bookID);
    const card = element('article', undefined, 'note-card');
    const actions = element('div', undefined, 'button-row');
    if (query) card.append(element('small', sourceBook.name));
    const source = button(noteLocation(sourceBook, note.page), () => navigate(sourceBook.id, note.page, 0));
    source.title = '返回原文';
    actions.append(source, button('编辑', () => openNote(note)), button('删除', async () => {
      if (window.confirm('删除这条笔记？')) sync(await api.call('delete-note', { id: note.id }));
    }));
    card.append(actions);
    if (note.excerpt) card.append(element('blockquote', note.excerpt, 'note-excerpt'));
    if (note.body.trim()) card.append(element('p', note.body, 'note-body'));
    return card;
  }));
  if (!notes.length) $('note-list').append(element('p', query ? '没有匹配的笔记。' : '这本书还没有笔记。', 'muted'));
}
function renderBookHistory(book, records, isAnalysis) {
  $('note-list').replaceChildren(...records.map(entry => {
    const card = element('article', undefined, 'note-card');
    const actions = element('div', undefined, 'button-row');
    const source = entry.selection;
    actions.append(element('small', noteLocation(book, source.page)),
      button(isAnalysis ? '查看分析' : '继续对话', async () => {
        await navigate(book.id, source.page, source.start);
        if (isAnalysis) renderResult({ ...entry, type: 'analysis', saved: true });
        else await showChat(source);
      }),
      button('删除', async () => {
        if (window.confirm('删除这条记录？')) {
          sync(await api.call(isAnalysis ? 'delete-analysis' : 'delete-chat', { id: entry.id }));
        }
      }));
    card.append(actions, element('blockquote', source.text, 'note-excerpt'),
      element('small', isAnalysis ? entry.serviceName : entry.messages[0]?.content));
    return card;
  }));
  if (!records.length) $('note-list').append(element('p', isAnalysis ? '这本书还没有长句分析记录。' : '这本书还没有对话记录。', 'muted'));
}
function openNote(draft) {
  const book = state.books.find(item => item.id === draft.bookID);
  const excerpt = draft.excerpt ?? (draft.start === undefined ? '' : book.pages[draft.page].slice(draft.start, draft.end));
  noteDraft = draft;
  $('note-location').textContent = `${book.name} · ${noteLocation(book, draft.page)}`;
  $('note-excerpt').textContent = excerpt;
  $('note-excerpt').hidden = !excerpt;
  $('note-body').value = draft.body ?? '';
  $('note-body').required = !excerpt.trim();
  $('note-body-label').textContent = excerpt.trim() ? '笔记正文（可选）' : '笔记正文';
  $('note-error').hidden = true;
  $('note-dialog').showModal();
  $('note-body').focus();
}
function readerSelection() {
  const browserSelection = window.getSelection(); const reader = $('reader');
  if (!state || view !== 'reading' || !browserSelection?.rangeCount || browserSelection.isCollapsed ||
      !reader.contains(browserSelection.anchorNode) || !reader.contains(browserSelection.focusNode)) return null;
  const range = browserSelection.getRangeAt(0); const prefix = range.cloneRange();
  prefix.selectNodeContents(reader); prefix.setEnd(range.startContainer, range.startOffset);
  const start = prefix.toString().length, end = start + range.toString().length;
  return { range, payload: selectionPayload(start, end) };
}
let selectionTimer, selectionRequest = 0;
async function updateSelection() {
  const id = ++selectionRequest;
  const activeSelection = readerSelection();
  const toolbar = $('selection-toolbar');
  if (!activeSelection || $('note-dialog').open) { toolbar.hidden = true; return; }
  const { range, payload } = activeSelection;
  let level; try { level = await api.call('level', payload); } catch { level = 'none'; }
  const book = currentBook();
  if (id !== selectionRequest || view !== 'reading' || $('note-dialog').open ||
      payload.bookID !== book.id || payload.page !== book.page) return;
  selection = payload;
  toolbar.replaceChildren();
  if (level === 'word') {
    toolbar.append(button('词典释义', () => runAction('dictionary')), button('大模型释义', () => runAction('definition')));
  } else if (level === 'sentence') toolbar.append(button('本地翻译', () => runAction('translate')), button('长句分析', () => runAction('analysis')));
  else if (level === 'paragraph') toolbar.append(button('本地翻译', () => runAction('translate')));
  if (level !== 'none') toolbar.append(button('大模型对话', () => showChat()));
  if (!toolbar.childElementCount) { toolbar.hidden = true; return; }
  toolbar.hidden = false;
  const rect = range.getBoundingClientRect(), box = toolbar.getBoundingClientRect();
  toolbar.style.left = `${Math.max(8, Math.min(window.innerWidth - box.width - 8, rect.left + rect.width / 2 - box.width / 2))}px`;
  toolbar.style.top = `${rect.top > box.height + 12 ? rect.top - box.height - 9 : rect.bottom + 9}px`;
}
document.addEventListener('selectionchange', () => { clearTimeout(selectionTimer); selectionTimer = setTimeout(updateSelection, 90); });
$('selection-toolbar').addEventListener('mousedown', event => event.preventDefault());
$('reading-scroll').addEventListener('scroll', () => {
  $('selection-toolbar').hidden = true;
  const viewport = $('reading-scroll');
  if (viewport.classList.contains('paged') && view === 'reading') {
    viewport.scrollLeft = visiblePage * viewport.clientWidth;
  } else { captureReadingScroll(); }
});
$('reading-scroll').addEventListener('wheel', event => {
  if ($('reading-scroll').classList.contains('paged')) event.preventDefault();
}, { passive: false });
$('reader').addEventListener('keydown', event => {
  if (!$('reading-scroll').classList.contains('paged') || event.shiftKey || event.ctrlKey ||
      event.metaKey || event.altKey || !['ArrowLeft', 'ArrowRight'].includes(event.key)) return;
  event.preventDefault();
  attempt(() => turnPage(event.key === 'ArrowRight' ? 1 : -1));
});
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
  renderDictionarySettings();
  $('settings-dialog').showModal();
}
function renderDictionarySettings() {
  const options = [new Option('内置词典', '')];
  for (const info of state.settings.dictionaries || []) options.push(new Option(info.name, info.id));
  $('dictionary-source').replaceChildren(...options);
  $('dictionary-source').value = state.selectedDictionary;
  $('dictionary-status').textContent = state.dictionaryMessage || '';
}
async function updateDictionary(action, id) {
  const picker = $('dictionary-source'), importer = $('import-dictionary');
  picker.disabled = importer.disabled = true;
  $('dictionary-status').textContent = action === 'import-dictionary' ? '正在导入词典…' : '正在切换词典…';
  try {
    const next = await api.call(action, { id });
    if (next) {
      sync(next);
      if (!busy && view === 'reading' && result?.type === 'dictionary') {
        await runAction('dictionary', false, result.selection);
      }
    }
    renderDictionarySettings();
  } catch (error) {
    renderDictionarySettings();
    $('dictionary-status').textContent = error.message;
  } finally { picker.disabled = importer.disabled = false; }
}
$('dictionary-source').addEventListener('change', () => updateDictionary('select-dictionary', $('dictionary-source').value));
$('import-dictionary').addEventListener('click', () => updateDictionary('import-dictionary'));
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
$('previous').addEventListener('click', () => attempt(() => turnPage(-1)));
$('next').addEventListener('click', () => attempt(() => turnPage(1)));
$('page-number').addEventListener('change', () => attempt(() => navigate(currentBook().id, Number($('page-number').value) - 1, 0)));
$('reading-tab').addEventListener('click', () => { cancelQuery(); view = 'reading'; selection = null; clearDetail(); sync(state); });
$('notebook-tab').addEventListener('click', () => { captureReadingScroll(); cancelQuery(); view = 'notebook'; selection = null; $('selection-toolbar').hidden = true; clearDetail(); sync(state); });
$('notes-kind').addEventListener('change', renderNotes);
$('notes-tab').addEventListener('click', () => attempt(async () => {
  if (!state) return;
  captureReadingScroll();
  cancelQuery();
  const generation = uiGeneration;
  const next = await api.call('state');
  if (generation !== uiGeneration) return;
  view = 'notes'; selection = null; $('selection-toolbar').hidden = true; clearDetail();
  notesBookID ??= currentBook().id;
  sync(next);
}));
$('write-note').addEventListener('mousedown', event => event.preventDefault());
$('write-note').addEventListener('click', () => {
  if (!state) return;
  const book = currentBook();
  $('selection-toolbar').hidden = true;
  openNote(readerSelection()?.payload ?? { bookID: book.id, page: book.page });
});
$('new-note').addEventListener('click', () => {
  const book = notesBook();
  openNote({ bookID: book.id, page: book.page });
});
$('notes-search').addEventListener('input', renderNotes);
$('open-reading-search').addEventListener('click', () => setReadingSearchOpen(!readingSearchOpen));
$('close-reading-search').addEventListener('click', () => setReadingSearchOpen(false));
$('reading-query').addEventListener('input', resetReadingSearch);
$('reading-search').addEventListener('submit', event => { event.preventDefault(); attempt(findInBook); });
$('previous-match').addEventListener('click', () => attempt(() => jumpToMatch(matchIndex - 1)));
$('next-match').addEventListener('click', () => attempt(() => jumpToMatch(matchIndex + 1)));
document.addEventListener('keydown', event => {
  if (!state || document.querySelector('dialog[open]')) return;
  if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'f') {
    if (view === 'reading') setReadingSearchOpen(true);
    else $(view === 'notes' ? 'notes-search' : 'word-search').focus();
    event.preventDefault();
  }
});
$('cancel-note').addEventListener('click', () => $('note-dialog').close());
$('note-form').addEventListener('submit', async event => {
  event.preventDefault();
  const body = $('note-body').value;
  const save = $('save-note');
  if (save.disabled) return;
  save.disabled = true;
  $('cancel-note').disabled = true;
  $('note-error').hidden = true;
  try {
    sync(await api.call('save-note', { ...noteDraft, body }));
    $('note-dialog').close();
    notice('笔记已保存');
  } catch (error) {
    $('note-error').textContent = error.message;
    $('note-error').hidden = false;
  } finally {
    save.disabled = false;
    $('cancel-note').disabled = false;
  }
});
$('note-dialog').addEventListener('cancel', event => {
  if ($('save-note').disabled) event.preventDefault();
});
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
