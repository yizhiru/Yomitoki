const path = require('node:path');
const cases = require('./ebooks/cases.json');
const compact = text => text.replace(/\s+/gu, '');
function expectedBlocks(test) {
  if (test.long) return Array.from({ length: 30 }, (_, index) => {
    const chapter = index + 1;
    return [`第${chapter}章`, `LONG${chapter}_START ` + '私は静かな喫茶店で本を読み、窓の外を見た。'.repeat(250) + ` LONG${chapter}_END`];
  }).flat();
  return (test.expected || '').split(/\n+/).filter(value => value.trim());
}
module.exports = { cases, compact, expectedBlocks, fixturePath: test => path.join(__dirname, 'ebooks', test.file) };
