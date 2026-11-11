const { test, expect, _electron: electron } = require('@playwright/test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { defaults } = require('../../src/store.cjs');

test('EPUB adapts to the viewport and turns pages without vertical scrolling', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'yomitoki-pagination-'));
  const library = defaults();
  Object.assign(library.books[0], {
    kind: 'EPUB',
    pages: [Array.from({ length: 36 }, (_, index) => `第${index + 1}段。雨が上がったので、傘を閉じて駅まで歩いた。`).join('\n\n'), '次の節。']
  });
  fs.writeFileSync(path.join(directory, 'library.json'), JSON.stringify(library));
  const executablePath = process.env.YOMITOKI_EXECUTABLE;
  let app;
  try {
    app = await electron.launch({
      ...(executablePath ? { executablePath, args: [] } : { args: [path.join(__dirname, '../..')] }),
      env: { ...process.env, YOMITOKI_DATA_DIRECTORY: directory }
    });
    const page = await app.firstWindow();
    await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].setSize(1020, 620));
    const location = page.locator('#book-location');
    await expect(location).toHaveText(/第 1 \/ 2 节 · 页 1 \/ (?:[2-9]|[1-9]\d+)$/);
    const pageCount = async () => Number((await location.textContent()).split(' / ').at(-1));
    const small = await pageCount();
    await page.locator('#next').click();
    await expect(location).toHaveText(new RegExp(`第 1 / 2 节 · 页 2 / ${small}$`));
    const viewport = page.locator('#reading-scroll');
    const scrolled = await viewport.evaluate(node => ({ left: node.scrollLeft, width: node.clientWidth, top: node.scrollTop }));
    expect(scrolled.left).toBe(scrolled.width);
    expect(scrolled.top).toBe(0);

    const excerpt = await page.locator('#reader').evaluate(reader => {
      const bounds = reader.parentElement.getBoundingClientRect();
      const range = document.createRange();
      const text = reader.firstChild;
      for (const match of text.data.matchAll(/第\d+段。/g)) {
        range.setStart(text, match.index);
        range.setEnd(text, match.index + match[0].length);
        const rect = range.getBoundingClientRect();
        if (rect.left < bounds.left || rect.right > bounds.right || rect.bottom > bounds.bottom) continue;
        window.getSelection().removeAllRanges();
        window.getSelection().addRange(range);
        return match[0];
      }
      return null;
    });
    expect(excerpt).toBeTruthy();
    await page.locator('#write-note').click();
    await expect(page.locator('#note-excerpt')).toHaveText(excerpt);
    await page.locator('#cancel-note').click();

    await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].setSize(1350, 900));
    await expect.poll(pageCount).toBeLessThan(small);
    await expect(location).toContainText('第 1 / 2 节');
    for (let i = 0; i <= small && !(await location.textContent()).includes('第 2 / 2 节'); i++) {
      await page.locator('#next').click();
    }
    await expect(location).toHaveText(/第 2 \/ 2 节 · 页 1 \/ 1/);
    await page.locator('#previous').click();
    const large = await pageCount();
    await expect(location).toHaveText(new RegExp(`第 1 / 2 节 · 页 ${large} / ${large}$`));

    await page.locator('#open-reading-search').click();
    const query = page.locator('#reading-query');
    const status = page.locator('#reading-search-status');
    await query.fill('雨が上がった');
    await query.press('Enter');
    await expect(status).toHaveText('1 / 36');
    await page.locator('#next-match').click();
    await expect(status).toHaveText('2 / 36');
    await page.locator('#previous-match').click();
    await expect(status).toHaveText('1 / 36');
    await query.fill('第36段');
    await query.press('Enter');
    await expect(status).toHaveText('1 / 1');
    await expect(location).toHaveText(/第 1 \/ 2 节 · 页 ([2-9]|[1-9]\d*) \/ \d+$/);
    expect(await page.evaluate(() => [...CSS.highlights.get('reading-match')][0].toString())).toBe('第36段');
    await query.fill('次の節。');
    await query.press('Enter');
    await expect(status).toHaveText('1 / 1');
    await expect(location).toContainText('第 2 / 2 节');
    await query.fill('見つからない文字列');
    await query.press('Enter');
    await expect(status).toHaveText('没有匹配');
  } finally {
    if (app) await app.close();
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test('restores each book’s text position after switching books and restarting', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'yomitoki-progress-'));
  const library = defaults();
  const body = Array.from({ length: 60 }, (_, index) => `第${index + 1}段。雨が上がったので、傘を閉じて駅まで歩いた。`).join('\n\n');
  Object.assign(library.books[0], { name: '分段阅读', kind: 'EPUB', pages: [body] });
  library.books.push({ id: 'scrolling-book', name: '滚动阅读', kind: 'TXT', pages: [body], page: 0 });
  const libraryFile = path.join(directory, 'library.json');
  fs.writeFileSync(libraryFile, JSON.stringify(library));
  const launch = () => electron.launch({
    ...(process.env.YOMITOKI_EXECUTABLE ? { executablePath: process.env.YOMITOKI_EXECUTABLE, args: [] }
      : { args: [path.join(__dirname, '../..')] }),
    env: { ...process.env, YOMITOKI_DATA_DIRECTORY: directory },
  });
  let app;
  try {
    app = await launch();
    let page = await app.firstWindow();
    await expect(page.locator('#book-location')).toContainText('页 1 /');
    await page.locator('#next').click();
    await expect(page.locator('#book-location')).toContainText('页 2 /');
    await page.getByRole('button', { name: '滚动阅读', exact: true }).click();
    await expect(page.locator('#book-title')).toHaveText('滚动阅读');
    await page.locator('#reading-scroll').evaluate(view => { view.scrollTop = 1100; });
    await page.getByRole('button', { name: '分段阅读', exact: true }).click();
    await expect(page.locator('#book-location')).toContainText('页 2 /');
    await page.getByRole('button', { name: '滚动阅读', exact: true }).click();
    await expect.poll(() => page.locator('#reading-scroll').evaluate(view => view.scrollTop)).toBeGreaterThan(1000);
    await page.locator('#reading-scroll').evaluate(view => { view.scrollTop = 1700; });
    await app.close();
    app = null;

    const saved = JSON.parse(fs.readFileSync(libraryFile, 'utf8'));
    expect(saved.books.every(book => book.readingOffset > 0)).toBe(true);
    app = await launch();
    page = await app.firstWindow();
    await expect(page.locator('#book-title')).toHaveText('滚动阅读');
    await expect.poll(() => page.locator('#reading-scroll').evaluate(view => view.scrollTop)).toBeGreaterThan(1600);
    await page.getByRole('button', { name: '分段阅读', exact: true }).click();
    await expect(page.locator('#book-location')).toContainText('页 2 /');
  } finally {
    if (app) await app.close();
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
