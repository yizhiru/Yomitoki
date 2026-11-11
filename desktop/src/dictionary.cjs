const fs = require('node:fs');
const path = require('node:path');
const kuromoji = require('kuromoji');
const initSQL = require('sql.js');

const hira = text => String(text || '').replace(/[ァ-ヶ]/g, char => String.fromCharCode(char.charCodeAt(0) - 0x60));
const POS = { n: '名词', 'n-pr': '专有名词', adj: '形容词', 'adj-i': 'い形容词', 'adj-na': 'な形容词',
  v1: '一段动词', v5r: '五段动词（ら行）', v5m: '五段动词（ま行）', v5k: '五段动词（か行）',
  v5g: '五段动词（が行）', v5s: '五段动词（さ行）', v5t: '五段动词（た行）', v5b: '五段动词（ば行）',
  v5n: '五段动词（な行）', v5u: '五段动词（わ行）', vs: 'する动词', 'vs-i': 'する动词', vk: '来る动词',
  vi: '自动词', vt: '他动词', adv: '副词', exp: '惯用表达', pn: '代词', conj: '连词', int: '感叹词' };
class Dictionary {
  async load(resources) {
    const SQL = await initSQL({ locateFile: file => path.join(path.dirname(require.resolve('sql.js')), file) });
    this.db = new SQL.Database(fs.readFileSync(path.join(resources, 'jmdict.sqlite')));
    this.chinese = new Map(fs.readFileSync(path.join(resources, 'zh.tsv'), 'utf8').split(/\r?\n/).map(row => {
      const index = row.indexOf('\t'); return [row.slice(0, index), row.slice(index + 1)];
    }));
    this.tokenizer = await new Promise((resolve, reject) => kuromoji.builder({ dicPath: path.join(path.dirname(require.resolve('kuromoji/package.json')), 'dict') })
      .build((error, tokenizer) => error ? reject(error) : resolve(tokenizer)));
    return this;
  }
  tokens(text) { return this.tokenizer.tokenize(text); }
  entries(form) {
    const statement = this.db.prepare('SELECT head,reading,meaning,pos,rank FROM entries WHERE form=? ORDER BY rank DESC LIMIT 24');
    try {
      statement.bind([form]); const rows = [];
      while (statement.step()) rows.push(statement.getAsObject());
      return rows;
    } finally { statement.free(); }
  }
  lookup(text, before = '', after = '') {
    if (!text.trim() || text.length > 100) throw new Error('请选择一个单词。');
    const tokens = this.tokens(text);
    const content = tokens.filter(token => !['助詞', '助動詞', '記号'].includes(token.pos));
    const first = content[0] || tokens[0];
    const base = first?.basic_form && first.basic_form !== '*' ? first.basic_form : text;
    const reading = hira(first?.reading);
    const candidates = [...this.entries(base), ...this.entries(text)];
    const entry = candidates.find(row => hira(row.reading) === reading) || candidates[0];
    return entry ? { head: entry.head, reading: entry.reading, chinese: this.chinese.get(entry.head) || '',
      english: entry.meaning.split('\n').slice(0, 4).map((meaning, index) => `${index + 1}. ${meaning}`).join('\n'),
      pos: entry.pos.split(' ').filter(Boolean).map(code => POS[code] || (code.startsWith('v5') ? '五段动词' : code)), source: '离线词典' }
      : { head: base, reading, chinese: this.chinese.get(base) || '', english: '', pos: [], source: '离线词典' };
  }
  wordAt(text, offset) {
    let cursor = 0;
    for (const token of this.tokens(text)) {
      const start = text.indexOf(token.surface_form, cursor);
      if (start < 0) continue;
      cursor = start + token.surface_form.length;
      if (offset >= start && offset < start + token.surface_form.length && token.pos !== '記号') return { start, end: start + token.surface_form.length };
    }
    return null;
  }
}
class ImportedDictionary {
  constructor(info, chunks) {
    this.info = info;
    this.entries = new Map();
    for (const chunk of chunks) {
      for (const [head, text] of Object.entries(JSON.parse(chunk))) this.entries.set(head, text);
    }
    if (!this.entries.size) throw new Error('词典没有可读取的词条。');
  }
  meaning(forms, reading = '') {
    const kana = hira(reading.normalize('NFKC'));
    const keys = forms.filter(Boolean).flatMap(form => {
      const normalized = form.normalize('NFKC');
      return kana ? [normalized + '\n' + kana, form, normalized] : [form, normalized];
    });
    for (const candidate of keys) {
      let key = candidate;
      const seen = new Set();
      while (key && !seen.has(key)) {
        const text = this.entries.get(key);
        if (!text) break;
        if (!text.startsWith('@@@LINK=')) return text;
        seen.add(key);
        key = text.slice(8).trim();
      }
    }
    return '';
  }
  lookup(text, definition) {
    return {
      head: definition.head, reading: definition.reading, pos: definition.pos,
      dictionaryName: this.info.name, dictionaryText: this.meaning([text.trim(), definition.head, definition.reading], definition.reading)
    };
  }
}
function selectionLevel(text, start, end, tokenizer, dictionaryWord = () => false) {
  if (!Number.isInteger(start) || !Number.isInteger(end) || start < 0 || end > text.length || end <= start) throw new Error('选区无效。');
  const selected = text.slice(start, end).trim();
  if (!selected || !/[\p{L}\p{N}]/u.test(selected)) return 'none';
  const sentences = selected.split(/[。！？!?]+[」』）】]*/u).filter(part => /[\p{L}\p{N}]/u.test(part));
  const completeStart = !text.slice(0, start).trimEnd() || /[。！？!?\n「『]\s*$/.test(text.slice(0, start));
  const completeEnd = /[。！？!?][」』）】]*$/.test(selected) || !text.slice(end).trim() || /^[。！？!?\n」』]/.test(text.slice(end).trimStart());
  if ((/\n\s*\n/.test(selected) || sentences.length > 1) && completeStart && completeEnd) return 'paragraph';
  const tokens = tokenizer ? tokenizer.tokenize(selected) : [];
  const content = tokens.filter(token => !['助詞', '助動詞', '記号'].includes(token.pos));
  if (completeStart && completeEnd && (/[。！？!?]/.test(selected) || content.length > 1)) return 'sentence';
  if (dictionaryWord(selected) || tokens.length === 1 || (content.length === 1 && !tokens.some(token => token.pos === '助詞'))) return 'word';
  return 'fragment';
}
module.exports = { Dictionary, ImportedDictionary, selectionLevel, hira };
