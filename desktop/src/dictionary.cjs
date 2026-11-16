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
function contextualReading(text, start, surface, candidates) {
  const before = text.slice(0, start).split(/[。！？!?\n、，,]/u).at(-1);
  let patterns;
  if (surface.startsWith('行')) {
    patterns = [[/(?:駅|学校|病院|会社|公園|店|東京|京都|家|旅行|買い物)(?:へ|に)$/u, 'い'],
      [/(?:会議|調査|試験|実験|検査|手術|練習|授業|選挙|式典|研究)を$/u, 'おこな']];
  } else if (surface.startsWith('開')) {
    patterns = [[/(?:扉|ドア|窓|門|蓋|ふた|店)が$/u, 'あ'],
      [/(?:扉|ドア|窓|門|蓋|ふた|本|傘|会議|会|店|口|目)を$/u, 'ひら'],
      [/(?:会議|会|店|花|花びら)が$/u, 'ひら']];
  } else return '';
  const matching = patterns.filter(([pattern]) => pattern.test(before));
  if (matching.length !== 1) return '';
  const readings = [...candidates].filter(reading => reading.startsWith(matching[0][1]));
  return readings.length === 1 ? readings[0] : '';
}
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
  isWord(form) {
    if (this.entries(form).length) return true;
    const tokens = this.tokens(form);
    if (tokens.length < 2 || tokens[0].surface_form.length === 0 ||
        tokens[1].basic_form !== 'する' || tokens.slice(2).some(token => !['助動詞', '助詞'].includes(token.pos))) return false;
    return this.entries(tokens[0].surface_form).some(entry =>
      entry.pos.split(' ').some(pos => ['vs', 'vs-i', 'vs-s'].includes(pos)));
  }
  readingAnnotations(text, saved, showKana) {
    let cursor = 0;
    const annotations = [];
    const readingsByForm = new Map();
    for (const token of this.tokens(text)) {
      const surface = token.surface_form;
      const start = text.indexOf(surface, cursor);
      if (start < 0) continue;
      cursor = start + surface.length;
      const marked = saved.has(surface) || saved.has(token.basic_form);
      let kana = showKana && /\p{Script=Han}/u.test(surface) && /^[ァ-ヺー]+$/u.test(token.reading ?? '')
        ? hira(token.reading) : '';
      if (kana && surface === '行っ' && /^(?:た|て)/u.test(text.slice(cursor))) {
        const chosen = contextualReading(text, start, surface, new Set(['い', 'おこな']));
        kana = chosen ? chosen + 'っ' : '';
      } else if (kana && token.basic_form === surface) {
        const base = token.basic_form === '*' ? surface : token.basic_form;
        if (!readingsByForm.has(base)) {
          readingsByForm.set(base, new Set(this.entries(base).filter(entry => entry.head === base)
            .map(entry => hira(entry.reading))));
        }
        const candidates = readingsByForm.get(base);
        if (candidates.size > 1) {
          const chosen = contextualReading(text, start, surface, candidates);
          if (!chosen) kana = '';
          else if (token.basic_form === surface) kana = chosen;
          else if (!chosen.startsWith(kana.slice(0, 1))) kana = '';
        } else if (token.basic_form === surface && candidates.size === 1 && !candidates.has(kana)) {
          kana = '';
        }
      }
      if (!kana) {
        if (marked) annotations.push({ start, end: cursor, saved: true, kana: '' });
        continue;
      }
      let from = 0, to = surface.length, kanaStart = 0, kanaEnd = kana.length;
      while (from < to && kanaStart < kanaEnd && surface[from] === kana[kanaStart]) {
        from++; kanaStart++;
      }
      while (from < to && kanaStart < kanaEnd && surface[to - 1] === kana[kanaEnd - 1]) {
        to--; kanaEnd--;
      }
      if (marked && from > 0) annotations.push({ start, end: start + from, saved: true, kana: '' });
      if (to > from) {
        const base = surface.slice(from, to), reading = kana.slice(kanaStart, kanaEnd);
        const characters = [...base];
        let prefix = '';
        if (characters.length === 2 && /^[ぁ-ゖ]$/u.test(surface[to] || '') && /^\p{Script=Han}{2}$/u.test(base)) {
          const choices = new Set(this.entries(characters[0])
            .filter(entry => entry.head === characters[0])
            .map(entry => hira(entry.reading))
            .filter(value => value && reading.startsWith(value) && value.length < reading.length));
          if (choices.size === 1) prefix = [...choices][0];
        }
        if (prefix) {
          const boundary = start + from + characters[0].length;
          annotations.push({ start: start + from, end: boundary, saved: marked, kana: prefix });
          annotations.push({ start: boundary, end: start + to, saved: marked, kana: reading.slice(prefix.length) });
        } else {
          annotations.push({ start: start + from, end: start + to, saved: marked, kana: reading });
        }
      }
      if (marked && to < surface.length) annotations.push({ start: start + to, end: cursor, saved: true, kana: '' });
    }
    return annotations;
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
  if (dictionaryWord(selected)) return 'word';
  if (completeStart && completeEnd && (/[。！？!?]/.test(selected) || content.length > 1)) return 'sentence';
  if (tokens.length === 1 || (content.length === 1 && !tokens.some(token => token.pos === '助詞'))) return 'word';
  return 'fragment';
}
module.exports = { Dictionary, ImportedDictionary, selectionLevel, hira };
