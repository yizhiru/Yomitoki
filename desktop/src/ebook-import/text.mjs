const blocks = new Set(['p', 'div', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'li', 'section', 'article', 'blockquote', 'pre', 'tr', 'dt', 'dd']);
export function decodeText(data) {
  let encoding;
  if ((data[0] === 255 && data[1] === 254) || (data[0] === 60 && data[1] === 0)) encoding = 'utf-16le';
  else if ((data[0] === 254 && data[1] === 255) || (data[0] === 0 && data[1] === 60)) encoding = 'utf-16be';
  else {
    const head = new TextDecoder().decode(data.slice(0, 1024));
    encoding = head.match(/encoding\s*=\s*["']([^"']+)/i)?.[1] || head.match(/charset\s*=\s*["']?([^\s"';>]+)/i)?.[1] || 'utf-8';
  }
  try { return new TextDecoder(encoding, { fatal: true }).decode(data); }
  catch { throw new Error('EPUB 正文编码无法识别或文字不完整，请检查文件。'); }
}

export function plainText(doc, stylesheets = []) {
  const hidden = new WeakSet();
  for (const css of [...stylesheets, ...Array.from(doc.querySelectorAll('style'), node => node.textContent)]) {
    try {
      const sheet = new CSSStyleSheet(); sheet.replaceSync(css);
      const collect = rules => {
        for (const rule of rules) {
          if (rule.selectorText && (rule.style?.display === 'none' || rule.style?.visibility === 'hidden')) {
            try { for (const node of doc.querySelectorAll(rule.selectorText)) hidden.add(node); } catch {}
          } else if (rule.cssRules && (!rule.conditionText || matchMedia(rule.conditionText).matches)) collect(rule.cssRules);
        }
      };
      collect(sheet.cssRules);
    } catch {}
  }
  // Iterative traversal avoids a stack overflow on deeply nested document markup.
  const output = [], stack = [{ node: doc }];
  while (stack.length) {
    const { node, end } = stack.pop();
    if (end) { output.push('\n\n'); continue; }
    if (node.nodeType === 3) { output.push(node.nodeValue); continue; }
    const name = node.localName?.toLowerCase();
    if (['head', 'script', 'style', 'rt', 'rp', 'title', 'noscript'].includes(name) || hidden.has(node)) continue;
    if (node.nodeType === 1 && (node.hasAttribute('hidden') || node.getAttribute('aria-hidden') === 'true'
      || /(?:^|;)\s*(?:display\s*:\s*none|visibility\s*:\s*hidden)/i.test(node.getAttribute('style') || ''))) continue;
    if (name === 'br' || name === 'pagebreak') { output.push('\n\n'); continue; }
    if (blocks.has(name)) { output.push('\n\n'); stack.push({ node, end: true }); }
    for (let index = node.childNodes.length - 1; index >= 0; index--) stack.push({ node: node.childNodes[index] });
  }
  return output.join('').replace(/\r/g, '').replace(/[\t \u00a0]+/g, ' ').replace(/ *\n */g, '\n').replace(/\n{3,}/g, '\n\n').trim();
}
