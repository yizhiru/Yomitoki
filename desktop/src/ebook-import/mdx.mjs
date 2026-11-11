import { unzlibSync } from '../vendor/fflate/fflate.mjs';
import { plainText } from './text.mjs';

// MDX 2.0 layout: https://github.com/zhansliu/writemdict/blob/master/fileformat.md
const invalid = () => new Error('MDX 词典文件损坏或内容过大。');
const maximumBlock = 32_000_000;
export const maximumDictionaryText = 80_000_000;

class Cursor {
  constructor(bytes) {
    this.bytes = bytes;
    this.view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    this.offset = 0;
  }
  get remaining() { return this.bytes.length - this.offset; }
  take(length) {
    if (!Number.isSafeInteger(length) || length < 0 || length > this.remaining) throw invalid();
    const start = this.offset;
    this.offset += length;
    return this.bytes.subarray(start, this.offset);
  }
  uint(width) {
    const start = this.offset;
    this.take(width);
    if (width === 8) {
      const value = Number(this.view.getBigUint64(start));
      if (!Number.isSafeInteger(value)) throw invalid();
      return value;
    }
    return width === 4 ? this.view.getUint32(start) : this.view.getUint16(start);
  }
  keyword(unit) {
    const start = this.offset;
    while (this.remaining >= unit) {
      const bytes = this.take(unit);
      if (bytes.every(byte => byte === 0)) return this.bytes.subarray(start, this.offset - unit);
    }
    throw invalid();
  }
}

const leftWords = [
  [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
  [7, 4, 13, 1, 10, 6, 15, 3, 12, 0, 9, 5, 2, 14, 11, 8],
  [3, 10, 14, 4, 9, 15, 8, 1, 2, 7, 0, 6, 13, 11, 5, 12],
  [1, 9, 11, 10, 0, 8, 12, 4, 13, 3, 7, 15, 14, 5, 6, 2],
];
const rightWords = [
  [5, 14, 7, 0, 9, 2, 11, 4, 13, 6, 15, 8, 1, 10, 3, 12],
  [6, 11, 3, 7, 0, 13, 5, 10, 14, 15, 8, 12, 4, 9, 1, 2],
  [15, 5, 1, 3, 7, 14, 6, 9, 11, 8, 12, 2, 10, 0, 4, 13],
  [8, 6, 4, 1, 3, 11, 15, 0, 5, 12, 2, 13, 9, 7, 10, 14],
];
const leftRotations = [
  [11, 14, 15, 12, 5, 8, 7, 9, 11, 13, 14, 15, 6, 7, 9, 8],
  [7, 6, 8, 13, 11, 9, 7, 15, 7, 12, 15, 9, 11, 7, 13, 12],
  [11, 13, 6, 7, 14, 9, 13, 15, 14, 8, 13, 6, 5, 12, 7, 5],
  [11, 12, 14, 15, 14, 15, 9, 8, 9, 14, 5, 6, 8, 6, 5, 12],
];
const rightRotations = [
  [8, 9, 9, 11, 13, 15, 15, 5, 7, 7, 8, 11, 14, 14, 12, 6],
  [9, 13, 15, 7, 12, 8, 9, 11, 7, 7, 12, 7, 6, 15, 13, 11],
  [9, 7, 15, 11, 8, 6, 6, 14, 12, 13, 5, 14, 13, 13, 7, 5],
  [15, 5, 8, 11, 14, 14, 6, 14, 6, 9, 12, 9, 12, 5, 15, 8],
];
const mix = [(x, y, z) => x ^ y ^ z, (x, y, z) => (x & y) | (~x & z),
  (x, y, z) => (x | ~y) ^ z, (x, y, z) => (x & z) | (y & ~z)];

// MDX only hashes an eight-byte seed, so this RIPEMD-128 input occupies one padded block.
function indexKey(checksum) {
  const seed = new DataView(new ArrayBuffer(64));
  seed.setUint32(0, checksum);
  seed.setUint32(4, 0x3695, true);
  seed.setUint8(8, 0x80);
  seed.setUint8(56, 64);
  const initial = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476];
  const lane = (words, rotations, constants, reverse) => {
    let [a, b, c, d] = initial;
    for (let round = 0; round < 4; round++) {
      const combine = mix[reverse ? 3 - round : round];
      for (let step = 0; step < 16; step++) {
        const value = a + combine(b, c, d) + seed.getUint32(words[round][step] * 4, true) + constants[round];
        const shift = rotations[round][step];
        [a, b, c, d] = [d, (value << shift) | (value >>> (32 - shift)), b, c];
      }
    }
    return [a, b, c, d];
  };
  const [a, b, c, d] = lane(leftWords, leftRotations, [0, 0x5a827999, 0x6ed9eba1, 0x8f1bbcdc], false);
  const [aa, bb, cc, dd] = lane(rightWords, rightRotations, [0x50a28be6, 0x5c4dd124, 0x6d703ef3, 0], true);
  const output = new DataView(new ArrayBuffer(16));
  [initial[1] + c + dd, initial[2] + d + aa, initial[3] + a + bb, initial[0] + b + cc]
    .forEach((value, index) => output.setUint32(index * 4, value, true));
  return new Uint8Array(output.buffer);
}

function adler32(bytes) {
  let a = 1, b = 0;
  for (const byte of bytes) {
    a = (a + byte) % 65521;
    b = (b + a) % 65521;
  }
  return ((b << 16) | a) >>> 0;
}

function block(bytes, length, encrypted = false) {
  if (bytes.length < 8 || length > maximumBlock) throw invalid();
  const header = new DataView(bytes.buffer, bytes.byteOffset, 8);
  const type = header.getUint32(0, true), checksum = header.getUint32(4);
  let payload = bytes.subarray(8);
  if (encrypted) {
    const key = indexKey(checksum);
    let previous = 0x36;
    payload = payload.map((byte, index) => {
      const decoded = ((byte >> 4) | (byte << 4)) ^ previous ^ index ^ key[index % key.length];
      previous = byte;
      return decoded;
    });
  }
  if (type === 2) {
    // An extra byte makes an oversized inflate detectable while bounding allocation.
    payload = unzlibSync(payload, { out: new Uint8Array(length + 1) });
  } else if (type !== 0) {
    throw new Error('此 MDX 使用了暂不支持的压缩格式。');
  }
  if (payload.length !== length || adler32(payload) !== checksum) throw invalid();
  return payload;
}

export function decodeMdx(bytes, formatEntry) {
  const file = new Cursor(bytes);
  const headerLength = file.uint(4);
  if (headerLength > 1_000_000) throw invalid();
  const header = new TextDecoder('utf-16le', { fatal: true }).decode(file.take(headerLength));
  file.take(4);
  const attribute = name => header.match(new RegExp(`(?:^|\\s)${name}="([^"]*)"`, 'i'))?.[1];
  if (!/^\s*<Dictionary\b/i.test(header) || Number(attribute('GeneratedByEngineVersion')) !== 2) {
    throw new Error('请选择 MDict 2.0 格式的 .mdx 词典。');
  }
  const encrypted = attribute('Encrypted') || '0';
  if (!['No', '0', '2'].includes(encrypted)) throw new Error('此 MDX 词典需要注册码，暂无法导入。');
  const encoding = (attribute('Encoding') || 'UTF-8').toLowerCase();
  const decoder = new TextDecoder(encoding === 'utf16' ? 'utf-16le' : encoding, { fatal: true });
  const unit = decoder.encoding.startsWith('utf-16') ? 2 : 1;
  const isPlainText = attribute('Format')?.toLowerCase() === 'text';

  const keyBlocks = file.uint(8), count = file.uint(8), indexSize = file.uint(8), compressedIndex = file.uint(8), keySize = file.uint(8);
  file.take(4);
  if (count === 0 || count > 1_000_000 || keyBlocks > count) throw invalid();
  const keyIndex = new Cursor(block(file.take(compressedIndex), indexSize, encrypted === '2'));
  const keys = [];
  const keyData = new Cursor(file.take(keySize));
  for (let index = 0; index < keyBlocks; index++) {
    const entries = keyIndex.uint(8);
    if (entries > count - keys.length) throw invalid();
    for (let edge = 0; edge < 2; edge++) keyIndex.take((keyIndex.uint(2) + 1) * unit);
    const size = keyIndex.uint(8);
    const chunk = new Cursor(block(keyData.take(size), keyIndex.uint(8)));
    for (let entry = 0; entry < entries; entry++) {
      const offset = chunk.uint(8);
      if (keys.length && offset < keys.at(-1).offset) throw invalid();
      keys.push({ offset, key: decoder.decode(chunk.keyword(unit)).trim() });
    }
    if (chunk.remaining) throw invalid();
  }
  if (keys.length !== count || keyIndex.remaining || keyData.remaining) throw invalid();

  const recordBlocks = file.uint(8);
  if (file.uint(8) !== count) throw invalid();
  const recordIndexSize = file.uint(8), recordSize = file.uint(8);
  const recordIndex = new Cursor(file.take(recordIndexSize));
  const records = new Cursor(file.take(recordSize));
  if (recordBlocks * 16 !== recordIndex.remaining) throw invalid();
  const entries = new Map();
  let entry = 0, recordStart = 0, pending = [], outputLength = 0;
  for (let index = 0; index < recordBlocks; index++) {
    const compressed = recordIndex.uint(8);
    const chunk = block(records.take(compressed), recordIndex.uint(8));
    const recordEnd = recordStart + chunk.length;
    while (entry < count && keys[entry].offset <= recordEnd) {
      const { offset } = keys[entry];
      let next = entry + 1;
      while (next < count && keys[next].offset === offset) next++;
      const end = keys[next]?.offset ?? (index === recordBlocks - 1 ? recordEnd : Infinity);
      const part = chunk.subarray(Math.max(0, offset - recordStart), Math.min(chunk.length, end - recordStart));
      if (Math.min(end, recordEnd) - offset > maximumBlock) throw invalid();
      if (end > recordEnd) {
        if (part.length) pending.push(part);
        break;
      }
      let raw = '';
      for (const slice of pending) raw += decoder.decode(slice, { stream: true });
      raw += decoder.decode(part);
      pending = [];
      const value = formatEntry(raw.replace(/\0+$/g, ''), isPlainText);
      while (entry < next) {
        const { key } = keys[entry++];
        if (!key || !value) continue;
        outputLength += key.length + value.length;
        if (outputLength > maximumDictionaryText) throw invalid();
        const previous = entries.get(key);
        if (!previous || previous.startsWith('@@@LINK=')) entries.set(key, value);
        else if (!value.startsWith('@@@LINK=') && previous !== value) entries.set(key, previous + '\n\n' + value);
      }
    }
    recordStart = recordEnd;
  }
  if (entry !== count || records.remaining || !entries.size) throw invalid();
  return entries;
}

export function importMdx(bytes) {
  const template = document.createElement('template');
  return decodeMdx(bytes, (raw, isPlainText) => {
    if (isPlainText || raw.startsWith('@@@LINK=')) return raw.trim();
    template.innerHTML = raw;
    return plainText(template.content);
  });
}
