// @ts-check
const { test, expect } = require('@playwright/test');

const PORT    = 38080;
const API     = `http://localhost:${PORT}`;
const POLL_MS = 300; // dashboard polls every 250 ms; give it a little extra

// Helper: mutate state by calling the module scope via a pwsh one-liner.
// In a real CI run you would POST to a /state-override test endpoint; here we
// use the REST API to read current state and verify mutations seeded directly
// into the shared ConcurrentDictionary from within tests that have access to
// the module (DemoMode.Tests.ps1 covers that path).  These browser tests
// instead mutate state by PATCHing the live API's /state values if that
// endpoint exists, or by using the /debug response to know what keys exist.
//
// Since StagelinQ does not expose a write endpoint, we rely on the fact that
// the DemoMode session seeds known initial values, then verify the dashboard
// renders them correctly.  For state-change assertions we use the seeded
// crossfader and loop states from DemoMode which differ per deck.

test.describe('Dashboard initial render', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto(`${API}/dashboard`);
    // Wait for the dashboard to complete at least one successful poll
    await page.waitForSelector('#healthDot.ok', { timeout: 5000 });
  });

  test('status indicator shows CONNECTED', async ({ page }) => {
    const text = await page.locator('#healthText').innerText();
    expect(text).toBe('CONNECTED');
  });

  test('Deck 1 song name is populated', async ({ page }) => {
    const song = await page.locator('#d1-song').innerText();
    expect(song).not.toBe('—');
    expect(song.trim().length).toBeGreaterThan(0);
  });

  test('Deck 2 song name is populated', async ({ page }) => {
    const song = await page.locator('#d2-song').innerText();
    expect(song).not.toBe('—');
    expect(song.trim().length).toBeGreaterThan(0);
  });

  test('Deck 1 BPM shows a number', async ({ page }) => {
    const bpm = await page.locator('#d1-bpm').innerText();
    expect(bpm).not.toBe('—');
    expect(parseFloat(bpm)).toBeGreaterThan(0);
  });

  test('Deck 2 BPM shows a number', async ({ page }) => {
    const bpm = await page.locator('#d2-bpm').innerText();
    expect(bpm).not.toBe('—');
    expect(parseFloat(bpm)).toBeGreaterThan(0);
  });
});

test.describe('Play indicator', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto(`${API}/dashboard`);
    await page.waitForSelector('#healthDot.ok', { timeout: 5000 });
  });

  test('Deck 1 badge shows PLAYING (DemoMode seeds PlayState=true)', async ({ page }) => {
    // DemoMode seeds both decks as playing
    const badge = page.locator('#d1-play');
    await expect(badge).toHaveText('PLAYING');
    await expect(badge).toHaveClass(/playing/);
  });

  test('Deck 2 badge shows PLAYING (DemoMode seeds PlayState=true)', async ({ page }) => {
    const badge = page.locator('#d2-play');
    await expect(badge).toHaveText('PLAYING');
    await expect(badge).toHaveClass(/playing/);
  });
});

test.describe('Loop indicator', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto(`${API}/dashboard`);
    await page.waitForSelector('#healthDot.ok', { timeout: 5000 });
  });

  test('Deck 1 loop badge has loop-off class (DemoMode seeds Loop/Active=false)', async ({ page }) => {
    // DemoMode: Deck1 Loop/Active = false, Deck2 = true
    const badge = page.locator('#d1-loop');
    await expect(badge).toHaveClass(/loop-off/);
  });

  test('Deck 2 loop badge has loop-on class (DemoMode seeds Loop/Active=true)', async ({ page }) => {
    const badge = page.locator('#d2-loop');
    await expect(badge).toHaveClass(/loop-on/);
  });
});

test.describe('Crossfader', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto(`${API}/dashboard`);
    await page.waitForSelector('#healthDot.ok', { timeout: 5000 });
  });

  test('crossfader thumb is NOT at centre (DemoMode seeds position -0.2)', async ({ page }) => {
    // centre = 50%. With -0.2 the thumb should be at 40%.
    const left = await page.locator('#xfaderThumb').evaluate(
      el => parseFloat(el.style.left)
    );
    // -0.2 maps to ((-0.2+1)/2)*100 = 40%
    expect(left).toBeCloseTo(40, 0);
  });
});

test.describe('Beat bar animation', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto(`${API}/dashboard`);
    await page.waitForSelector('#healthDot.ok', { timeout: 5000 });
  });

  test('Deck 1 beat bar width changes across two poll cycles', async ({ page }) => {
    const w1 = await page.locator('#d1-beat').evaluate(el => el.style.width);
    await page.waitForTimeout(POLL_MS * 3);
    const w2 = await page.locator('#d1-beat').evaluate(el => el.style.width);
    // The beat bar must move; if it stays identical across 900 ms something is frozen
    expect(w1).not.toBe(w2);
  });

  test('Deck 1 beat bar width is a percentage within 0..100', async ({ page }) => {
    const w = await page.locator('#d1-beat').evaluate(el => parseFloat(el.style.width));
    expect(w).toBeGreaterThanOrEqual(0);
    expect(w).toBeLessThanOrEqual(100);
  });
});

test.describe('Error state', () => {
  test('status dot turns red when API is unreachable', async ({ page }) => {
    // Point the dashboard at a port that has nothing listening
    await page.goto(`${API}/dashboard`);
    await page.waitForSelector('#healthDot.ok', { timeout: 5000 });

    // Intercept all /health and /state requests and make them fail
    await page.route(`${API}/health`, route => route.abort());
    await page.route(`${API}/state`,  route => route.abort());

    await page.waitForSelector('#healthDot.err', { timeout: 5000 });
    const text = await page.locator('#healthText').innerText();
    expect(text).not.toBe('CONNECTED');
  });
});
