const fs = require('node:fs');
const path = require('node:path');
const { randomUUID, createHash } = require('node:crypto');

const sampleText = '雨が上がったので、傘を閉じて小さな喫茶店に入った。窓際の席に座ると、淹れたての珈琲の香りが漂ってきた。\n\n店主は「お好きな席へどうぞ」と言って、穏やかに微笑んだ。私は鞄から読みかけの小説を取り出した。\n\n頁をめくるたび、街の音が少しずつ遠ざかっていくようだった。';
function defaults() {
  const book = { id: randomUUID(), name: '雨上がりの喫茶店（示例）', kind: 'TXT', pages: [sampleText], page: 0 };
  return { version: 1, books: [book], current: book.id, words: [], notes: [], chats: [], caches: {},
    settings: { fontSize: 26, definitionSize: 20, singleClick: false, sidebarWidth: 220, detailWidth: 380,
      provider: 'deepseek', model: 'deepseek-flash', url: 'https://api.deepseek.com', mirror: 'hf', modelPath: '', translationAcceleration: 'auto' } };
}
class Store {
  constructor(directory) {
    fs.mkdirSync(directory, { recursive: true });
    this.file = path.join(directory, 'library.json');
    this.directory = directory;
    this.data = fs.existsSync(this.file) ? JSON.parse(fs.readFileSync(this.file, 'utf8')) : defaults();
    if (!Array.isArray(this.data.books) || !Array.isArray(this.data.words) || !this.data.settings) throw new Error('数据文件无法读取，原文件已保留。');
    this.data.chats ||= []; this.data.caches ||= {};
    this.data.analyses ??= [];
    if (!Array.isArray(this.data.analyses)) throw new Error('长句分析记录无法读取，原文件已保留。');
    this.data.notes ??= [];
    if (!Array.isArray(this.data.notes)) throw new Error('笔记数据无法读取，原文件已保留。');
    this.data.settings.translationAcceleration ||= 'auto';
  }
  change(update) {
    const next = structuredClone(this.data);
    update(next);
    const temporary = `${this.file}.${randomUUID()}.tmp`;
    try {
      fs.writeFileSync(temporary, JSON.stringify(next), { encoding: 'utf8', mode: 0o600 });
      fs.renameSync(temporary, this.file);
      this.data = next;
    } finally { fs.rmSync(temporary, { force: true }); }
  }
  get book() {
    if (this.data.current === null) return undefined;
    return this.data.books.find(book => book.id === this.data.current)
      ?? this.data.books.find(book => !book.removedFromShelf);
  }
  saveNote({ id, bookID, page, start, end, body }) {
    if (typeof body !== 'string') throw new Error('笔记正文无效。');
    if (id !== undefined) {
      const index = this.data.notes.findIndex(note => note.id === id);
      if (index === -1) throw new Error('这条笔记已不存在。');
      if (!body.trim() && !this.data.notes[index].excerpt?.trim()) throw new Error('请输入笔记正文。');
      this.change(data => { data.notes[index].body = body; });
      return;
    }
    const book = this.data.books.find(book => book.id === bookID);
    const text = book?.pages[page];
    if (!Number.isInteger(page) || typeof text !== 'string') throw new Error('笔记来源无效。');
    let excerpt;
    if (start !== undefined || end !== undefined) {
      if (!Number.isInteger(start) || !Number.isInteger(end) || start < 0 || end <= start || end > text.length) {
        throw new Error('选文范围无效。');
      }
      excerpt = text.slice(start, end);
    }
    if (!body.trim() && !excerpt?.trim()) throw new Error('请输入笔记正文或选中原文。');
    this.change(data => { data.notes.unshift({ id: randomUUID(), bookID, page, excerpt, body }); });
  }
  deleteNote(id) {
    this.change(data => { data.notes = data.notes.filter(note => note.id !== id); });
  }
  publicState() {
    const state = structuredClone(this.data);
    delete state.settings.keyBlob; delete state.caches;
    state.hasKey = Boolean(this.data.settings.keyBlob);
    return state;
  }
  cacheKey(...values) { return createHash('sha256').update(JSON.stringify(values)).digest('hex'); }
  cached(key) { return this.data.caches[key]; }
  cache(key, value) {
    this.change(data => {
      data.caches[key] = value;
      const keys = Object.keys(data.caches);
      if (keys.length > 2000) for (const old of keys.slice(0, keys.length - 2000)) delete data.caches[old];
    });
  }
}
function exportWords(words, format = 'csv', fields = ['reading', 'chinese', 'english', 'source', 'sentence', 'location']) {
  const columns = [['head', '单词'], ['reading', '读音'], ['chinese', '中文释义'], ['english', '英文释义'],
    ['source', '释义来源'], ['etymology', '词源'], ['sentence', '原句'], ['location', '文件与位置']].filter(([key]) => key === 'head' || fields.includes(key));
  const rows = words.flatMap(word => (fields.includes('sentence') || fields.includes('location') ? word.examples : [null]).map(example => {
    const definition = example?.definition || word.definition;
    return columns.map(([key]) => {
      if (key === 'sentence') return example?.sentence || '';
      if (key === 'location') return example ? `${example.filename} · 第 ${example.page + 1} ${example.kind === 'PDF' ? '页' : '节'}` : '';
      if (key === 'source' && definition.dictionaryName) return definition.dictionaryName;
      return definition[key] || word.definition[key] || '';
    });
  }));
  if (format === 'txt') return rows.map(row => row.map((value, index) => `${columns[index][1]}：${value}`).join('\n')).join('\n\n');
  const escape = value => `"${String(value).replaceAll('"', '""')}"`;
  return '\uFEFF' + [columns.map(([, title]) => title), ...rows].map(row => row.map(escape).join(',')).join('\r\n');
}
module.exports = { Store, defaults, exportWords, sampleText };
