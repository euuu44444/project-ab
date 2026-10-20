// The one place that finds Playwright and Chromium and starts the browser the way the Android target looks to the game.
//
// Used by tools/verify_golden_chromium.mjs, tools/census_rng_slots_chromium.mjs and tools/reference-trace/capture.mjs, so that
// every tool that runs the original game in a browser sees the same environment (design section 9.2):
//   - viewport 390 x 844 CSS pixels, deviceScaleFactor 3, isMobile and hasTouch, so that the game's
//     IS_COARSE_POINTER (= matchMedia("(pointer:coarse)").matches) is true and its entity caps are the Android ones;
//   - a fresh profile for every context (no localStorage, no cookies): difficulty, unlocks, tutorial and meta progress start at
//     their defaults;
//   - Chromium 141 (V8 14.1), the version the golden vectors and the reference traces are recorded with.
//
// Where things are looked up (first hit wins):
//   Playwright   1. tools/reference-trace/node_modules (the pinned install: `cd tools/reference-trace && npm ci`)
//                2. $PLAYWRIGHT_DIR (a directory that contains node_modules/playwright, or node_modules itself)
//                3. the global npm root, then /opt/node22/lib/node_modules
//   Chromium     1. $SWARM_CHROME_BINARY
//                2. $CHROMIUM_PATH (the name the older tools used)
//                3. /opt/pw-browsers/chromium-1194/chrome-linux/chrome
//
// Node 22, ES modules. Playwright itself is CommonJS and is loaded with createRequire.
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const LIB_DIR = path.dirname(fileURLToPath(import.meta.url));
export const REPO_ROOT = path.resolve(LIB_DIR, '..', '..');
export const PINNED_PLAYWRIGHT_DIR = path.join(REPO_ROOT, 'tools', 'reference-trace');
export const DEFAULT_CHROME_BINARY = '/opt/pw-browsers/chromium-1194/chrome-linux/chrome';
/** The Chromium major version the reference data is recorded with. */
export const EXPECTED_CHROMIUM_MAJOR = 141;

/** The Android phone of the design: logical size, device pixel ratio, touch. */
export const ANDROID_CONTEXT = Object.freeze({
  viewport: Object.freeze({ width: 390, height: 844 }),
  deviceScaleFactor: 3,
  isMobile: true,
  hasTouch: true,
});

function playwrightCandidates() {
  const candidates = [PINNED_PLAYWRIGHT_DIR];
  if (process.env.PLAYWRIGHT_DIR) candidates.push(process.env.PLAYWRIGHT_DIR);
  try {
    candidates.push(execFileSync('npm', ['root', '-g'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim());
  } catch { /* npm is not available */ }
  candidates.push('/opt/node22/lib/node_modules');
  return candidates;
}

/** The directory of the Playwright package inside `dir` (dir/node_modules/playwright, or dir/playwright when dir is a node_modules), or null. */
function playwrightPackageIn(dir) {
  for (const candidate of [path.join(dir, 'node_modules', 'playwright'), path.join(dir, 'playwright')]) {
    if (fs.existsSync(path.join(candidate, 'package.json'))) return candidate;
  }
  return null;
}

/**
 * Loads Playwright. Returns { playwright, version, dir }, where dir is the package directory that was loaded. The candidates are
 * looked at one by one, by path, so that an earlier place always wins over Node's own search (NODE_PATH, parent directories);
 * that search is the last resort. Throws when nothing has it.
 */
export function loadPlaywright() {
  const require = createRequire(import.meta.url);
  for (const dir of playwrightCandidates()) {
    const packageDir = playwrightPackageIn(dir);
    if (packageDir === null) continue;
    try {
      const playwright = require(packageDir);
      return { playwright, version: JSON.parse(fs.readFileSync(path.join(packageDir, 'package.json'), 'utf8')).version, dir: packageDir };
    } catch { /* a broken install: try the next candidate */ }
  }
  try {
    return { playwright: require('playwright'), version: require('playwright/package.json').version, dir: path.dirname(require.resolve('playwright/package.json')) };
  } catch { /* fall through */ }
  throw new Error(
    'Playwright not found. Install the pinned version with `cd tools/reference-trace && PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci`, '
    + 'or set PLAYWRIGHT_DIR to a directory that contains node_modules/playwright.',
  );
}

/** The Chromium executable: $SWARM_CHROME_BINARY, $CHROMIUM_PATH or the default install. Throws when it does not exist. */
export function chromeBinary() {
  const executable = process.env.SWARM_CHROME_BINARY || process.env.CHROMIUM_PATH || DEFAULT_CHROME_BINARY;
  if (!fs.existsSync(executable)) {
    throw new Error(`Chromium not found at ${executable} (set SWARM_CHROME_BINARY to a chrome executable)`);
  }
  return executable;
}

/**
 * Starts Chromium headless. Returns { browser, playwright, playwrightVersion, executablePath, chromiumVersion, chromiumMajor }.
 * The caller closes the browser. `chromiumVersion` is like "141.0.7390.37".
 */
export async function launchChromium({ headless = true } = {}) {
  const { playwright, version: playwrightVersion } = loadPlaywright();
  const executablePath = chromeBinary();
  const browser = await playwright.chromium.launch({ executablePath, headless });
  const chromiumVersion = browser.version();
  const chromiumMajor = Number((/^(\d+)\./.exec(chromiumVersion) || [])[1]);
  return { browser, playwright, playwrightVersion, executablePath, chromiumVersion, chromiumMajor };
}

/** Throws unless the page reports a coarse pointer (what IS_COARSE_POINTER of the game reads). */
export async function assertCoarsePointer(page) {
  const coarse = await page.evaluate(() => matchMedia('(pointer:coarse)').matches);
  if (coarse !== true) throw new Error('the emulated device does not report (pointer:coarse): IS_COARSE_POINTER would be false');
}

/**
 * A fresh browser context with the Android emulation and one page in it; asserts the coarse pointer.
 * Options override the defaults of ANDROID_CONTEXT (for example a different deviceScaleFactor). Returns { context, page }.
 */
export async function newAndroidPage(browser, options = {}) {
  const context = await browser.newContext({ ...ANDROID_CONTEXT, ...options });
  const page = await context.newPage();
  await assertCoarsePointer(page);
  return { context, page };
}

/** launchChromium() followed by newAndroidPage(): the usual start of a tool. Returns the launch result plus { context, page }. */
export async function launchAndroidChromium({ headless = true, ...contextOptions } = {}) {
  const launched = await launchChromium({ headless });
  try {
    const { context, page } = await newAndroidPage(launched.browser, contextOptions);
    return { ...launched, context, page };
  } catch (error) {
    await launched.browser.close();
    throw error;
  }
}

/** Serves `html` (a string) for every request below `origin` in this page's context, so a page can be loaded from memory. */
export async function serveFromMemory(page, origin, html) {
  const base = origin.replace(/\/+$/, '');
  await page.route(`${base}/**`, (route) => route.fulfill({ status: 200, contentType: 'text/html; charset=utf-8', body: html }));
  return `${base}/index.html`;
}
