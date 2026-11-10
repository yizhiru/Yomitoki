// Safari 17.0 (macOS 14.0) predates Object.groupBy / Map.groupBy (Safari 17.4).
// Keep the pinned Foliate sources intact and fill only the methods it needs.
(() => {
  if (!Object.groupBy) Object.defineProperty(Object, 'groupBy', {
    configurable: true, writable: true,
    value(items, callback) {
      if (typeof callback !== 'function') throw new TypeError('callback must be a function');
      const groups = Object.create(null); let index = 0;
      for (const item of items) {
        const key = callback(item, index++);
        (groups[key] ??= []).push(item);
      }
      return groups;
    }
  });
  if (!Map.groupBy) Object.defineProperty(Map, 'groupBy', {
    configurable: true, writable: true,
    value(items, callback) {
      if (typeof callback !== 'function') throw new TypeError('callback must be a function');
      const groups = new Map(); let index = 0;
      for (const item of items) {
        const key = callback(item, index++);
        if (!groups.has(key)) groups.set(key, []);
        groups.get(key).push(item);
      }
      return groups;
    }
  });
})();
