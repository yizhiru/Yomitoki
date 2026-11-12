const { test, expect, _electron: electron } = require('@playwright/test');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { cases, compact, expectedBlocks, fixturePath } = require('../fixtures/ebooks.cjs');
test('built-in EPUB/MOBI import, limits, cancellation and persisted reading work without calibre', async ({}, testInfo) => {
  test.setTimeout(180000);
  const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'yomitoki-epub-日本語 '));
  const project = path.join(__dirname, '../..');
  const launch = () => electron.launch({ ...(process.env.YOMITOKI_EXECUTABLE ? { executablePath: process.env.YOMITOKI_EXECUTABLE } : {}),
    args: process.env.YOMITOKI_EXECUTABLE ? [] : [project], env: { ...process.env, YOMITOKI_DATA_DIRECTORY: folder } });
  let app = await launch();
  try {
    expect(await app.evaluate(({ app }) => app.getVersion())).toBe(require('../../package.json').version);
    const page = await app.firstWindow(); await expect(page.locator('#reader')).not.toBeEmpty();
    const results = [];
    for (const value of cases) {
      const before = await page.evaluate(async () => (await window.yomitoki.call('state')).books.length);
      await app.evaluate(({ dialog }, file) => { dialog.showOpenDialog = async () => ({ canceled: false, filePaths: [file] }); }, fixturePath(value));
      await page.locator('#import').click(); await expect(page.locator('#import')).toBeEnabled({ timeout: 40000 });
      const state = JSON.parse(fs.readFileSync(path.join(folder, 'library.json')));
      if (value.reject) { expect(state.books.length, value.id).toBe(before); await expect(page.locator('#status')).toBeVisible(); }
      else {
        expect(state.books.length, value.id).toBe(before + 1);
        const book = state.books.find(book => book.id === state.current); expect(book.kind).toBe(value.kind);
        if (book.name === '日本語の本 空白.epub') {
          expect(book.metadata.title).toBe('epub3-japanese-ruby');
          await expect(page.locator('#books .active')).toHaveText('epub3-japanese-ruby');
        }
        const text = compact(book.pages.join('\n\n')); let cursor = -1;
        for (const part of expectedBlocks(value)) { const at = text.indexOf(compact(part), cursor + 1); expect(at, value.id + ': missing/out-of-order expected text').toBeGreaterThan(cursor); cursor = at; }
        for (const marker of ['HIDDEN_ATTR_PROBE', 'HIDDEN_INLINE_PROBE', 'HIDDEN_CSS_PROBE', 'SCRIPT_PROBE', 'STYLE_PROBE']) expect(text).not.toContain(marker);
        if (!['mobi6-japanese', 'mobi6-uncompressed'].includes(value.id)) expect(text).not.toContain('きっさてん');
      }
      expect(await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows().length)).toBe(1);
      results.push({ id: value.id, rejectedAsExpected: value.reject, ok: true });
    }
    const ruby = cases.find(value => value.id === 'epub3-japanese-ruby');
    const beforeCancel = JSON.parse(fs.readFileSync(path.join(folder, 'library.json'))).books.length;
    await app.evaluate(({ dialog }, file) => {
      dialog.showOpenDialog = () => new Promise(resolve => setTimeout(() => resolve({ canceled: false, filePaths: [file] }), 350));
    }, fixturePath(ruby));
    await page.locator('#import').click(); await page.locator('#cancel-import').click();
    await expect(page.locator('#import')).toBeEnabled(); await expect(page.locator('#status')).toContainText('已取消导入');
    expect(JSON.parse(fs.readFileSync(path.join(folder, 'library.json'))).books.length).toBe(beforeCancel);
    await app.evaluate(({ dialog }, file) => { dialog.showOpenDialog = async () => ({ canceled: false, filePaths: [file] }); }, fixturePath(ruby));
    await page.locator('#import').click(); await expect(page.locator('#reader')).toContainText('喫茶店'); await expect(page.locator('#import')).toBeEnabled();
    await page.locator('#reader').evaluate(node => {
      const target = document.createTreeWalker(node, NodeFilter.SHOW_TEXT).nextNode(), start = target.textContent.indexOf('喫茶店');
      const range = document.createRange(); range.setStart(target, start); range.setEnd(target, start + 3); const selection = getSelection(); selection.removeAllRanges(); selection.addRange(range);
      document.dispatchEvent(new Event('selectionchange'));
    });
    await expect(page.getByRole('button', { name: '词典释义', exact: true })).toBeVisible();
    await page.getByRole('button', { name: '词典释义', exact: true }).click(); await expect(page.locator('#detail-body h2')).toHaveText('喫茶店');
    await page.getByRole('button', { name: '保存到生词本' }).click();
    const cancellation = await app.evaluate(async ({ app, BrowserWindow }, file) => {
      const load = process.getBuiltinModule('module').createRequire(app.getAppPath() + '/package.json');
      const { readEbook } = load('./src/ebook-import.cjs');
      const controller = new AbortController(); const pending = readEbook(file, { signal: controller.signal, parent: BrowserWindow.getAllWindows()[0] }); controller.abort();
      try { await pending; return ''; } catch (error) { return error.message; }
    }, fixturePath(ruby));
    expect(cancellation).toContain('取消');
    const timeout = await app.evaluate(async ({ app, BrowserWindow }, file) => {
      const load = process.getBuiltinModule('module').createRequire(app.getAppPath() + '/package.json');
      const { readEbook } = load('./src/ebook-import.cjs');
      try { await readEbook(file, { parent: BrowserWindow.getAllWindows()[0], timeoutMs: 1 }); return ''; } catch (error) { return error.message; }
    }, fixturePath(ruby));
    expect(timeout).toContain('超时'); expect(await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows().length)).toBe(1);
    await page.screenshot({ path: testInfo.outputPath('native-epub-reading.png') });
    await fs.promises.writeFile(testInfo.outputPath('ebook-cases.json'), JSON.stringify({ packaged: Boolean(process.env.YOMITOKI_EXECUTABLE), platform: process.platform, results }, null, 2));
    expect(JSON.parse(fs.readFileSync(path.join(folder, 'library.json'))).words.some(word => word.definition.head === '喫茶店')).toBe(true);
    await app.close(); app = null; app = await launch();
    const restored = await app.firstWindow();
    await expect(restored.locator('#reader')).toContainText('喫茶店');
    await restored.locator('#notebook-tab').click(); await expect(restored.locator('#words')).toContainText('喫茶店');
  } finally { if (app) await app.close(); fs.rmSync(folder, { recursive: true, force: true }); }
});
