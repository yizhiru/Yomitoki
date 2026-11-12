const { test, expect, _electron: electron } = require('@playwright/test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { defaults } = require('../../src/store.cjs');

test('笔记按书管理，保留选文并返回原文', async () => {
  const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'yomitoki-notes-'));
  const library = defaults();
  delete library.notes;
  library.books[0].pages.push('二ページ目の文章。');
  library.books.push({ id: 'second-book', name: '另一本书', kind: 'EPUB', pages: ['別の本。'], page: 0 });
  fs.writeFileSync(path.join(folder, 'library.json'), JSON.stringify(library));
  const executablePath = process.env.YOMITOKI_EXECUTABLE;
  const launch = () => electron.launch({
    ...(executablePath ? { executablePath, args: [] } : { args: [path.join(__dirname, '../..')] }),
    env: { ...process.env, YOMITOKI_DATA_DIRECTORY: folder }
  });
  let app;
  try {
    app = await launch();
    const page = await app.firstWindow();
    await expect(page.locator('#reader')).toContainText('雨が上がった');
    await page.locator('#next').click();
    await expect(page.locator('#reader')).toHaveText('二ページ目の文章。');
    await page.locator('#reader').evaluate(node => {
      const range = document.createRange();
      range.selectNodeContents(node);
      window.getSelection().removeAllRanges();
      window.getSelection().addRange(range);
    });
    const toolbar = page.locator('#selection-toolbar');
    await expect(toolbar).toBeVisible();
    await expect(toolbar.getByRole('button', { name: '写笔记' })).toHaveCount(0);
    await page.locator('#reading-more').click();
    await page.locator('#write-note').click();
    await expect(page.locator('#note-excerpt')).toHaveText('二ページ目の文章。');
    await page.locator('#save-note').click();
    await page.locator('#notes-tab').click();
    await expect(page.locator('#note-list')).toContainText('二ページ目の文章。');
    await expect(page.locator('#note-list .note-body')).toHaveCount(0);
    await page.locator('#notes-books').getByRole('button', { name: '另一本书 · 0' }).click();
    await expect(page.locator('#note-list')).toHaveText('这本书还没有笔记。');
    await page.locator('#new-note').click();
    await page.locator('#note-body').fill('另一条读书笔记');
    await page.locator('#save-note').click();
    await expect(page.locator('#note-list')).toContainText('另一条读书笔记');
    const search = page.locator('#notes-search');
    await search.fill('二ページ目');
    await expect(page.locator('#note-list')).toContainText('二ページ目の文章。');
    await expect(page.locator('#note-list .note-card')).toHaveCount(1);
    await search.fill('读书笔记');
    await expect(page.locator('#note-list')).toContainText('另一本书');
    await expect(page.locator('#note-list')).toContainText('另一条读书笔记');
    await search.fill('不存在的笔记');
    await expect(page.locator('#note-list')).toHaveText('没有匹配的笔记。');
    await page.locator('#notes-books').getByRole('button', { name: /雨上がりの喫茶店/ }).click();
    await page.locator('#note-list').getByRole('button', { name: '编辑' }).click();
    await page.locator('#note-body').fill('修改后的笔记');
    await page.locator('#save-note').click();
    await expect(page.locator('#note-list')).toContainText('修改后的笔记');

    await app.close();
    app = null;
    app = await launch();
    const restored = await app.firstWindow();
    await expect(restored.locator('#reader')).toHaveText('二ページ目の文章。');
    await restored.locator('#previous').click();
    await expect(restored.locator('#reader')).toContainText('雨が上がった');
    await restored.locator('#notes-tab').click();
    await expect(restored.locator('#note-list')).toContainText('修改后的笔记');
    const shelf = restored.locator('#books');
    for (const title of ['另一本书', /雨上がりの喫茶店/]) {
      await shelf.getByRole('button', { name: title }).click({ button: 'right' });
      restored.once('dialog', dialog => dialog.accept());
      await restored.locator('#book-context-remove').click();
      await expect(shelf.getByRole('button', { name: title })).toHaveCount(0);
    }
    await restored.locator('#reading-tab').click();
    await expect(restored.locator('#reading-empty')).toBeVisible();
    await restored.locator('#notes-tab').click();
    await expect(restored.locator('#note-list')).toContainText('修改后的笔记');
    await restored.getByRole('button', { name: '第 2 节', exact: true }).click();
    await expect(restored.locator('#reader')).toHaveText('二ページ目の文章。');
    await expect(shelf.getByRole('button')).toHaveCount(0);
    await restored.locator('#notes-tab').click();
    restored.once('dialog', dialog => dialog.accept());
    await restored.locator('#note-list').getByRole('button', { name: '删除' }).click();
    await expect(restored.locator('#note-list')).toHaveText('这本书还没有笔记。');
  } finally {
    if (app) await app.close();
    fs.rmSync(folder, { recursive: true, force: true });
  }
});
