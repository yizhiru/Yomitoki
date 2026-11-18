const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const { Store, exportWords } = require('../src/store.cjs');
const { Dictionary, selectionLevel } = require('../src/dictionary.cjs');
const { endpoint, completion, decodeAnalysis, decodeDefinition } = require('../src/models.cjs');
const { paginate, readBook } = require('../src/imports.cjs');
const { validateModel, MODEL } = require('../src/translation.cjs');
const scratch = () => fs.mkdtempSync(path.join(os.tmpdir(), 'yomitoki-test-'));

test('保存、重启读取、失败写入保留原状态与原文件', () => {
  const folder = scratch();
  try {
    const store = new Store(folder);
    store.change(data => { data.settings.fontSize = 30; data.settings.keyBlob = 'encrypted'; });
    assert.equal(new Store(folder).data.settings.fontSize, 30);
    assert.equal(store.publicState().settings.keyBlob, undefined);
    assert.equal(store.publicState().hasKey, true);
    const previous = fs.readFileSync(store.file);
    assert.throws(() => store.change(data => { data.version = BigInt(1); }));
    assert.deepEqual(fs.readFileSync(store.file), previous);
    assert.equal(store.data.version, 1);
    fs.writeFileSync(store.file, 'corrupt');
    assert.throws(() => new Store(folder));
    assert.equal(fs.readFileSync(store.file, 'utf8'), 'corrupt');
  } finally { fs.rmSync(folder, { recursive: true, force: true }); }
});
test('缓存隔离与重启持久化', () => {
  const folder = scratch();
  try {
    const store = new Store(folder), key = store.cacheKey('definitions', 'model-a', '微笑む', 'ほほえむ');
    store.cache(key, { chinese: '微笑' });
    assert.equal(new Store(folder).cached(key).chinese, '微笑');
    assert.notEqual(key, store.cacheKey('definitions', 'model-b', '微笑む', 'ほほえむ'));
  } finally { fs.rmSync(folder, { recursive: true, force: true }); }
});
test('CSV 转义、按例句展开及 TXT 字段选择', () => {
  const words = [{ definition: { head: '微笑む', reading: 'ほほえむ', chinese: '微笑,"示例"' },
    examples: [{ sentence: '微笑んだ。\n次の文。', filename: 'test.pdf', kind: 'PDF', page: 2 }] }];
  const csv = exportWords(words);
  assert.ok(csv.startsWith('\uFEFF')); assert.ok(csv.includes('微笑,""示例""')); assert.ok(csv.includes('第 3 页'));
  const txt = exportWords(words, 'txt', []);
  assert.equal(txt, '单词：微笑む');
});
test('接口地址规范化、认证凭据与协议校验', () => {
  assert.equal(endpoint({ provider: 'custom', url: 'http://localhost:123/v1/' }).href, 'http://localhost:123/v1/chat/completions');
  assert.equal(endpoint({ provider: 'deepseek' }).href, 'https://api.deepseek.com/chat/completions');
  for (const url of ['file:///etc/passwd', 'https://user:password@example.com', 'https://example.com/#x']) assert.throws(() => endpoint({ provider: 'custom', url }));
});
test('真实 HTTP 调用、禁用 V4 思考、错误与取消', async () => {
  const server = http.createServer((request, response) => {
    let body = ''; request.on('data', chunk => body += chunk);
    request.on('end', () => {
      assert.equal(request.headers.authorization, 'Bearer test-key');
      assert.equal(JSON.parse(body).messages[0].content, '原文');
      response.writeHead(200, { 'Content-Type': 'application/json' });
      response.end(JSON.stringify({ choices: [{ message: { content: '测试回复' }, finish_reason: 'stop' }] }));
    });
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  try {
    const settings = { provider: 'custom', url: `http://127.0.0.1:${server.address().port}/v1`, model: 'test' };
    assert.equal((await completion(settings, 'test-key', [{ role: 'user', content: '原文' }])).text, '测试回复');
    let body;
    const fetchImpl = async (_url, request) => { body = JSON.parse(request.body); return new Response(JSON.stringify({ choices: [{ message: { content: 'ok' } }] })); };
    await completion({ provider: 'custom', url: 'http://i-nhi.zhejianglab.org/maas/v1', model: 'DeepSeek-V4.1-Flash' }, 'test-key', [], { fetchImpl });
    assert.deepEqual(body.thinking, { type: 'disabled' });
    await completion(settings, 'test-key', [], { fetchImpl }); assert.equal(body.thinking, undefined);
    await assert.rejects(completion(settings, 'test-key', [], { fetchImpl: async () => new Response('', { status: 401 }) }), /认证失败/);
    const abort = new AbortController(); abort.abort();
    await assert.rejects(completion(settings, 'test-key', [], { signal: abort.signal }), /取消/);
  } finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
});
test('模型格式校验、结构嵌套图保留、截断拒绝', () => {
  const analysis = { translation: '翻译', mainStructure: '主干', diagram: '［原文］ ➔ 主语\n └─ 修饰', modifiers: ['关系'], grammarPoints: [] };
  assert.deepEqual(decodeAnalysis({ text: JSON.stringify(analysis) }), analysis);
  assert.throws(() => decodeAnalysis({ text: JSON.stringify({ ...analysis, diagram: '' }) }));
  assert.throws(() => decodeDefinition({ text: '{}', truncated: true }));
  assert.throws(() => decodeDefinition({ text: '{"head":"词"}' }));
  assert.equal(decodeDefinition({ text: '```json\n{"head":"微笑む","reading":"ほほえむ","meaning":"微笑"}\n```' }).head, '微笑む');
});
test('UTF-8 TXT 导入与段落重排', async () => {
  const folder = scratch();
  try {
    const file = path.join(folder, '日本語 文書.txt'); fs.writeFileSync(file, '私は本を読む。\n\n次の段落。');
    const book = await readBook(file); assert.equal(book.kind, 'TXT'); assert.equal(book.pages[0], '私は本を読む。\n\n次の段落。');
    const markdown = path.join(folder, '読書.md');
    fs.writeFileSync(markdown, Buffer.concat([Buffer.from([0xff, 0xfe]), Buffer.from('# 日本語\n文章。', 'utf16le')]));
    const importedMarkdown = await readBook(markdown);
    assert.equal(importedMarkdown.kind, 'MD');
    assert.equal(importedMarkdown.pages[0], '# 日本語\n文章。');
    fs.writeFileSync(file, Buffer.from([0xff, 0xff]));
    await assert.rejects(readBook(file), /编码/);
    assert.equal(paginate('あ'.repeat(1100) + '\n\n次の段落。').length, 2);
    await assert.rejects(readBook(path.join(folder, 'unsupported.exe')), /PDF/);
  } finally { fs.rmSync(folder, { recursive: true, force: true }); }
});
test('真实词典与日语形态分析：基本形、读音及三级选区', async () => {
  const dictionary = await new Dictionary().load(path.join(__dirname, '../.build/resources'));
  const value = dictionary.lookup('微笑んだ');
  assert.equal(value.head, '微笑む'); assert.ok(value.english); assert.ok(value.pos.length);
  assert.equal(dictionary.lookup('食べました').head, '食べる');
  for (const [sentence, base, kana] of [
    ['電車が来た。', '来', 'き'], ['来ない。', '来', 'こ'], ['来れば。', '来', 'く'],
    ['食べた。', '食', 'た'], ['歩いた。', '歩', 'ある'], ['読みました。', '読', 'よ'],
    ['取り出した。', '取り出', 'とりだ'],
    ['駅に行った。', '行', 'い'], ['会議を行った。', '行', 'おこな'],
    ['扉が開く。', '開', 'あ'], ['本を開く。', '開', 'ひら'],
    ['俺は客に注文を聞いた。', '俺', 'おれ'],
    ['俺は客に注文を聞いた。', '客', 'きゃく'],
    ['俺は客に注文を聞いた。', '注文', 'ちゅうもん'],
  ]) {
    const readings = dictionary.readingAnnotations(sentence, new Set(), true);
    assert.ok(readings.some(({ start, end, kana: reading }) => sentence.slice(start, end) === base && reading === kana), sentence);
  }
  for (const sentence of ['行った。', '開く。']) {
    const annotations = dictionary.readingAnnotations(sentence, new Set(), true);
    assert.equal(annotations.some(({ start, end }) => /^[行開]$/.test(sentence.slice(start, end))), false);
  }
  const compound = '日本語を勉強する。';
  assert.ok(dictionary.readingAnnotations(compound, new Set(), true)
    .some(({ start, end, kana }) => compound.slice(start, end) === '日本語' && kana === 'にほんご'));
  const rain = '雨上がり。';
  const rainReadings = dictionary.readingAnnotations(rain, new Set(), true);
  assert.ok(rainReadings.some(({ start, end, kana }) => rain.slice(start, end) === '雨' && kana === 'あめ'));
  assert.ok(rainReadings.some(({ start, end, kana }) => rain.slice(start, end) === '上' && kana === 'あ'));
  for (const surface of ['注文して', '注文した', '注文します', '注文しない']) {
    assert.equal(dictionary.lookup(surface).head, '注文');
    const sentence = `あとは${surface}くれりゃあ。`;
    const start = sentence.indexOf(surface);
    assert.equal(selectionLevel(sentence, start, start + surface.length, dictionary.tokenizer, word => dictionary.isWord(word)), 'word');
  }
  const sentence = '私は本を読む。';
  assert.equal(selectionLevel(sentence, 0, sentence.length, dictionary.tokenizer, word => dictionary.isWord(word)), 'sentence');
  const text = '私は本を読む。\n\n彼は微笑んだ。';
  assert.equal(selectionLevel(text, 0, 8, dictionary.tokenizer), 'sentence');
  assert.equal(selectionLevel(text, 0, text.length, dictionary.tokenizer), 'paragraph');
  assert.equal(selectionLevel(text, text.indexOf('微笑'), text.indexOf('微笑') + 4, dictionary.tokenizer), 'word');
  assert.equal(selectionLevel('食べました', 0, 5, dictionary.tokenizer), 'word');
  const fragment = '私は本を読む。';
  assert.equal(selectionLevel(fragment, 0, 4, dictionary.tokenizer), 'fragment');
  const emoji = '😀 微笑んだ。';
  assert.equal(dictionary.wordAt(emoji, emoji.indexOf('微笑')).start, emoji.indexOf('微笑'));
  assert.throws(() => selectionLevel(text, -1, 2, dictionary.tokenizer));
});
test('拒绝错误模型，不自动下载权重', async () => {
  const folder = scratch();
  try { const file = path.join(folder, MODEL.filename); fs.writeFileSync(file, 'wrong'); await assert.rejects(validateModel(file), /校验不符/); }
  finally { fs.rmSync(folder, { recursive: true, force: true }); }
});
