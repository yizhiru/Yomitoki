const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { createHash } = require('node:crypto');
const { spawn } = require('node:child_process');
const { LocalEngine } = require('../src/translation.cjs');
const { parseDevices, candidates, backendArgs } = require('../src/acceleration.cjs');
const { Store } = require('../src/store.cjs');

function fixture(environment = {}, noDevice = false) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'yomitoki-gpu-test-'));
  const model = path.join(directory, 'test-model.gguf'); fs.writeFileSync(model, 'test model');
  const calls = []; let probes = 0;
  for (const folder of ['runtime', 'runtime-vulkan']) {
    const root = path.join(directory, folder); fs.mkdirSync(root);
    const bytes = Buffer.from('test engine'); fs.writeFileSync(path.join(root, 'llama-server.exe'), bytes);
    fs.writeFileSync(path.join(root, 'manifest.json'), JSON.stringify({ files: [{ path: 'llama-server.exe', sha256: createHash('sha256').update(bytes).digest('hex') }] }));
  }
  const engine = new LocalEngine(directory, { platform: 'win32', startupTimeout: 5000, validate: async () => {},
    runFile: async () => { probes++; return { stdout: noDevice ? 'Available devices:\n' : 'Available devices:\n  Vulkan0: Test GPU (4096 MiB, 4000 MiB free)\n' }; },
    spawn: (executable, args, options) => {
      calls.push({ executable, args });
      return spawn(process.execPath, [path.join(__dirname, 'fixtures/translation-engine.cjs'), ...args],
        { ...options, env: { ...process.env, ...environment, FAKE_REQUEST_LOG: path.join(directory, 'request.json') } });
    } });
  return { directory, model, engine, calls, probes: () => probes,
    async close() { await engine.stop(); fs.rmSync(directory, { recursive: true, force: true }); } };
}
test('只识别真正列出的 Vulkan 设备，CPU 与 GPU 使用不同参数', () => {
  const devices = parseDevices('Available devices:\n  Vulkan0: NVIDIA example (4096 MiB)\n  CPU: CPU\n  Vulkan1: AMD example\n  Vulkan2: llvmpipe\n  Vulkan3: Microsoft Basic Render Driver\n');
  assert.equal(devices.length, 2); assert.equal(devices[0].id, 'Vulkan0');
  assert.equal(devices[0].name, 'NVIDIA example');
  assert.deepEqual(backendArgs(candidates('cpu', { devices })[0]), ['--device', 'none', '-ngl', '0']);
  assert.deepEqual(backendArgs(candidates('gpu', { devices })[0]), ['--device', 'Vulkan0', '-ngl', '99']);
  assert.deepEqual(candidates('auto', { devices: [] }), [{ backend: 'cpu' }]);
  assert.throws(() => candidates('gpu', { devices: [], reason: '没有兼容显卡' }), /没有兼容显卡/);
  assert.throws(() => candidates('invalid', { devices }));
});
test('旧设置自动兼容，GPU 选择重启后保留', () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'yomitoki-gpu-settings-'));
  try {
    const store = new Store(directory);
    store.change(data => { delete data.settings.translationAcceleration; });
    const old = new Store(directory); assert.equal(old.data.settings.translationAcceleration, 'auto');
    old.change(data => { data.settings.translationAcceleration = 'gpu'; });
    assert.equal(new Store(directory).data.settings.translationAcceleration, 'gpu');
  } finally { fs.rmSync(directory, { recursive: true, force: true }); }
});
test('同一模型并发启动共享进程，GPU 必须确认实际卸载层数', async () => {
  const f = fixture();
  try {
    await Promise.all([f.engine.start(f.model, 'auto'), f.engine.start(f.model, 'auto')]);
    assert.equal(f.calls.length, 1); assert.equal(f.engine.status().backend, 'vulkan'); assert.equal(f.engine.status().gpuLayers, 25);
    const reply = await f.engine.translate(f.model, '私は本を読む。', new AbortController().signal, 'auto');
    assert.equal(reply, '模拟译文（GPU）');
    assert.ok(JSON.parse(fs.readFileSync(path.join(f.directory, 'request.json'))).messages[0].content.endsWith('私は本を読む。'));
  } finally { await f.close(); }
});
test('无显卡自动回退 CPU；强制 CPU 不初始化 GPU；强制 GPU 明确报错', async () => {
  const f = fixture({}, true);
  try {
    await f.engine.start(f.model, 'auto'); assert.equal(f.engine.status().backend, 'cpu');
    const probes = f.probes(); await f.engine.start(f.model, 'cpu');
    assert.equal(f.probes(), probes);
    await f.engine.start(f.model, 'cpu'); assert.equal(f.probes(), probes);
    await assert.rejects(f.engine.start(f.model, 'gpu'), /Vulkan 显卡/);
    assert.ok(f.calls.every(call => call.executable.includes('runtime' + path.sep)));
  } finally { await f.close(); }
});
for (const [name, environment] of [['显存不足或驱动初始化失败', { FAKE_GPU_FAIL: 'load' }], ['没有真正使用 GPU', { FAKE_GPU_LAYERS: '0' }]]) {
  test(name + '时自动使用独立 CPU 引擎，强制 GPU 不悄悄回退', async () => {
    const f = fixture(environment);
    try {
      await f.engine.start(f.model, 'auto'); assert.equal(f.engine.status().backend, 'cpu'); assert.match(f.engine.status().reason, /回退/);
      assert.equal(f.calls.length, 2);
      await assert.rejects(f.engine.start(f.model, 'gpu'), /GPU/);
      assert.equal(f.calls.length, 3);
    } finally { await f.close(); }
  });
}
test('GPU 推理故障只回退一次，并复用已加载的 CPU 模型', async () => {
  const f = fixture({ FAKE_GPU_FAIL: 'inference' });
  try {
    const signal = new AbortController().signal;
    assert.equal(await f.engine.translate(f.model, '原文', signal), '模拟译文（CPU）');
    assert.equal(f.engine.status().requested, 'auto'); assert.match(f.engine.status().reason, /重试/);
    assert.equal(await f.engine.translate(f.model, '另一个原文', signal), '模拟译文（CPU）');
    assert.equal(f.calls.length, 2);
  } finally { await f.close(); }
});
test('停止冷启动后不能由迟到的任务重新拉起 CPU 引擎', async () => {
  const f = fixture({ FAKE_HEALTH_WAIT: '1' });
  try {
    const started = f.engine.start(f.model, 'auto').then(() => null, error => error);
    while (!f.calls.length) await new Promise(resolve => setTimeout(resolve, 10));
    await f.engine.stop(); assert.match((await started).message, /停止/);
    assert.equal(f.calls.length, 1); assert.equal(f.engine.child, null);
  } finally { await f.close(); }
});
