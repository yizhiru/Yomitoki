const http = require('node:http');
const fs = require('node:fs');
const args = process.argv.slice(2);
const value = flag => args[args.indexOf(flag) + 1];
const gpu = value('--device').startsWith('Vulkan');
if (gpu && process.env.FAKE_GPU_FAIL === 'load') process.exit(1);
if (gpu) process.stderr.write(`load_tensors: offloaded ${process.env.FAKE_GPU_LAYERS || '25'}/25 layers to GPU\n`);
const server = http.createServer((request, response) => {
  if (request.headers.authorization !== `Bearer ${value('--api-key')}`) { response.writeHead(401).end(); return; }
  if (request.url === '/health') { response.writeHead(process.env.FAKE_HEALTH_WAIT ? 503 : 200).end('{}'); return; }
  let raw = '';
  request.on('data', chunk => raw += chunk);
  request.on('end', () => {
    if (gpu && process.env.FAKE_GPU_FAIL === 'inference') { response.writeHead(503).end(); return; }
    if (process.env.FAKE_REQUEST_LOG) fs.writeFileSync(process.env.FAKE_REQUEST_LOG, raw);
    response.writeHead(200, { 'Content-Type': 'application/json' });
    response.end(JSON.stringify({ choices: [{ message: { content: `模拟译文（${gpu ? 'GPU' : 'CPU'}）` }, finish_reason: 'stop' }] }));
  });
});
server.listen(Number(value('--port')), '127.0.0.1');
process.on('SIGTERM', () => server.close(() => process.exit(0)));
