const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');
const net = require('node:net');
const { createHash, randomBytes } = require('node:crypto');
const { spawn, execFile } = require('node:child_process');
const { promisify } = require('node:util');
const { completion } = require('./models.cjs');
const { MODES, parseDevices, candidates, backendArgs } = require('./acceleration.cjs');
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
  constructor(resources, options = {}) {
    this.resources = resources; this.child = null; this.loaded = ''; this.starting = null; this.epoch = 0;
    this.platform = options.platform || process.platform;
    this.runFile = options.runFile || promisify(execFile);
    this.spawn = options.spawn || spawn;
    this.validate = options.validate || validateModel;
    this.startupTimeout = options.startupTimeout || 120000;
    this.execution = { backend: null, requested: 'auto', device: '', gpuLayers: 0, reason: '' };
  }
  status() { return structuredClone(this.execution); }
  runtime(backend) { return path.join(this.resources, backend === 'vulkan' ? 'runtime-vulkan' : 'runtime'); }
  async verifyRuntime(backend) {
    const runtime = this.runtime(backend);
    const manifest = JSON.parse(await fsp.readFile(path.join(runtime, 'manifest.json'), 'utf8'));
    if (!Array.isArray(manifest.files) || !manifest.files.some(item => item.path === 'llama-server.exe')) throw new Error('内置翻译引擎清单无效，请重新安装。');
    for (const item of manifest.files) {
      if (path.basename(item.path) !== item.path || await checksum(path.join(runtime, item.path)) !== item.sha256) throw new Error('内置翻译引擎校验失败，请重新安装应用。');
    }
    return runtime;
  }
  async detect(force = false) {
    if (this.platform !== 'win32') return { devices: [], reason: 'GPU 检测需在 Windows 上运行。' };
    if (!force && this.detection && Date.now() - this.detectedAt < 30000) return structuredClone(this.detection);
    try {
      const runtime = await this.verifyRuntime('vulkan');
      const output = await this.runFile(path.join(runtime, 'llama-server.exe'), ['--list-devices'],
        { cwd: runtime, windowsHide: true, timeout: 15000, maxBuffer: 2_000_000 });
      const devices = parseDevices(output.stdout);
      this.detection = { devices, reason: devices.length ? '' : '未检测到兼容的 Vulkan 显卡，可更新显卡驱动或使用 CPU。' };
    } catch {
      this.detection = { devices: [], reason: '无法初始化 GPU 引擎，可检查显卡驱动或使用 CPU。' };
    }
    this.detectedAt = Date.now();
    return structuredClone(this.detection);
  }
  async stopChild() {
    const child = this.child; this.child = null;
    if (child && child.exitCode === null) {
      child.kill();
      await Promise.race([new Promise(resolve => child.once('exit', resolve)), new Promise(resolve => setTimeout(resolve, 2000))]);
    }
  }
  async stop() {
    this.epoch++; this.loaded = ''; this.starting = null;
    this.execution = { backend: null, requested: 'auto', device: '', gpuLayers: 0, reason: '' };
    await this.stopChild();
  }
  async start(model, mode = 'auto') {
    if (!MODES.includes(mode)) throw new Error('翻译加速模式无效。');
    const info = await fsp.stat(model);
    const identity = `${model}|${info.size}|${info.mtimeMs}|${mode}`;
    if (this.loaded === identity && (this.starting || this.child?.exitCode === null)) { if (this.starting) await this.starting; return; }
    const epoch = ++this.epoch;
    this.loaded = identity;
    this.execution = { backend: null, requested: mode, device: '', gpuLayers: 0, reason: '' };
    const startup = (async () => {
      await this.stopChild();
      if (epoch !== this.epoch) throw new Error('已停止加载模型。');
      if (this.platform !== 'win32') throw new Error('此客户端内置的是 Windows 翻译引擎，请在 Windows 上运行本地翻译。');
      await this.startSelected(model, mode, epoch);
    })();
    this.starting = startup;
    try { await startup; }
    catch (error) { if (this.epoch === epoch) await this.stop(); throw error; }
    finally { if (this.starting === startup) this.starting = null; }
  }
  async startSelected(model, mode, epoch) {
    await this.validate(model);
    const detection = mode === 'cpu' ? { devices: [], reason: '' } : await this.detect();
    let reason = mode === 'auto' ? detection.reason : '';
    for (const candidate of candidates(mode, detection)) {
      if (epoch !== this.epoch) throw new Error('已停止加载模型。');
      try {
        const gpuLayers = await this.launch(model, candidate, epoch);
        if (epoch !== this.epoch) throw new Error('已停止加载模型。');
        this.execution = { backend: candidate.backend, requested: mode, device: candidate.device?.name || '', gpuLayers, reason };
        return;
      } catch (error) {
        if (epoch !== this.epoch) throw new Error('已停止加载模型。');
        await this.stopChild();
        if (candidate.backend !== 'vulkan' || mode !== 'auto') throw error;
        reason = 'GPU 加载未成功，已回退 CPU。可检查显存和显卡驱动。';
      }
    }
  }
  async launch(model, candidate, epoch) {
    const runtime = await this.verifyRuntime(candidate.backend);
    if (epoch !== this.epoch) throw new Error('已停止加载模型。');
    const port = await new Promise((resolve, reject) => {
      const socket = net.createServer(); socket.on('error', reject);
      socket.listen(0, '127.0.0.1', () => { const port = socket.address().port; socket.close(() => resolve(port)); });
    });
    if (epoch !== this.epoch) throw new Error('已停止加载模型。');
    this.key = randomBytes(32).toString('hex'); this.url = `http://127.0.0.1:${port}`;
    const child = this.spawn(path.join(runtime, 'llama-server.exe'), ['-m', model, '--host', '127.0.0.1', '--port', String(port),
      '--api-key', this.key, '--alias', 'yomitoki-translation', '--ctx-size', '8192', '--parallel', '1', ...backendArgs(candidate)],
      { cwd: runtime, windowsHide: true, stdio: ['ignore', 'ignore', 'pipe'] });
    this.child = child;
    let startupError = '', gpuLayers = 0, diagnostics = '';
    child.on('error', error => { startupError = error.message; });
    child.stderr.on('data', chunk => {
      diagnostics = (diagnostics + chunk.toString()).slice(-16000);
      for (const match of diagnostics.matchAll(/offloaded\s+(\d+)\/\d+\s+layers to GPU/g)) gpuLayers = Math.max(gpuLayers, Number(match[1]));
    });
    const deadline = Date.now() + this.startupTimeout;
    while (Date.now() < deadline) {
      if (epoch !== this.epoch || this.child !== child) throw new Error('已停止加载模型。');
      if (startupError || child.exitCode !== null) throw new Error(candidate.backend === 'vulkan' ? 'GPU 模型加载失败，可检查显存或改用 CPU。' : '本地翻译引擎启动失败，请检查模型或重新安装应用。');
      let healthy = false;
      try {
        const response = await fetch(this.url + '/health', { redirect: 'error', signal: AbortSignal.timeout(1500), headers: { Authorization: `Bearer ${this.key}` } });
        healthy = response.ok;
      } catch {}
      if (healthy) {
        if (candidate.backend === 'vulkan' && gpuLayers === 0) throw new Error('模型未能使用 GPU，请检查显存、驱动或改用 CPU。');
        return gpuLayers;
      }
      await new Promise(resolve => setTimeout(resolve, 100));
    }
    throw new Error('加载本地模型超时，可释放内存后重试。');
  }
  async translate(model, text, signal, mode = 'auto') {
    await this.start(model, mode); signal.throwIfAborted();
    const reply = () => completion({ provider: 'custom', url: this.url, model: 'yomitoki-translation' }, this.key,
      [{ role: 'user', content: '将以下文本翻译为简体中文，注意只需要输出翻译后的结果，不要额外解释，保留段落划分：\n\n' + text }], { signal, local: true, maxTokens: 4096 });
    let result;
    try { result = await reply(); }
    catch (error) {
      signal.throwIfAborted();
      if (mode !== 'auto' || this.execution.backend !== 'vulkan') throw error;
      const identity = this.loaded;
      await this.start(model, 'cpu'); signal.throwIfAborted();
      this.loaded = identity;
      this.execution.requested = 'auto'; this.execution.reason = 'GPU 翻译失败，已使用 CPU 重试。';
      result = await reply();
    }
    if (result.truncated) throw new Error('译文输出被截断，请缩短选文后重试。');
    return result.text;
  }
}
module.exports = { MODEL, checksum, validateModel, downloadModel, LocalEngine };
