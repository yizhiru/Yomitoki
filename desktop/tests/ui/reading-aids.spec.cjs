const { test, expect, _electron: electron } = require('@playwright/test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { defaults } = require('../../src/store.cjs');

test('imports SRT and preserves original selection offsets with reading aids enabled', async ({}, testInfo) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'yomitoki-reading-aids-'));
  const library = defaults();
  library.words.push({ id: '駅\nえき', definition: { head: '駅', reading: 'えき' }, examples: [] });
  fs.writeFileSync(path.join(directory, 'library.json'), JSON.stringify(library));
  const subtitle = path.join(directory, '雨上がりの長い字幕ファイルを使った表示確認.srt');
  const line = '駅まで歩いた。';
  fs.writeFileSync(subtitle, `1\r\n00:00:01,000 --> 00:00:03,000\r\n<i>${line.repeat(25)}</i>\r\n\r\n2\r\n00:00:04,000 --> 00:00:05,000\r\nまた明日。\r\n`);
  let app;
  try {
    app = await electron.launch({
      ...(process.env.YOMITOKI_EXECUTABLE ? { executablePath: process.env.YOMITOKI_EXECUTABLE, args: [] } : { args: [path.join(__dirname, '../..')] }),
      env: { ...process.env, YOMITOKI_DATA_DIRECTORY: directory },
    });
    const page = await app.firstWindow();
    await app.evaluate(({ dialog }, file) => {
      dialog.showOpenDialog = async () => ({ canceled: false, filePaths: [file] });
    }, subtitle);
    await page.locator('#import').click();
    const reader = page.locator('#reader');
    await expect(reader).toContainText('また明日');
    await expect(reader).not.toContainText('00:00');
    await expect(reader.locator('.saved-word').first()).toContainText('駅');
    await page.locator('#settings-button').click();
    await expect(page.locator('#reading-kana')).toBeChecked();
    await expect(reader.locator('ruby.saved-word rt').first()).toHaveText('えき');
    await page.getByRole('button', { name: '关闭设置' }).click();
    for (const [width, height] of [[1220, 800], [900, 600]]) {
      await app.evaluate(({ BrowserWindow }, size) => BrowserWindow.getAllWindows()[0].setSize(...size), [width, height]);
      await reader.locator('ruby.saved-word').first().evaluate(ruby => {
        const range = document.createRange();
        range.selectNodeContents(ruby);
        getSelection().removeAllRanges();
        getSelection().addRange(range);
        const data = new DataTransfer();
        document.dispatchEvent(new ClipboardEvent('copy', { clipboardData: data, cancelable: true }));
        if (data.getData('text/plain') !== '駅') throw new Error('Copy included reading annotations');
        document.dispatchEvent(new Event('selectionchange'));
      });
      await page.getByRole('button', { name: '词典释义', exact: true }).click();
      await expect(page.locator('#detail-body h2')).toHaveText('駅');
      expect(await reader.evaluate(node => node.scrollWidth <= node.clientWidth)).toBe(true);
      await page.screenshot({ path: testInfo.outputPath(`reading-aids-${width}.png`) });
    }
    await page.locator('#settings-button').click();
    await page.locator('#highlight-saved').uncheck();
    await expect(reader.locator('.saved-word')).toHaveCount(0);
    await expect(reader.locator('ruby').first()).toBeVisible();
    await page.locator('#reading-kana').uncheck();
    await expect(reader.locator('ruby')).toHaveCount(0);
  } finally {
    if (app) await app.close();
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
