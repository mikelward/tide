#!/usr/bin/env node
// Draws the boot splash theme's images (plymouth/tide/*.png) from
// images.html: one PNG per element with class "img", named by its id, on a
// transparent background, at 1x, the size Plymouth draws them.
//
// Usage: node plymouth/render.js   (`make splash-images` sets NODE_PATH)
//
// Needs Playwright with Chromium, as docs/mocks/render.js does, and
// fonts.googleapis.com for Inter. A font or script that fails fails the
// render, rather than drawing the wordmark in another font.

const path = require('path');
const { chromium } = require('playwright');

const dir = __dirname;
const outDir = path.join(dir, 'tide');

(async () => {
  const browser = await chromium.launch();
  let failed = false;
  const tab = await browser.newPage({ viewport: { width: 800, height: 600 }, deviceScaleFactor: 1 });
  tab.on('requestfailed', (r) => { failed = true; console.error(`failed to load ${r.url()}`); });
  tab.on('pageerror', (e) => { failed = true; console.error(`script error: ${e.message}`); });
  await tab.goto('file://' + path.join(dir, 'images.html'), { waitUntil: 'networkidle' });
  const broken = await tab.evaluate(async () => {
    await document.fonts.ready;
    return [...document.fonts].filter((f) => f.status === 'error').map((f) => f.family);
  });
  for (const f of broken) { failed = true; console.error(`font failed to load: ${f}`); }
  if (!failed) {
    const ids = await tab.$$eval('.img', (els) => els.map((e) => e.id));
    for (const id of ids) {
      await tab.locator('#' + id).screenshot({ path: path.join(outDir, id + '.png'), omitBackground: true });
    }
    console.log(`${ids.length} images in ${path.relative(process.cwd(), outDir)}`);
  }
  await browser.close();
  process.exit(failed ? 1 : 0);
})();
