const fs = require('node:fs');
const { Dictionary } = require('../../desktop/src/dictionary.cjs');
async function main() {
  const dict = await new Dictionary().load(process.argv[2]);
  const lines = JSON.parse(fs.readFileSync(0, 'utf8'));
  const result = lines.map(line => dict.readingAnnotations(line, new Set(), true)
    .map(({start, end, kana}) => [start, end, kana]));
  process.stdout.write(JSON.stringify(result));
}
main().catch(error => { console.error(error); process.exitCode = 1; });
