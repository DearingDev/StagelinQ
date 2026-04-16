// @ts-check
const { defineConfig } = require('@playwright/test');

const PORT = 38080;

module.exports = defineConfig({
  testDir: './Tests',
  testMatch: '**/*.spec.js',
  timeout: 30_000,
  use: {
    baseURL: `http://localhost:${PORT}`,
    headless: true,
  },
  globalSetup:    './Tests/playwright-setup.js',
  globalTeardown: './Tests/playwright-teardown.js',
  projects: [
    { name: 'chromium', use: { browserName: 'chromium' } },
  ],
});
