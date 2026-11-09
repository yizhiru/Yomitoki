const MODES = ['auto', 'gpu', 'cpu'];
function parseDevices(stdout) {
  const devices = [];
  for (const line of stdout.split(/\r?\n/)) {
    const match = line.match(/^\s*(Vulkan\d+):\s*(.+)$/);
    if (match) devices.push({ id: match[1], name: match[2].trim() });
  }
  return devices;
}
function candidates(mode, detection) {
  if (!MODES.includes(mode)) throw new Error('翻译加速模式无效。');
  if (mode === 'cpu') return [{ backend: 'cpu' }];
  const device = detection.devices[0];
  if (!device && mode === 'gpu') throw new Error(detection.reason || '未检测到兼容的 Vulkan 显卡，请检查驱动或选择 CPU。');
  const gpu = device ? [{ backend: 'vulkan', device }] : [];
  return mode === 'gpu' ? gpu : [...gpu, { backend: 'cpu' }];
}
function backendArgs(candidate) {
  return candidate.backend === 'vulkan' ? ['--device', candidate.device.id, '-ngl', '99'] : ['--device', 'none', '-ngl', '0'];
}
module.exports = { MODES, parseDevices, candidates, backendArgs };
