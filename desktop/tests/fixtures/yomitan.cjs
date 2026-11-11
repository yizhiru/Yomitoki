async function yomitanFixture() {
  const { strToU8, zipSync } = await import('../../src/vendor/fflate/fflate.mjs');
  const node = (kind, content) => ({ tag: 'div', data: { class: kind }, content });
  const zh = content => ({ tag: 'span', lang: 'zh', content });
  const glossary = [{
    type: 'structured-content',
    content: node('mjrhsjcd-entry', [
      '①',
      node('def2', ['静かに笑う。', zh('/ 微笑。')]),
      node('exam', ['▲ 「彼女は静かに微笑んだ。」', zh('她静静地笑了。')]),
      '②',
      node('def2', ['花が少し開く。', zh('/ 花儿初放。')]),
      node('exam', ['▲ 「花が微笑んだ。」', zh('花开了。')]),
      { tag: 'script', content: 'hiddenProbe' },
    ]),
  }];
  const row = (head, reading, definitions) => [head, reading, '', '', 0, definitions, 1, ''];
  return zipSync({
    'index.json': strToU8(JSON.stringify({ format: 3, title: '测试日汉词典', revision: '1' })),
    'term_bank_0.json': strToU8(JSON.stringify([
      row('微笑む', 'ほほえむ', glossary),
      row('開く', 'あく', ['自動詞']),
      row('開く', 'ひらく', ['他動詞']),
    ])),
  });
}

module.exports = { yomitanFixture };
