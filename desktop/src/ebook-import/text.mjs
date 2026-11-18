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

// Count only non-whitespace UTF-16 units until pagination has normalized the text.
function rubyGroups(ruby, targets) {
  if (ruby.querySelector('ruby')) return;
  const visibleParts = node => [...node.childNodes].filter(n => (n.nodeType === 1 || n.nodeType === 3)
    && n.localName !== 'rp' && n.textContent.trim());
  const children = visibleParts(ruby);
  const group = children.find(n => n.localName === 'rbc');
  const layer = children.find(n => n.localName === 'rtc');
  const nodes = group || layer
    ? [...(group ? visibleParts(group) : children.filter(n => !['rtc','rt'].includes(n.localName))),
       ...(layer ? visibleParts(layer) : children.filter(n => n.localName === 'rt'))]
    : children;
  const bases = nodes.filter(n => n.localName === 'rb'), readings = nodes.filter(n => n.localName === 'rt');
  const register = (parts, rt) => {
    if (!parts.length) return;
    const first = parts[0];
    const leaf = first.nodeType === 3 ? first : first.ownerDocument.createTreeWalker(first, 4).nextNode();
    const surface = parts.map(n => n.textContent).join('').trim(), kana = rt.textContent.trim();
    if (leaf && surface && surface.length <= 256 && kana && kana.length <= 256)
      targets.set(leaf, {surface, kana});
  };
  if (bases.length && nodes.length === bases.length + readings.length) {
    const widths = readings.map(rt => Number(rt.getAttribute('rbspan') ?? (readings.length === 1 ? bases.length : 1)));
    if (widths.every(n => Number.isInteger(n) && n > 0) && widths.reduce((s,n) => s+n,0) === bases.length) {
      let i = 0;
      readings.forEach((rt,j) => { register(bases.slice(i,i+widths[j]),rt); i += widths[j]; });
    }
  } else {
    let parts = [];
    for (const n of nodes) {
      if (n.localName === 'rt') { register(parts, n); parts = []; }
      else parts.push(n);
    }
  }
}

export function plainText(doc, stylesheets = [], anchors) {
  const targets = new WeakMap();
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
    if (node.nodeType === 3) {
      if (anchors) {
        const note = targets.get(node);
        if (note) anchors.notes.push({...note, at: anchors.offset});
        anchors.offset += node.nodeValue.replace(/\s/g, '').length;
      }
      output.push(node.nodeValue); continue;
    }
    const name = node.localName?.toLowerCase();
    if (['head', 'script', 'style', 'rt', 'rp', 'rtc', 'title', 'noscript'].includes(name) || hidden.has(node)) continue;
    if (node.nodeType === 1 && (node.hasAttribute('hidden') || node.getAttribute('aria-hidden') === 'true'
      || /(?:^|;)\s*(?:display\s*:\s*none|visibility\s*:\s*hidden)/i.test(node.getAttribute('style') || ''))) continue;
    if (anchors && name === 'ruby') rubyGroups(node, targets);
    if (name === 'br' || name === 'pagebreak') { output.push('\n\n'); continue; }
    if (blocks.has(name)) { output.push('\n\n'); stack.push({ node, end: true }); }
    for (let index = node.childNodes.length - 1; index >= 0; index--) stack.push({ node: node.childNodes[index] });
  }
  return output.join('').replace(/\r/g, '').replace(/[\t \u00a0]+/g, ' ').replace(/ *\n */g, '\n').replace(/\n{3,}/g, '\n\n').trim();
}
