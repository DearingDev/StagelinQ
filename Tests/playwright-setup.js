// Global setup: start a DemoMode session on PORT 38080 and wait for the API.
const { spawn } = require('child_process');
const http      = require('http');
const path      = require('path');

const PORT    = 38080;
const TIMEOUT = 20_000; // ms to wait for API to become healthy

function waitForApi(ms) {
  const deadline = Date.now() + ms;
  return new Promise((resolve, reject) => {
    function attempt() {
      http.get(`http://localhost:${PORT}/health`, res => {
        if (res.statusCode === 200) return resolve();
        if (Date.now() > deadline) return reject(new Error('API did not become healthy in time'));
        setTimeout(attempt, 300);
      }).on('error', () => {
        if (Date.now() > deadline) return reject(new Error('API did not become healthy in time'));
        setTimeout(attempt, 300);
      });
    }
    attempt();
  });
}

module.exports = async function globalSetup() {
  const modulePsd1 = path.resolve(__dirname, '..', 'StagelinQ.psd1');
  const cmd = [
    `Import-Module '${modulePsd1}' -Force;`,
    `$s = Start-StagelinQSession -DemoMode -Port ${PORT} -Quiet;`,
    // Keep the process alive until stdin closes (Playwright teardown closes it)
    `$null = [Console]::In.ReadToEnd()`,
  ].join(' ');

  const proc = spawn('pwsh', ['-NoProfile', '-Command', cmd], {
    stdio: ['pipe', 'pipe', 'pipe'],
  });

  proc.stderr.on('data', d => process.stderr.write(`[pwsh] ${d}`));

  // Store proc reference for teardown
  process.env._PLAYWRIGHT_PWSH_PID = String(proc.pid);

  // Stash the stdin handle so teardown can close it cleanly
  global.__pwshProc = proc;

  await waitForApi(TIMEOUT);
};
