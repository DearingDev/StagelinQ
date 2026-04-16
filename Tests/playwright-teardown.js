module.exports = async function globalTeardown() {
  const proc = global.__pwshProc;
  if (proc) {
    // Closing stdin causes ReadToEnd() to return, which lets pwsh exit cleanly
    proc.stdin.end();
    await new Promise(resolve => proc.on('exit', resolve));
  }
};
