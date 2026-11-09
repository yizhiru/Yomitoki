module.exports = { testDir: './tests/ui', timeout: 60000, workers: 1, retries: 0,
  use: { trace: 'retain-on-failure' }, reporter: [['list']] };
