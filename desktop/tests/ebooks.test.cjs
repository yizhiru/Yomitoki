const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { createHash } = require('node:crypto');
const { pathToFileURL } = require('node:url');
const { readBook } = require('../src/imports.cjs');
const { cases, fixturePath } = require('./fixtures/ebooks.cjs');
test('bundled parsers, licenses and fixtures match pinned checksums', () => {
  const root = path.join(__dirname, '../src/vendor'), manifest = require('../src/vendor/manifest.json');
  for (const [file, sha] of Object.entries(manifest.files)) assert.equal(createHash('sha256').update(fs.readFileSync(path.join(root, file))).digest('hex'), sha, file);
  for (const value of cases) assert.equal(createHash('sha256').update(fs.readFileSync(fixturePath(value))).digest('hex'), value.sha256, value.id);
});
test('EPUB archive limits and malformed MOBI headers', async () => {
  const { inspectZip, inspectMobi, LIMITS } = await import(pathToFileURL(path.join(__dirname, '../src/ebook-import/zip.mjs')).href);
  const epub = fs.readFileSync(fixturePath(cases.find(value => value.id === 'epub3-japanese-ruby')));
  assert.ok(inspectZip(epub).count > 0);
  assert.throws(() => inspectZip(epub, { ...LIMITS, entries: 1 }), /数量/);
  assert.throws(() => inspectZip(epub, { ...LIMITS, entry: 1 }), /解压/);
  assert.throws(() => inspectZip(epub.subarray(0, 100)), /损坏/);
  for (const id of ['corrupt-mobi', 'drm-flag-mobi']) assert.throws(() => inspectMobi(fs.readFileSync(fixturePath(cases.find(value => value.id === id)))));
});
test('native ebook import preserves the existing book contract and respects cancellation', async () => {
  const file = fixturePath(cases.find(value => value.id === 'epub3-japanese-ruby')); let calls = 0;
  const value = await readBook(file, { extractEbook: async chosen => {
    calls++;
    assert.equal(chosen, file);
    return { sections: ['第一章\n\n喫茶店へ行く。', '第二章\n\n本を読む。'], metadata: { title: ' 喫茶店 ', author: '作者' } };
  } });
  assert.equal(value.metadata.title, '喫茶店');
  assert.equal(value.metadata.author, '作者');
  assert.equal(value.kind, 'EPUB'); assert.ok(value.id); assert.equal(value.page, 0); assert.ok(value.pages.join('\n').includes('第二章'));
  const controller = new AbortController(); controller.abort();
  await assert.rejects(readBook(file, { signal: controller.signal, extractEbook: async () => { calls++; } }));
  assert.equal(calls, 1);
  await assert.rejects(readBook(file, { extractEbook: async () => { throw new Error('损坏文件'); } }), /损坏文件/);
});
