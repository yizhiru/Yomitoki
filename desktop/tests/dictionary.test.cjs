const test = require('node:test');
const assert = require('node:assert/strict');
const { fixture } = require('./fixtures/mdx.cjs');
const { ImportedDictionary } = require('../src/dictionary.cjs');

test('MDX preserves bilingual records across block boundaries and resolves aliases locally', async () => {
  const { decodeMdx } = await import('../src/ebook-import/mdx.mjs');
  const bytes = fixture();
  const entries = decodeMdx(bytes, raw => raw);
  const index = new ImportedDictionary({ name: '日汉词典' }, [JSON.stringify(Object.fromEntries(entries))]);
  const result = index.lookup('微笑んだ', { head: '微笑む', reading: 'ほほえむ', english: 'to smile' });
  assert.match(result.dictionaryText, /彼女は静かに微笑んだ。.*她静静地笑了。/);
  assert.equal(result.english, undefined);
  assert.equal(index.meaning(['ほほえむ']), result.dictionaryText);
  assert.equal(index.meaning(['雨']), '');
  assert.throws(() => decodeMdx(bytes.subarray(0, -1), raw => raw), /MDX/);
});

test('Yomitan v3 preserves bilingual example order and distinguishes readings', async () => {
  const { importYomitan } = await import('../src/ebook-import/yomitan.mjs');
  const { yomitanFixture } = require('./fixtures/yomitan.cjs');
  const bytes = await yomitanFixture();
  const { title, entries } = importYomitan(bytes);
  const index = new ImportedDictionary({ name: title }, [JSON.stringify(Object.fromEntries(entries))]);
  assert.equal(title, '测试日汉词典');
  assert.equal(index.meaning(['微笑む']), '①\n静かに笑う。\n/ 微笑。\n▲ 「彼女は静かに微笑んだ。」\n她静静地笑了。\n②\n花が少し開く。\n/ 花儿初放。\n▲ 「花が微笑んだ。」\n花开了。');
  assert.equal(index.meaning(['開く'], 'アク'), '自動詞');
  assert.equal(index.meaning(['開く'], 'ひらく'), '他動詞');
  assert.throws(() => importYomitan(bytes.subarray(0, -1)), /ZIP/);
});
