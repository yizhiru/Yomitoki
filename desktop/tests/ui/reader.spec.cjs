const { test, expect, _electron: electron } = require('@playwright/test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');

test('阅读、三级选文、模型功能、生词导出、设置持久化与真实文档导入', async ({}, testInfo) => {
  test.setTimeout(180000);
  const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'yomitoki-ui-'));
  const requests = [];
  const server = http.createServer((request, response) => {
    let raw = ''; request.on('data', chunk => raw += chunk);
    request.on('end', () => {
      const body = JSON.parse(raw); requests.push(body);
      let content;
      if (body.max_tokens === 1024) content = JSON.stringify({ head: '微笑む', reading: 'ほほえむ', meaning: '微笑', note: '动词过去式', etymology: '' });
      else if (body.max_tokens === 6144) content = JSON.stringify({ translation: '雨停了，我走进一家小咖啡店。', mainStructure: '私は ➔ 入った', modifiers: ['雨が上がったので ➔ 入った：原因'], grammarPoints: ['ので：原因'], diagram: '［雨が上がったので］ ➔ 入った\n        └─ 原因状语', notes: '' });
      else content = '这里的「ので」表示前后事件之间的原因关系。';
      const send = () => { if (!response.destroyed) { response.writeHead(200, { 'Content-Type': 'application/json' }); response.end(JSON.stringify({ choices: [{ message: { content }, finish_reason: 'stop' }] })); } };
      if (body.messages.at(-1).content === '慢回复') setTimeout(send, 1800); else send();
    });
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  let app;
  async function launch(expected = '雨が上がった') {
    app = await electron.launch({ ...(process.env.YOMITOKI_EXECUTABLE ? { executablePath: process.env.YOMITOKI_EXECUTABLE, args: [] } : { args: [path.join(__dirname, '../..')] }),
      env: { ...process.env, YOMITOKI_DATA_DIRECTORY: folder }, timeout: 45000 });
    const page = await app.firstWindow();
    page.on('pageerror', error => { throw error; });
    await expect(page.locator('#reader')).toContainText(expected, { timeout: 30000 });
    return page;
  }
  async function select(page, text) {
    await page.locator('#reader').evaluate((reader, text) => {
      const start = reader.textContent.indexOf(text); if (start < 0) throw new Error('找不到测试选文');
      const range = document.createRange(); range.setStart(reader.firstChild, start); range.setEnd(reader.firstChild, start + text.length);
      window.getSelection().removeAllRanges(); window.getSelection().addRange(range);
      document.dispatchEvent(new Event('selectionchange'));
    }, text);
    await expect(page.locator('#selection-toolbar')).toBeVisible();
  }
  try {
    let page = await launch();
    await expect(page.locator('#book-title')).toContainText('示例');
    await app.evaluate(({ BrowserWindow }) => {
      const preferences = BrowserWindow.getAllWindows()[0].webContents.getLastWebPreferences();
      if (!preferences.contextIsolation || preferences.nodeIntegration || !preferences.sandbox) throw new Error('渲染进程未正确隔离');
    });
    if (process.platform === 'win32') await app.evaluate(({ safeStorage }) => {
      if (!safeStorage.isEncryptionAvailable()) throw new Error('Windows 凭据加密不可用');
      if (safeStorage.decryptString(safeStorage.encryptString('round-trip')) !== 'round-trip') throw new Error('Windows 加密失败');
    });
    await select(page, '微笑んだ');
    await expect(page.getByRole('button', { name: '词典释义', exact: true })).toBeVisible();
    await expect(page.locator('#selection-toolbar').getByText('本地翻译')).toHaveCount(0);
    await page.getByRole('button', { name: '词典释义', exact: true }).click();
    await expect(page.locator('#detail-body h2')).toHaveText('微笑む');
    await expect(page.locator('#detail-body')).toContainText('英文释义');
    await page.getByRole('button', { name: '保存到生词本' }).click();
    await page.locator('#notebook-tab').click(); await expect(page.locator('#words')).toContainText('微笑む');
    await app.evaluate(({ dialog }, file) => { dialog.showSaveDialog = async () => ({ canceled: false, filePath: file }); }, path.join(folder, 'words.csv'));
    await page.locator('#export-button').click(); await page.locator('#export-confirm').click();
    await expect.poll(() => fs.existsSync(path.join(folder, 'words.csv'))).toBe(true);
    expect(fs.readFileSync(path.join(folder, 'words.csv'), 'utf8')).toContain('微笑む');
    await page.locator('#reading-tab').click();
    await page.locator('#detail-split').focus(); await page.keyboard.press('ArrowLeft');
    await expect.poll(() => JSON.parse(fs.readFileSync(path.join(folder, 'library.json'))).settings.detailWidth).toBe(390);
    await page.locator('#settings-button').click();
    await expect(page.locator('#single-click')).not.toBeChecked();
    await expect(page.locator('#translation-acceleration')).toHaveValue('auto');
    await page.locator('#translation-acceleration').selectOption('gpu');
    await expect.poll(() => JSON.parse(fs.readFileSync(path.join(folder, 'library.json'))).settings.translationAcceleration).toBe('gpu');
    await page.locator('#translation-acceleration').selectOption('cpu');
    await page.locator('#detect-gpu').click();
    await expect(page.locator('#gpu-detection')).not.toHaveText('正在检测显卡…', { timeout: 25000 });
    await expect(page.locator('#gpu-detection')).not.toBeEmpty();
    await expect(page.locator('#translation-runtime')).toHaveText('尚未加载翻译模型。');
    await page.locator('#font-size').evaluate(input => { input.value = 28; input.dispatchEvent(new Event('input')); input.dispatchEvent(new Event('change')); });
    await page.locator('#definition-size').evaluate(input => { input.value = 22; input.dispatchEvent(new Event('input')); input.dispatchEvent(new Event('change')); });
    // Avoid a macOS keychain consent dialog in automated source-client tests.
    if (process.platform !== 'win32') await app.evaluate(({ safeStorage }) => {
      safeStorage.isEncryptionAvailable = () => true;
      safeStorage.encryptString = value => Buffer.from(value);
      safeStorage.decryptString = value => value.toString();
    });
    await page.locator('#provider').selectOption('custom');
    await page.locator('#api-url').fill(`http://127.0.0.1:${server.address().port}/v1`);
    await page.locator('#model-name').fill('test-model'); await page.locator('#api-key').fill('test-only-key');
    await page.locator('#save-model').click(); await expect(page.locator('#key-status')).toContainText('加密保存');
    await page.getByRole('button', { name: '关闭设置' }).click();
    await select(page, '微笑んだ'); await page.getByRole('button', { name: '大模型释义', exact: true }).click();
    await expect(page.locator('#detail-body')).toContainText('动词过去式');
    const count = requests.length;
    await select(page, '微笑んだ'); await page.getByRole('button', { name: '大模型释义', exact: true }).click();
    await expect(page.locator('#detail-body')).toContainText('已从本地缓存读取'); expect(requests.length).toBe(count);
    const sentence = '雨が上がったので、傘を閉じて小さな喫茶店に入った。';
    await select(page, sentence);
    await expect(page.locator('#selection-toolbar').getByText('本地翻译')).toBeVisible();
    await expect(page.locator('#selection-toolbar').getByText('词典释义', { exact: true })).toHaveCount(0);
    await page.getByRole('button', { name: '长句分析', exact: true }).click();
    await expect(page.locator('.diagram')).toContainText('原因状语');
    await select(page, sentence); await page.getByRole('button', { name: '大模型对话', exact: true }).click();
    await page.locator('#chat-question').fill('「ので」是什么意思？'); await page.getByRole('button', { name: '发送', exact: true }).click();
    await expect(page.locator('.chat-message').last()).toContainText('原因关系');
    await page.locator('#chat-question').fill('慢回复'); await page.getByRole('button', { name: '发送', exact: true }).click();
    await page.getByRole('button', { name: '停止', exact: true }).click();
    await expect(page.locator('.chat-message')).toHaveCount(2);
    const paragraph = await page.locator('#reader').textContent();
    await select(page, paragraph);
    await expect(page.locator('#selection-toolbar').getByText('本地翻译')).toBeVisible();
    await expect(page.locator('#selection-toolbar').getByText('长句分析')).toHaveCount(0);
    await page.locator('#reading-tab').click();
    await page.screenshot({ path: testInfo.outputPath('windows-reader.png') });
    const txt = path.join(folder, '日本語 文書.txt'); fs.writeFileSync(txt, '日本語の本を読む。\n\n次の段落。');
    await app.evaluate(({ dialog }, file) => { dialog.showOpenDialog = async () => ({ canceled: false, filePaths: [file] }); }, txt);
    await page.locator('#import').click(); await expect(page.locator('#reader')).toContainText('日本語の本を読む。');
    // Minimal real PDF, including xref offsets, exercises PDF.js and its packaged dependencies.
    const parts = ['%PDF-1.4\n']; const offsets = [0];
    const objects = ['<< /Type /Catalog /Pages 2 0 R >>', '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
      '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'];
    const stream = 'BT /F1 14 Tf 20 200 Td (Yomitoki PDF reading) Tj ET';
    objects.push(`<< /Length ${stream.length} >>\nstream\n${stream}\nendstream`);
    for (let index = 0; index < objects.length; index++) { offsets.push(Buffer.byteLength(parts.join(''))); parts.push(`${index + 1} 0 obj\n${objects[index]}\nendobj\n`); }
    const xref = Buffer.byteLength(parts.join(''));
    parts.push(`xref\n0 6\n0000000000 65535 f \n${offsets.slice(1).map(offset => String(offset).padStart(10, '0') + ' 00000 n \n').join('')}trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF`);
    const pdf = path.join(folder, 'reading.pdf'); fs.writeFileSync(pdf, parts.join(''));
    await app.evaluate(({ dialog }, file) => { dialog.showOpenDialog = async () => ({ canceled: false, filePaths: [file] }); }, pdf);
    await page.locator('#import').click(); await expect(page.locator('#reader')).toContainText('Yomitoki PDF reading');
    await app.close(); app = null;
    page = await launch('Yomitoki PDF reading');
    await expect(page.locator('#reader')).toContainText('Yomitoki PDF reading');
    const persisted = JSON.parse(fs.readFileSync(path.join(folder, 'library.json')));
    expect(persisted.settings.fontSize).toBe(28); expect(persisted.settings.definitionSize).toBe(22); expect(persisted.settings.detailWidth).toBe(390);
    expect(persisted.settings.translationAcceleration).toBe('cpu');
    expect(persisted.words).toHaveLength(1); expect(persisted.chats[0].messages).toHaveLength(2);
    expect(JSON.stringify(persisted)).not.toContain('"apiKey"');
  } finally {
    if (app) await app.close(); server.closeAllConnections(); await new Promise(resolve => server.close(resolve));
    fs.rmSync(folder, { recursive: true, force: true });
  }
});
