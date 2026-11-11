const { test, expect, _electron: electron } = require('@playwright/test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { fixture } = require('../fixtures/mdx.cjs');
const { yomitanFixture } = require('../fixtures/yomitan.cjs');

const formats = [
  { extension: 'mdx', bytes: fixture, name: '测试日汉词典', example: '彼女は静かに微笑んだ。 她静静地笑了。', translation: '她静静地笑了。' },
  { extension: 'zip', bytes: yomitanFixture, name: '测试日汉词典', japanese: '「彼女は静かに微笑んだ。」', translation: '她静静地笑了。' },
];
if (process.env.YOMITOKI_MEIKYO_ZIP) {
  formats.push({
    extension: 'zip', bytes: () => fs.readFileSync(process.env.YOMITOKI_MEIKYO_ZIP),
    name: '明鏡日汉双解辞典', japanese: '「にこやかに～」', translation: '微微一笑',
  });
}

async function lookup(page, word) {
  await page.locator('#reader').evaluate((reader, word) => {
    const start = reader.textContent.indexOf(word);
    const range = document.createRange();
    range.setStart(reader.firstChild, start);
    range.setEnd(reader.firstChild, start + word.length);
    getSelection().removeAllRanges();
    getSelection().addRange(range);
    document.dispatchEvent(new Event('selectionchange'));
  }, word);
  await page.getByRole('button', { name: '词典释义', exact: true }).click();
}

for (const format of formats) test(`settings import, switch and remember ${format.name} (${format.extension})`, async () => {
  test.setTimeout(90000);
  const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'yomitoki-dictionary-'));
  const file = path.join(folder, format.extension === 'zip' ? 'dictionary.zip' : '测试日汉词典.mdx');
  fs.writeFileSync(file, await format.bytes());
  const launch = () => electron.launch({
    ...(process.env.YOMITOKI_EXECUTABLE ? { executablePath: process.env.YOMITOKI_EXECUTABLE, args: [] }
      : { args: [path.join(__dirname, '../..')] }),
    env: { ...process.env, YOMITOKI_DATA_DIRECTORY: folder },
  });
  let app;
  try {
    app = await launch();
    let page = await app.firstWindow();
    await expect(page.locator('#reader')).toContainText('微笑んだ');
    await app.evaluate(({ dialog }, file) => {
      dialog.showOpenDialog = async () => ({ canceled: false, filePaths: [file] });
    }, file);
    await page.locator('#settings-button').click();
    await page.locator('#import-dictionary').click();
    const source = page.locator('#dictionary-source');
    await expect(source.locator('option:checked')).toHaveText(format.name);
    await page.getByRole('button', { name: '关闭设置' }).click();
    await lookup(page, '微笑んだ');
    const detail = page.locator('#detail-body');
    await expect(detail.locator('.definition-heading h2')).toHaveText('微笑む');
    await expect(detail.locator('.definition-heading').getByRole('button', { name: 'moji 词典', exact: true })).toBeVisible();
    if (format.japanese) {
      const senses = detail.locator('.dictionary-sense');
      await expect(senses).toHaveCount(2);
      await expect(senses.locator('h4')).toHaveText(['义项 ①', '义项 ②']);
      await expect(senses.first().locator('.dictionary-language > span')).toHaveText(['日', '中']);
      const leftEdges = await senses.first().locator('.dictionary-language p').evaluateAll(
        paragraphs => paragraphs.map(paragraph => paragraph.getBoundingClientRect().left),
      );
      expect(leftEdges).toHaveLength(2);
      expect(leftEdges[0]).toBe(leftEdges[1]);
      await expect(senses.first().locator('.dictionary-language-zh p')).not.toHaveText(/^\//);
      await expect(senses.nth(1).locator('.dictionary-language-zh p')).toContainText('花儿初放');
      const pair = senses.first().locator('.dictionary-examples li').filter({ hasText: format.japanese });
      await expect(pair.locator('p').nth(0)).toHaveText(format.japanese);
      await expect(pair.locator('p').nth(0)).toHaveAttribute('lang', 'ja');
      await expect(pair.locator('p').nth(1)).toHaveText(format.translation);
      await expect(pair.locator('p').nth(1)).toHaveAttribute('lang', 'zh');
    } else {
      await expect(detail).toContainText(format.example);
    }
    await expect(detail).not.toContainText('hiddenProbe');
    await page.locator('#settings-button').click();
    await source.selectOption('');
    await expect(detail).toContainText('英文释义');
    await source.selectOption({ label: format.name });
    await expect(detail).toContainText(format.translation);
    await app.close();
    app = null;
    fs.unlinkSync(file);

    app = await launch();
    page = await app.firstWindow();
    await page.locator('#settings-button').click();
    await expect(page.locator('#dictionary-source option:checked')).toHaveText(format.name);
    const persisted = await page.evaluate(async () => {
      const state = await window.yomitoki.call('state');
      const book = state.books.find(item => item.id === state.current);
      const start = book.pages[book.page].indexOf('微笑んだ');
      return window.yomitoki.call('dictionary', {
        selection: { bookID: book.id, page: book.page, start, end: start + '微笑んだ'.length },
      });
    });
    expect(persisted.definition.dictionaryText).toContain(format.translation);
    if (format.name === '明鏡日汉双解辞典') {
      const bookFile = path.join(folder, 'sample.txt');
      fs.writeFileSync(bookFile, 'その子は安らかに眠った。');
      await app.evaluate(({ dialog }, file) => {
        dialog.showOpenDialog = async () => ({ canceled: false, filePaths: [file] });
      }, bookFile);
      await page.getByRole('button', { name: '关闭设置' }).click();
      await page.locator('#import').click();
      await expect(page.locator('#reader')).toContainText('安らか');
      await lookup(page, '安らか');
      const senses = page.locator('.dictionary-sense');
      await expect(senses.locator('h4')).toHaveText(['义项 ①', '义项 ②']);
      await expect(senses.first().locator('.dictionary-language-ja p')).toHaveText('何事もなく平穏無事であるさま。');
      await expect(senses.first().locator('.dictionary-language-zh p')).toHaveText('一切都平安无事。');
      await expect(senses.first().locator('.example-chinese')).toHaveText('安稳的日子');
      await expect(senses.nth(1).locator('.example-chinese')).toHaveText(['安详地睡觉', '安详的睡容']);
    }
  } finally {
    if (app) await app.close();
    fs.rmSync(folder, { recursive: true, force: true });
  }
});
