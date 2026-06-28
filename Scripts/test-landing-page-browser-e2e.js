#!/usr/bin/env node
// Browser e2e for docs/landing.html. Runs the static page in headless Chrome via
// the Chrome DevTools Protocol using only Node stdlib/web APIs. It intentionally
// does not import Swift app code, build targets, or daemon modules.

const { spawn, spawnSync } = require('node:child_process');
const { existsSync, mkdtempSync, rmSync } = require('node:fs');
const { tmpdir } = require('node:os');
const { resolve } = require('node:path');
const { pathToFileURL } = require('node:url');

const ROOT = resolve(__dirname, '..');
const LANDING = resolve(process.env.LANDING_PAGE || `${ROOT}/docs/landing.html`);
const CHROME = process.env.CHROME_BIN || findChrome();
const timeoutMs = Number(process.env.LANDING_E2E_TIMEOUT_MS || 30000);

function findChrome() {
  const candidates = [
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/Applications/Chromium.app/Contents/MacOS/Chromium',
    '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
    process.env.GOOGLE_CHROME_SHIM,
    'google-chrome',
    'chromium',
  ].filter(Boolean);
  for (const candidate of candidates) {
    if (candidate.startsWith('/') && existsSync(candidate)) return candidate;
    if (!candidate.startsWith('/')) {
      const found = spawnSync('command', ['-v', candidate], { shell: true, encoding: 'utf8' });
      if (found.status === 0 && found.stdout.trim()) return candidate;
    }
  }
  return null;
}

if (!CHROME) {
  console.error('FAIL: no Chrome/Chromium binary found; set CHROME_BIN');
  process.exit(1);
}

const userDataDir = mkdtempSync(`${tmpdir()}/landing-e2e-`);
let chrome;
let cdp;
let nextId = 1;
const pending = new Map();
const startedAt = Date.now();

function fail(message) {
  throw new Error(message);
}

function assert(condition, message) {
  if (!condition) fail(message);
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function waitFor(label, fn, timeout = timeoutMs) {
  const deadline = Date.now() + timeout;
  let last;
  while (Date.now() < deadline) {
    last = await fn();
    if (last) return last;
    await sleep(100);
  }
  fail(`timed out waiting for ${label}; last=${JSON.stringify(last)}`);
}

function command(method, params = {}) {
  const id = nextId++;
  cdp.send(JSON.stringify({ id, method, params }));
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject, method });
  });
}

async function evaluate(expression) {
  const response = await command('Runtime.evaluate', {
    expression,
    awaitPromise: true,
    returnByValue: true,
  });
  if (response.exceptionDetails) {
    fail(`browser evaluation failed: ${response.exceptionDetails.text || 'exception'}`);
  }
  return response.result?.value;
}

async function clickDot(scene) {
  await evaluate(`document.querySelector('[data-scene="${scene}"]').click()`);
  await waitFor(`scene ${scene} active`, () => evaluate(`
    document.querySelector('[data-scene="${scene}"]').getAttribute('aria-current') === 'true'
  `));
}

function launchChrome() {
  return new Promise((resolve, reject) => {
    const url = pathToFileURL(LANDING).href;
    const args = [
      '--headless=new',
      '--disable-gpu',
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-background-networking',
      '--disable-extensions',
      '--remote-debugging-port=0',
      `--user-data-dir=${userDataDir}`,
      url,
    ];
    chrome = spawn(CHROME, args, { stdio: ['ignore', 'ignore', 'pipe'] });
    let stderr = '';
    const timer = setTimeout(() => reject(new Error(`Chrome did not expose DevTools URL. stderr=${stderr}`)), 10000);
    chrome.stderr.on('data', chunk => {
      stderr += chunk.toString();
      const match = stderr.match(/DevTools listening on (ws:\/\/[^\s]+)/);
      if (match) {
        clearTimeout(timer);
        resolve(match[1]);
      }
    });
    chrome.on('error', reject);
    chrome.on('exit', code => {
      if (!cdp) reject(new Error(`Chrome exited before connection with code ${code}; stderr=${stderr}`));
    });
  });
}

async function pageWebSocketUrl(browserWsUrl) {
  const url = new URL(browserWsUrl);
  const response = await fetch(`http://${url.host}/json/list`);
  if (!response.ok) fail(`could not list Chrome targets: HTTP ${response.status}`);
  const targets = await response.json();
  const page = targets.find(t => t.type === 'page' && t.url.startsWith('file:')) || targets.find(t => t.type === 'page');
  if (!page?.webSocketDebuggerUrl) fail(`could not find page target in ${JSON.stringify(targets)}`);
  return page.webSocketDebuggerUrl;
}

async function connect(browserWsUrl) {
  const pageWsUrl = await pageWebSocketUrl(browserWsUrl);
  cdp = new WebSocket(pageWsUrl);
  await new Promise((resolve, reject) => {
    cdp.once?.('open', resolve);
    if (!cdp.once) {
      cdp.addEventListener('open', resolve, { once: true });
      cdp.addEventListener('error', reject, { once: true });
    }
  });
  cdp.addEventListener('message', event => {
    const message = JSON.parse(event.data);
    if (!message.id) return;
    const item = pending.get(message.id);
    if (!item) return;
    pending.delete(message.id);
    if (message.error) item.reject(new Error(`${item.method}: ${message.error.message}`));
    else item.resolve(message.result);
  });
  await command('Runtime.enable');
  await command('Page.enable');
}

async function run() {
  const wsUrl = await launchChrome();
  await connect(wsUrl);

  await waitFor('landing page ready', () => evaluate('document.readyState === "complete"'));

  const dotScenes = await evaluate(`Array.from(document.querySelectorAll('#dots .dot')).map(d => d.dataset.scene).join(',')`);
  assert(dotScenes === '0,1,2', `expected dots for scenes 0,1,2; got ${dotScenes}`);

  // Drive the carousel manually through every scene before exercising scene 2.
  await clickDot(0);
  await waitFor('Tree of Thought profile', () => evaluate('document.querySelector("#profileName")?.textContent === "Tree of Thought (experimental)"'));
  await clickDot(1);
  await waitFor('JSON Think profile', () => evaluate('document.querySelector("#profileName")?.textContent === "JSON Think"'));
  await clickDot(2);
  await waitFor('Best of N profile', () => evaluate('document.querySelector("#profileName")?.textContent === "Best of N"'));

  await waitFor('round 1 renders three options', () => evaluate(`document.querySelectorAll('#bon1 .bonopt.in').length === 3`));
  await waitFor('round 1 pick appears', () => evaluate(`document.querySelectorAll('#bon1 .bonopt.chosen').length === 1`));
  await waitFor('comment appears after pick', () => evaluate(`
    Array.from(document.querySelectorAll('.boncomment')).some(n => n.textContent.trim() === 'Make it more practical.')
  `));
  await waitFor('round 2 renders three options seeded by comment', () => evaluate(`document.querySelectorAll('#bon2 .bonopt.in').length === 3`));
  await waitFor('round 2 final pick appears', () => evaluate(`document.querySelectorAll('#bon2 .bonopt.chosen').length === 1`));
  await waitFor('final answer appears', () => evaluate(`
    Array.from(document.querySelectorAll('.bubble.assistant')).some(n => n.textContent.trim() === 'Build a windowsill herb planter with a short shopping list.')
  `));

  await waitFor('carousel cycles from scene 2 back to scene 0', () => evaluate(`
    document.querySelector('[data-scene="0"]').getAttribute('aria-current') === 'true'
  `), 12000);

  console.log(`PASS: landing browser e2e (${Date.now() - startedAt}ms)`);
}

run().catch(error => {
  console.error(`FAIL: ${error.message}`);
  process.exitCode = 1;
}).finally(() => {
  try { cdp?.close?.(); } catch {}
  try { chrome?.kill?.('SIGTERM'); } catch {}
  try { rmSync(userDataDir, { recursive: true, force: true }); } catch {}
});
