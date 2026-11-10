export const LIMITS = Object.freeze({ file: 300_000_000, unpacked: 128_000_000, entry: 32_000_000, entries: 10_000, text: 10_000_000 });

// Check the directory before any decompression, including sizes and ZIP64 sentinels.
export function inspectZip(bytes, limits = LIMITS) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let end = -1;
  for (let at = bytes.length - 22; at >= Math.max(0, bytes.length - 65557); at--) {
    if (view.getUint32(at, true) === 0x06054b50 && at + 22 + view.getUint16(at + 20, true) === bytes.length) { end = at; break; }
  }
  if (end < 0) throw new Error('EPUB 文件损坏，找不到完整 ZIP 目录。');
  const count = view.getUint16(end + 10, true), size = view.getUint32(end + 12, true), offset = view.getUint32(end + 16, true);
  if (view.getUint16(end + 4, true) || view.getUint16(end + 6, true) || count === 0xffff || offset === 0xffffffff || size === 0xffffffff) throw new Error('暂不支持分卷或 ZIP64 EPUB，请转换为普通 EPUB。');
  if (count > limits.entries || offset + size > end) throw new Error('EPUB 目录无效或文件数量过多。');
  let position = offset, total = 0;
  for (let index = 0; index < count; index++) {
    if (position + 46 > offset + size || view.getUint32(position, true) !== 0x02014b50) throw new Error('EPUB ZIP 目录损坏。');
    if (view.getUint16(position + 8, true) & 1) throw new Error('不支持密码保护或加密的 EPUB。');
    const compressed = view.getUint32(position + 20, true), unpacked = view.getUint32(position + 24, true);
    const local = view.getUint32(position + 42, true);
    const length = 46 + view.getUint16(position + 28, true) + view.getUint16(position + 30, true) + view.getUint16(position + 32, true);
    if (local + 30 > offset || position + length > offset + size || compressed === 0xffffffff || unpacked === 0xffffffff) throw new Error('EPUB ZIP 条目无效。');
    if (unpacked > limits.entry || (total += unpacked) > limits.unpacked) throw new Error('EPUB 解压内容过大，请拆分书籍后导入。');
    position += length;
  }
  if (position !== offset + size) throw new Error('EPUB ZIP 目录长度无效。');
  return { count, total };
}

export function inspectMobi(bytes) {
  if (bytes.length < 100) throw new Error('MOBI 文件不完整。');
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const count = view.getUint16(76), first = view.getUint32(78);
  if (!count || 78 + count * 8 > bytes.length || first + 40 > bytes.length || first < 78 + count * 8) throw new Error('MOBI 记录目录损坏。');
  let previous = first;
  for (let index = 0; index < count; index++) {
    const offset = view.getUint32(78 + index * 8);
    if (offset < previous || offset >= bytes.length) throw new Error('MOBI 记录位置无效。');
    previous = offset;
  }
  if (view.getUint16(first + 12)) throw new Error('此 MOBI 受 DRM 或加密保护，暂不支持导入。');
}
