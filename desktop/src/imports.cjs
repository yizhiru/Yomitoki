const fs = require('node:fs/promises');
const path = require('node:path');
const { randomUUID } = require('node:crypto');

function paginate(text) {
  const paragraphs = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split(/\n\s*\n/).map(value => value.trim()).filter(Boolean);
  const pages = []; let current = '';
  for (const paragraph of paragraphs) {
    if (current && current.length + paragraph.length > 1100) { pages.push(current); current = ''; }
    current += (current ? '\n\n' : '') + paragraph;
  }
  if (current) pages.push(current);
  return pages;
}
async function readBook(file, { signal, parent, extractEbook } = {}) {
  signal?.throwIfAborted();
  const kind = path.extname(file).slice(1).toUpperCase();
  if (!['PDF', 'EPUB', 'MOBI', 'TXT'].includes(kind)) throw new Error('请选择 PDF、EPUB、MOBI 或 UTF-8 TXT 文件。');
  if ((await fs.stat(file)).size > 300_000_000) throw new Error('文件超过 300 MB，请先拆分。');
  let pages;
  if (kind === 'PDF') {
    const canvas = require('@napi-rs/canvas');
    globalThis.DOMMatrix ||= canvas.DOMMatrix;
    globalThis.ImageData ||= canvas.ImageData;
    globalThis.Path2D ||= canvas.Path2D;
    const { getDocument } = await import('pdfjs-dist/legacy/build/pdf.mjs');
    const task = getDocument({ data: new Uint8Array(await fs.readFile(file)), useSystemFonts: true, isEvalSupported: false });
    let document;
    try {
      document = await task.promise;
      pages = [];
      for (let number = 1; number <= document.numPages; number++) {
        const page = await document.getPage(number);
        const content = await page.getTextContent();
        pages.push(content.items.map(item => item.str + (item.hasEOL ? '\n' : '')).join('')
          .replace(/(?<=[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}、])\s*\n\s*(?=[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}])/gu, '').trim());
        page.cleanup();
      }
    } finally { await task.destroy(); }
  } else if (kind === 'TXT') pages = paginate(await fs.readFile(file, 'utf8'));
  else {
    const extract = extractEbook || require('./ebook-import.cjs').readEbook;
    const sections = await extract(file, { signal, parent });
    pages = paginate(sections.join('\n\n'));
  }
  signal?.throwIfAborted();
  if (!pages.some(page => page.trim())) throw new Error('没有可读取的文字。扫描 PDF 需要先进行 OCR。');
  if (pages.join('').length > 10_000_000) throw new Error('提取文字过多，请拆分文档。');
  return { id: randomUUID(), name: path.basename(file), kind, pages, page: 0 };
}
module.exports = { paginate, readBook };
