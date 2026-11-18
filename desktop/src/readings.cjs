const path = require('node:path');
const { execFile } = require('node:child_process');

let last;
function automatic(text, resources) {
  if (last?.text === text) return last.promise;
  last?.child?.kill();
  const request = {text};
  const name = process.platform === 'win32' ? 'sudachi-reader.exe' : 'sudachi-reader';
  const promise = new Promise(resolve => {
    const child = execFile(path.join(resources, 'sudachi-reader', name), [], {
      windowsHide: true, timeout: 20000, maxBuffer: 64 * 1024 * 1024,
    }, (error, stdout) => {
      try { resolve(error ? null : JSON.parse(stdout)); } catch { resolve(null); }
    });
    request.child = child;
    child.once('close', () => { request.child = null; });
    child.stdin.on('error', () => {});
    child.stdin.end(text, 'utf8');
  });
  request.promise = promise;
  last = request;
  return promise;
}

function bookMatches(text, rules, tokens) {
  const matches = [];
  if (!rules || !Object.keys(rules).length) return matches;
  const starts = new Set(), ends = new Set();
  let offset = 0;
  for (const token of tokens(text)) {
    const start = text.indexOf(token.surface_form, offset);
    if (start < 0) continue;
    offset = start + token.surface_form.length;
    starts.add(start); ends.add(offset);
  }
  for (const [surface, kana] of Object.entries(rules)) {
    if (!surface.length) continue;
    for (let i = text.indexOf(surface); i >= 0; i = text.indexOf(surface, i + surface.length)) {
      if (starts.has(i) && ends.has(i + surface.length)) matches.push({start:i, surface, kana});
    }
  }
  return matches.sort((a,b) => b.surface.length - a.surface.length);
}

async function annotations(book, dictionary, saved, showKana, resources) {
  const text = book.pages[book.page];
  if (!showKana) return saved.size ? dictionary.readingAnnotations(text, saved, false) : [];
  const auto = await automatic(text, resources);
  const fallback = !auto || saved.size ? dictionary.readingAnnotations(text, saved, !auto) : [];
  const used = new Uint8Array(text.length), marked = new Uint8Array(text.length);
  for (const r of fallback) if (r.saved) marked.fill(1, r.start, r.end);
  const result = [];
  const layers = [book.localReadings?.[book.page], bookMatches(text, book.bookReadings, t => dictionary.tokens(t)),
    book.sourceReadings?.[book.page],
    auto ?? fallback.filter(r => r.kana).map(r => ({...r, surface:text.slice(r.start,r.end)}))];
  for (const layer of layers) for (const {start, surface, kana} of layer ?? []) {
    const end = start + surface.length;
    if (!surface || !kana || start < 0 || !text.startsWith(surface,start) || used.subarray(start,end).includes(1)) continue;
    used.fill(1,start,end);
    const sub = marked.subarray(start,end);
    const saved = sub.every(Boolean);
    const highlights = [];
    if (!saved) for (let i = start; i < end;) {
      if (!marked[i]) { i++; continue; }
      const from = i++;
      while (i < end && marked[i]) i++;
      highlights.push([from,i]);
    }
    result.push({start,end,kana,saved,highlights});
  }
  for (let i = 0; i < text.length;) {
    if (!marked[i] || used[i]) { i++; continue; }
    const start = i++;
    while (i < text.length && marked[i] && !used[i]) i++;
    result.push({start,end:i,kana:'',saved:true});
  }
  return result.sort((a,b) => a.start - b.start);
}
module.exports = {annotations};
