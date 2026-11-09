const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const { promisify } = require('node:util');
const { execFile } = require('node:child_process');
const run = promisify(execFile);
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
async function calibrePath() {
  const candidates = process.platform === 'win32' ? [
    path.join(process.env.ProgramFiles || 'C:\\Program Files', 'Calibre2', 'ebook-convert.exe'),
    path.join(process.env['ProgramFiles(x86)'] || 'C:\\Program Files (x86)', 'Calibre2', 'ebook-convert.exe'),
    path.join(process.env.LOCALAPPDATA || '', 'calibre', 'ebook-convert.exe')
  ] : ['/Applications/calibre.app/Contents/MacOS/ebook-convert'];
  for (const candidate of candidates) { try { await fs.access(candidate); return candidate; } catch {} }
  try {
    const found = await run(process.platform === 'win32' ? 'where.exe' : 'which', ['ebook-convert'], { windowsHide: true, timeout: 5000 });
    if (found.stdout.trim()) return found.stdout.trim().split(/\r?\n/)[0];
  } catch {}
  throw new Error('导入 EPUB / MOBI 需要安装 calibre（默认安装目录或 PATH）。');
}
async function readBook(file) {
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
    const scratch = await fs.mkdtemp(path.join(os.tmpdir(), 'yomitoki-'));
    try {
      const output = path.join(scratch, 'reading.txt');
      await run(await calibrePath(), [file, output, '--txt-output-formatting', 'plain', '--max-line-length', '0', '--txt-output-encoding', 'utf-8', '--newline', 'unix'],
        { windowsHide: true, timeout: 180000, maxBuffer: 2_000_000, env: { ...process.env, CALIBRE_CONFIG_DIRECTORY: scratch } });
      pages = paginate(await fs.readFile(output, 'utf8'));
    } finally { await fs.rm(scratch, { recursive: true, force: true }); }
  }
  if (!pages.some(page => page.trim())) throw new Error('没有可读取的文字。扫描 PDF 需要先进行 OCR。');
  if (pages.join('').length > 10_000_000) throw new Error('提取文字过多，请拆分文档。');
  return { id: randomUUID(), name: path.basename(file), kind, pages, page: 0 };
}
module.exports = { paginate, readBook, calibrePath };
