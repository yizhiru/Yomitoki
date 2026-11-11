import { inflateSync } from '../vendor/fflate/fflate.mjs';
import { inspectZip } from './zip.mjs';

const limits = { file: 50 * 1024 ** 2, unpacked: 350 * 1024 ** 2, entry: 32 * 1024 ** 2, entries: 512 };
const decoder = new TextDecoder('utf-8', { fatal: true });
const bankName = /^term_bank_(\d+)\.json$/;
const blockTags = new Set(['br', 'div', 'p', 'li', 'ul', 'ol', 'table', 'tr', 'details', 'summary']);
const omittedTags = new Set(['script', 'style', 'img', 'audio', 'video', 'iframe', 'svg']);
const blockClasses = new Set(['def0', 'def1', 'def2', 'def2_first', 'exam', 'head']);
const crcTable = Uint32Array.from({ length: 256 }, (_, value) => {
  for (let bit = 0; bit < 8; bit++) value = (value >>> 1) ^ ((value & 1) ? 0xedb88320 : 0);
  return value >>> 0;
});
const hira = text => text.replace(/[ァ-ヶ]/g, char => String.fromCharCode(char.charCodeAt(0) - 0x60));

function readJSON(bytes, entry) {
  const { local, directoryOffset, compressed, unpacked, method, crc } = entry;
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (view.getUint32(local, true) !== 0x04034b50 || view.getUint16(local + 8, true) !== method ||
      view.getUint16(local + 6, true) & 1) throw new Error('词典 ZIP 文件头损坏。');
  const start = local + 30 + view.getUint16(local + 26, true) + view.getUint16(local + 28, true);
  if (start + compressed > directoryOffset) throw new Error('词典 ZIP 数据不完整。');
  const source = bytes.subarray(start, start + compressed);
  const data = method === 8 ? inflateSync(source, { out: new Uint8Array(unpacked + 1) }) : source;
  if (data.length !== unpacked) throw new Error('词典 ZIP 解压大小与目录不符。');
  let checksum = 0xffffffff;
  for (const byte of data) checksum = crcTable[(checksum ^ byte) & 255] ^ (checksum >>> 8);
  if (((checksum ^ 0xffffffff) >>> 0) !== crc) throw new Error('词典 ZIP 校验失败。');
  return JSON.parse(decoder.decode(data));
}

// Meikyo uses def* and exam groups, with inline Japanese and lang="zh" translations.
// Walk the source in order and start each translation on its own line.
export function glossaryText(glossary) {
  const output = [];
  let visited = 0;
  function visit(node, depth, chinese = false) {
    if (depth > 40 || ++visited > 80_000) throw new Error('词条结构过大。');
    if (typeof node === 'string') {
      output.push(node);
    } else if (Array.isArray(node)) {
      for (const child of node) visit(child, depth + 1, chinese);
    } else if (node && typeof node === 'object' && !omittedTags.has(node.tag)) {
      const translation = typeof node.lang === 'string' ? /^zh(?:-|$)/i.test(node.lang) : chinese;
      const boundary = blockTags.has(node.tag) || blockClasses.has(node.data?.class);
      if (boundary || (translation && !chinese)) output.push('\n');
      visit(node.content, depth + 1, translation);
      if (boundary) output.push('\n');
    }
  }
  for (const item of glossary) {
    visit(item, 0);
    output.push('\n');
  }
  return output.join('').replace(/\r/g, '').replace(/[\t \u00a0]+/g, ' ')
    .replace(/ *\n */g, '\n').replace(/\n{2,}/g, '\n').trim();
}

export function importYomitan(bytes) {
  if (bytes.length > limits.file) throw new Error('Yomitan ZIP 词典上限为 50 MB。');
  const files = new Map();
  inspectZip(bytes, limits, entry => {
    const name = decoder.decode(entry.name);
    if (files.has(name) || ![0, 8].includes(entry.method)) throw new Error('词典 ZIP 项目重复或压缩格式不受支持。');
    files.set(name, entry);
  }, 'Yomitan 词典');

  const banks = [...files.keys()].filter(name => bankName.test(name));
  banks.sort((left, right) => Number(bankName.exec(left)[1]) - Number(bankName.exec(right)[1]));
  const metadata = files.has('index.json') && readJSON(bytes, files.get('index.json'));
  if (!banks.length || metadata?.format !== 3 || typeof metadata.title !== 'string' || !metadata.title.trim()) {
    throw new Error('请选择根目录包含 index.json 和词条文件的 Yomitan v3 ZIP 词典。');
  }

  const terms = new Map();
  let count = 0;
  for (const bank of banks) {
    const rows = readJSON(bytes, files.get(bank));
    if (!Array.isArray(rows)) throw new Error('Yomitan 词条文件无效。');
    for (const row of rows) {
      if (++count > 300_000) throw new Error('Yomitan 词条数量超过 300,000 条。');
      if (!Array.isArray(row) || row.length !== 8 || typeof row[0] !== 'string' || typeof row[1] !== 'string' ||
          !Array.isArray(row[5]) || row[0].length > 256 || row[1].length > 256 || /[\r\n]/.test(row[0] + row[1])) {
        throw new Error('发现无效的 Yomitan 词条。');
      }
      const head = row[0].trim().normalize('NFKC');
      const reading = hira(row[1].trim().normalize('NFKC'));
      const meaning = glossaryText(row[5]);
      if (!head || !meaning) continue;
      if (!terms.has(head)) terms.set(head, new Map());
      const variants = terms.get(head);
      if (!variants.has(reading)) variants.set(reading, new Set());
      variants.get(reading).add(meaning);
    }
  }

  const entries = new Map();
  for (const [head, variants] of terms) {
    const meanings = new Set();
    for (const [reading, texts] of variants) {
      for (const text of texts) meanings.add(text);
      if (reading && variants.size > 1) entries.set(head + '\n' + reading, [...texts].join('\n\n'));
    }
    entries.set(head, [...meanings].join('\n\n'));
  }
  if (!entries.size) throw new Error('Yomitan 词典没有可读取的释义。');
  return { title: metadata.title.trim().slice(0, 160), entries };
}
