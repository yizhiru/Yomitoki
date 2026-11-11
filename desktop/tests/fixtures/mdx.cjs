const { deflateSync } = require('node:zlib');

function number(value, bytes = 8) {
  const buffer = Buffer.alloc(bytes);
  if (bytes === 8) buffer.writeBigUInt64BE(BigInt(value));
  else buffer.writeUIntBE(value, 0, bytes);
  return buffer;
}

function block(data) {
  const compressed = deflateSync(data);
  return Buffer.concat([Buffer.from([2, 0, 0, 0]), compressed.subarray(-4), compressed]);
}

function fixture() {
  const entries = [
    ['ほほえむ', '@@@LINK=微笑む'],
    ['微笑む', '<div>微笑</div><div>彼女は静かに微笑んだ。</div><div>她静静地笑了。</div><script>hiddenProbe()</script>'],
  ];
  const encode = value => Buffer.from(value, 'utf16le');
  let offset = 0;
  const keys = [], records = [];
  for (const [key, text] of entries) {
    keys.push(number(offset), encode(key + '\0'));
    const record = encode(text + '\0');
    records.push(record);
    offset += record.length;
  }
  const keyData = Buffer.concat(keys), keyBlock = block(keyData);
  const first = entries[0][0], last = entries.at(-1)[0];
  const keyIndex = Buffer.concat([number(entries.length), number(first.length, 2), encode(first + '\0'),
    number(last.length, 2), encode(last + '\0'), number(keyBlock.length), number(keyData.length)]);
  const keyIndexBlock = block(keyIndex);
  const header = encode('<Dictionary GeneratedByEngineVersion="2.0" Encoding="UTF-16" Encrypted="0" Format="Html"/>\0');
  const raw = Buffer.concat(records);
  // Split a UTF-16 code unit and its record across two compressed blocks.
  const parts = [raw.subarray(0, records[0].length + 3), raw.subarray(records[0].length + 3)];
  const recordBlocks = parts.map(block);
  return Buffer.concat([
    number(header.length, 4), header, Buffer.alloc(4),
    number(1), number(entries.length), number(keyIndex.length), number(keyIndexBlock.length),
    number(keyBlock.length), Buffer.alloc(4), keyIndexBlock, keyBlock,
    number(parts.length), number(entries.length), number(16 * parts.length),
    number(recordBlocks.reduce((sum, value) => sum + value.length, 0)),
    ...parts.flatMap((part, index) => [number(recordBlocks[index].length), number(part.length)]),
    ...recordBlocks,
  ]);
}

module.exports = { fixture };
