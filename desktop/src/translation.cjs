const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');
const net = require('node:net');
const { createHash, randomBytes } = require('node:crypto');
const { spawn } = require('node:child_process');
const { completion } = require('./models.cjs');
const MODEL = { filename: 'Hy-MT2-1.8B-Q4_K_M.gguf', bytes: 1133080448,
  sha256: 'dc5f44fcf1fa496ee7ad725982c0c8c553a4de00259b53af84c4b89fb0c06699',
  urls: { hf: 'https://hf-mirror.com/tencent/Hy-MT2-1.8B-GGUF/resolve/b27182d810fa3ceb6ed04e7c324c54e35c0d209c/Hy-MT2-1.8B-Q4_K_M.gguf',
    modelscope: 'https://modelscope.cn/models/Tencent-Hunyuan/Hy-MT2-1.8B-GGUF/resolve/ef1d40b8b315575d30d1eb6579996130b8fc0bb2/Hy-MT2-1.8B-Q4_K_M.gguf' } };
async function checksum(file, signal) {
  const hash = createHash('sha256');
  for await (const chunk of fs.createReadStream(file)) { signal?.throwIfAborted(); hash.update(chunk); }
  return hash.digest('hex');
}
async function validateModel(file, signal) {
  if ((await fsp.stat(file)).size !== MODEL.bytes || await checksum(file, signal) !== MODEL.sha256) throw new Error('模型大小或 SHA-256 校验不符，请选择官方 Hy-MT2-1.8B Q4_K_M 文件。');
  return file;
}
async function downloadModel(directory, mirror, progress, signal) {
  const url = MODEL.urls[mirror];
  if (!url) throw new Error('下载源无效。');
  await fsp.mkdir(directory, { recursive: true });
  const target = path.join(directory, MODEL.filename), temporary = target + '.download';
  try {
    const response = await fetch(url, { signal });
    if (!response.ok || !response.body) throw new Error(`模型下载失败（HTTP ${response.status}）。`);
    const file = await fsp.open(temporary, 'w'); let received = 0, last = 0;
    try {
      for await (const chunk of response.body) {
        signal.throwIfAborted(); received += chunk.length;
        if (received > MODEL.bytes) throw new Error('下载文件超过预期大小。');
        await file.write(chunk);
        if (Date.now() - last > 200) { progress({ received, total: MODEL.bytes, phase: 'download' }); last = Date.now(); }
      }
    } finally { await file.close(); }
    progress({ received, total: MODEL.bytes, phase: 'verify' });
    await validateModel(temporary, signal);
    signal.throwIfAborted();
    await fsp.rename(temporary, target);
    return target;
  } finally { await fsp.rm(temporary, { force: true }); }
}
class LocalEngine {
  constructor(resources) { this.resources = resources; this.child = null; this.loaded = ''; this.starting = null; }
  async stop() {
    const child = this.child; this.child = null; this.loaded = ''; this.starting = null;
    if (child && child.exitCode === null) {
      child.kill();
      await Promise.race([new Promise(resolve => child.once('exit', resolve)), new Promise(resolve => setTimeout(resolve, 2000))]);
    }
  }
  async start(model) {
    const info = await fsp.stat(model);
    const identity = `${model}|${info.size}|${info.mtimeMs}`;
    if (this.loaded === identity && this.child?.exitCode === null) { if (this.starting) await this.starting; return; }
    await this.stop();
    if (process.platform !== 'win32') throw new Error('此客户端内置的是 Windows 翻译引擎，请在 Windows 上运行本地翻译。');
    await validateModel(model);
    const runtime = path.join(this.resources, 'runtime');
    const manifest = JSON.parse(await fsp.readFile(path.join(runtime, 'manifest.json'), 'utf8'));
    for (const item of manifest.files) {
      if (path.basename(item.path) !== item.path || await checksum(path.join(runtime, item.path)) !== item.sha256) throw new Error('内置翻译引擎校验失败，请重新安装应用。');
    }
    const port = await new Promise((resolve, reject) => {
      const socket = net.createServer(); socket.on('error', reject);
      socket.listen(0, '127.0.0.1', () => { const port = socket.address().port; socket.close(() => resolve(port)); });
    });
    this.key = randomBytes(32).toString('hex'); this.url = `http://127.0.0.1:${port}`;
    const child = spawn(path.join(runtime, 'llama-server.exe'), ['-m', model, '--host', '127.0.0.1', '--port', String(port),
      '--api-key', this.key, '--alias', 'yomitoki-translation', '--ctx-size', '8192', '--parallel', '1', '-ngl', '0'],
      { cwd: runtime, windowsHide: true, stdio: ['ignore', 'ignore', 'pipe'] });
    this.child = child; this.loaded = identity;
    let startupError = '';
    child.on('error', error => { startupError = error.message; });
    child.stderr.on('data', () => {});
    this.starting = (async () => {
      const deadline = Date.now() + 120000;
      while (Date.now() < deadline) {
        if (this.child !== child || startupError || child.exitCode !== null) throw new Error('本地翻译引擎启动失败，请检查模型或重新安装应用。');
        try {
          const response = await fetch(this.url + '/health', { redirect: 'error', signal: AbortSignal.timeout(1500), headers: { Authorization: `Bearer ${this.key}` } });
          if (response.ok) return;
        } catch {}
        await new Promise(resolve => setTimeout(resolve, 250));
      }
      throw new Error('加载本地模型超时，可释放内存后重试。');
    })();
    try { await this.starting; } catch (error) { await this.stop(); throw error; }
    finally { this.starting = null; }
  }
  async translate(model, text, signal) {
    await this.start(model); signal.throwIfAborted();
    const reply = await completion({ provider: 'custom', url: this.url, model: 'yomitoki-translation' }, this.key,
      [{ role: 'user', content: '将以下文本翻译为简体中文，注意只需要输出翻译后的结果，不要额外解释，保留段落划分：\n\n' + text }], { signal, local: true, maxTokens: 4096 });
    if (reply.truncated) throw new Error('译文输出被截断，请缩短选文后重试。');
    return reply.text;
  }
}
module.exports = { MODEL, checksum, validateModel, downloadModel, LocalEngine };
