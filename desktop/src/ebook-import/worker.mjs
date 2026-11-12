import { EPUB } from '../vendor/foliate/epub.js';
import { MOBI } from '../vendor/foliate/mobi.js';
import { unzipSync, unzlibSync } from '../vendor/fflate/fflate.mjs';
import { LIMITS, inspectZip, inspectMobi } from './zip.mjs';
import { decodeText, plainText } from './text.mjs';
let book;
function metadataText(value) {
  if (typeof value === 'string') return value.trim().slice(0, 500);
  if (Array.isArray(value)) return value.map(metadataText).filter(Boolean).join('、').slice(0, 500);
  if (value?.name) return metadataText(value.name);
  if (value && typeof value === 'object') return Object.values(value).map(metadataText).find(Boolean) ?? '';
  return '';
}

async function run() {
  const { bytes: input, kind, name } = await window.ebookImport.input();
  const bytes = new Uint8Array(input);
  if (bytes.length > LIMITS.file) throw new Error('文件超过 300 MB，请先拆分。');
  if (kind === 'MDX' || kind === 'ZIP') {
    const sections = [];
    let entries;
    if (kind === 'ZIP') {
      const { importYomitan } = await import('./yomitan.mjs');
      const dictionary = importYomitan(bytes);
      sections.push(dictionary.title);
      entries = dictionary.entries;
    } else {
      const { importMdx } = await import('./mdx.mjs');
      entries = importMdx(bytes);
    }
    let chunk = Object.create(null), count = 0;
    for (const [key, text] of entries) {
      chunk[key] = text;
      if (++count % 1000 === 0) {
        sections.push(JSON.stringify(chunk));
        chunk = Object.create(null);
      }
    }
    if (count % 1000) sections.push(JSON.stringify(chunk));
    return { sections };
  }
  let loadText;
  if (kind === 'EPUB') {
    inspectZip(bytes);
    const files = unzipSync(bytes);
    const find = name => {
      if (Object.hasOwn(files, name)) return files[name];
      try { const decoded = decodeURIComponent(name); return Object.hasOwn(files, decoded) ? files[decoded] : undefined; } catch { return undefined; }
    };
    loadText = name => { const data = find(name); return data ? decodeText(data) : undefined; };
    const encrypted = loadText('META-INF/encryption.xml');
    if (encrypted) {
      const doc = new DOMParser().parseFromString(encrypted, 'application/xml');
      if (doc.querySelector('parsererror')) throw new Error('EPUB 加密信息损坏。');
      for (const method of doc.getElementsByTagNameNS('*', 'EncryptionMethod')) {
        if (!['http://www.idpf.org/2008/embedding', 'http://ns.adobe.com/pdf/enc#RC'].includes(method.getAttribute('Algorithm'))) throw new Error('此 EPUB 正文受 DRM 或加密保护，暂不支持导入。');
      }
    }
    book = await new EPUB({ loadText, loadBlob: name => { const data = find(name); return data ? new Blob([data]) : undefined; }, getSize: name => find(name)?.length || 0 }).init();
  } else {
    inspectMobi(bytes);
    book = await new MOBI({ unzlib: unzlibSync }).open(new File([bytes], name));
  }
  const sections = []; let total = 0;
  for (const section of book.sections) {
    const doc = await section.createDocument();
    if (!doc || doc.querySelector('parsererror')) throw new Error('电子书章节损坏，无法读取完整正文。');
    const styles = [];
    if (loadText) for (const link of doc.querySelectorAll('link[rel~="stylesheet"][href]')) {
      try {
        const resolved = new URL(link.getAttribute('href'), new URL(section.id, 'https://ebook.invalid/'));
        if (resolved.origin === 'https://ebook.invalid') { const css = loadText(resolved.pathname.slice(1)); if (css) styles.push(css); }
      } catch {}
    }
    const text = plainText(doc, styles);
    if ((total += text.length) > LIMITS.text) throw new Error('提取文字过多，请拆分文档。');
    if (text) sections.push(text);
  }
  if (!sections.length) throw new Error('电子书没有可读取的正文。');
  const metadata = book.metadata ?? {};
  return { sections, metadata: {
    title: metadataText(metadata.title), author: metadataText(metadata.author),
    publisher: metadataText(metadata.publisher), published: metadataText(metadata.published)
  } };
}
try {
  window.ebookImport.result({ ok: true, ...await run() });
} catch (error) {
  const message = error.message || '电子书解析失败。';
  const friendly = /[\u4e00-\u9fff]/u.test(message) ? message : '文件格式无效或文件损坏，无法导入。';
  window.ebookImport.result({ ok: false, error: friendly });
} finally { try { book?.destroy(); } catch {} }
