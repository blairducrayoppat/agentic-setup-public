// capture-web-cdp.mjs — #823 H8/H9: protocol-level browser-console capture + positive behavior smoke.
//
// WHY (evidence B5n2, failure-taxonomy-20260711): a web app rendered the literal text
// "OK (sum = undefined)". The pixel-only VLM critic quoted the string three times and called
// it cosmetic; the coder cosmetically HID it; the chart stayed blank; the run STALLED. The
// runtime JS error sat in the browser console the whole time — the msedge `--screenshot`
// one-shot capture has no console channel, so no gate ever saw it.
//
// This helper drives Edge/Chromium over the DevTools Protocol (CDP) — the PROTOCOL level, not an
// in-page hook. H8: `Runtime.consoleAPICalled` / `Runtime.exceptionThrown` / `Log.entryAdded` are
// events the PAGE cannot suppress (a small-model coder can silence `window.onerror` or override
// `console.error`, but it cannot reach a CDP event). H9: after load it runs a POSITIVE behavior
// smoke — clicks the primary action, asserts a DOM delta, and flags `undefined`/`NaN` substrings in
// the RENDERED text — the check that actually catches B5 (a cosmetic hide passes "no error" but not
// "the primary action changed the DOM and no cell reads undefined").
//
// Zero npm install: Node built-ins only (global `WebSocket` [Node >=22], `http`, `child_process`,
// `fs`). Fail-soft everywhere: any failure writes a sidecar with `captured:false` and a reason, and
// exits non-zero so the caller (capture-app.ps1) falls back to today's pixel-only `--screenshot`
// path — "console capture unavailable -> today's pixel-only behavior, honestly noted".
//
// Usage:
//   node capture-web-cdp.mjs --url <http|file url> --out <png> --console-out <json>
//                            [--app-dir <dir>] [--edge <path>] [--debug-port <n>]
//                            [--timeout-ms 30000] [--settle-ms 1200] [--profile-dir <dir>]
//
// --profile-dir: the Edge --user-data-dir this capture may use. The caller should pass it and
// own the name: it is the one join key every process in the (possibly detached) Edge tree
// carries, so a caller that owns it can enforce teardown even if this process dies uncleanly
// (capture-app.ps1 re-sweeps by it in its finally). Default: a self-generated temp dir.
//
// The behavior smoke reads an OPTIONAL declared spec from <app-dir>/blarai-smoke.json:
//   { "click": "<css selector for the primary action>", "expectDelta": "<css selector that must change>" }
// When absent, a heuristic picks the first visible enabled primary control. The rendered-text
// `undefined`/`NaN` scan is ALWAYS on and needs no declaration (it is the direct B5 catch).

import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import net from 'node:net';
import os from 'node:os';
import { pathToFileURL } from 'node:url';

// ===========================================================================
// PURE helpers (exported for verify-capture-cdp.mjs — no browser required)
// ===========================================================================

const _CTRL_RE = /[\x00-\x1f\x7f]/g;

/** One-line, control-stripped, length-capped rendering of an untrusted string (mirrors the S2
 *  rule; the PS + Python sides re-hygiene, this only keeps the sidecar JSON lines clean). */
export function cleanText(text, cap = 400) {
  return String(text ?? '').replace(_CTRL_RE, ' ').replace(/\s+/g, ' ').trim().slice(0, cap);
}

/** Normalize a CDP Runtime.consoleAPICalled param into {level,text,url,line}. */
export function fromConsoleApi(params) {
  const type = String(params?.type ?? 'log');
  const level = type === 'warning' ? 'warning' : (type === 'error' ? 'error' : (type === 'assert' ? 'error' : type));
  const parts = Array.isArray(params?.args) ? params.args.map(argToText) : [];
  const frame = params?.stackTrace?.callFrames?.[0] ?? {};
  return {
    source: 'console',
    level,
    text: cleanText(parts.join(' ')),
    url: cleanText(frame.url ?? '', 300),
    line: Number.isFinite(frame.lineNumber) ? frame.lineNumber + 1 : 0,
  };
}

/** Normalize a CDP Runtime.exceptionThrown param into a page-error record (always level 'error'). */
export function fromException(params) {
  const d = params?.exceptionDetails ?? {};
  const desc = d.exception?.description ?? d.text ?? 'Uncaught (unknown) exception';
  const frame = d.stackTrace?.callFrames?.[0] ?? {};
  return {
    source: 'exception',
    level: 'error',
    text: cleanText(desc),
    url: cleanText(d.url ?? frame.url ?? '', 300),
    line: Number.isFinite(d.lineNumber) ? d.lineNumber + 1 : (Number.isFinite(frame.lineNumber) ? frame.lineNumber + 1 : 0),
  };
}

/** Normalize a CDP Log.entryAdded entry (browser log: failed module/network loads, CORS, CSP). */
export function fromLogEntry(entry) {
  const level = String(entry?.level ?? 'info') === 'error' ? 'error' : (String(entry?.level) === 'warning' ? 'warning' : 'info');
  return {
    source: 'browser',
    level,
    text: cleanText(entry?.text ?? ''),
    url: cleanText(entry?.url ?? '', 300),
    line: Number.isFinite(entry?.lineNumber) ? entry.lineNumber + 1 : 0,
  };
}

function argToText(arg) {
  if (arg == null) return '';
  if (arg.value !== undefined) return typeof arg.value === 'string' ? arg.value : JSON.stringify(arg.value);
  if (arg.description) return arg.description;
  if (arg.unserializableValue) return String(arg.unserializableValue);
  if (arg.type) return `[${arg.type}]`;
  return '';
}

/** A console/exception/browser entry is a hard RUNTIME ERROR when its level is 'error'. */
export function isRuntimeError(entry) {
  return entry && entry.level === 'error';
}

/** Scan RENDERED text for the B5 shape: `undefined` / `NaN` tokens (a value that failed to compute
 *  leaked into the UI). Whole-token match keeps false positives low; samples give the fix context. */
export function scanRenderedText(innerText) {
  const text = String(innerText ?? '');
  const out = { hasUndefined: false, hasNaN: false, samples: [] };
  for (const [token, key] of [[/\bundefined\b/gi, 'hasUndefined'], [/\bNaN\b/g, 'hasNaN']]) {
    let m;
    let count = 0;
    while ((m = token.exec(text)) && count < 3) {
      out[key] = true;
      const start = Math.max(0, m.index - 24);
      const end = Math.min(text.length, m.index + m[0].length + 24);
      out.samples.push(cleanText(text.slice(start, end), 80));
      count += 1;
    }
  }
  return out;
}

/** Decide whether the primary-action click produced a POSITIVE behavior (H9). ``before``/``after``
 *  are DOM snapshots ({elementCount, htmlLen, chartMarks, canvasInk, textLen}); ``spec`` may name an
 *  ``expectDelta`` region the snapshot recorded under ``regionHtmlLen``. A delta in ANY structural
 *  axis (or the named region) counts; no delta on a real click is the "cosmetic hide" tell. */
export function evaluateBehavior(before, after, spec, click) {
  const b = before || {}, a = after || {};
  if (!click || !click.clicked) {
    return { ran: true, ok: false, changed: false,
      reason: click && click.reason ? cleanText(click.reason) : 'no primary action could be found or clicked' };
  }
  if (spec && spec.expectDelta) {
    const changed = (a.regionHtmlLen ?? -1) !== (b.regionHtmlLen ?? -2) || (a.regionText ?? '') !== (b.regionText ?? '');
    return { ran: true, ok: changed, changed,
      reason: changed ? '' : `the declared result region (${cleanText(spec.expectDelta, 80)}) did not change after the primary action` };
  }
  const changed = (a.htmlLen !== b.htmlLen) || (a.elementCount !== b.elementCount)
    || (a.chartMarks !== b.chartMarks) || (a.canvasInk !== b.canvasInk) || (a.textLen !== b.textLen);
  return { ran: true, ok: changed, changed,
    reason: changed ? '' : `the primary action (${cleanText(click.selectorUsed || 'auto', 80)}) produced no visible change when clicked` };
}

/** Build the VERBATIM runtime findings list (file/line/message) the fix-cycle prompt must carry,
 *  ranked errors-first. A finding is a single clean line; the PS + Python sides fence + cap it. The
 *  behavior finding is included only when ``behaviorHard`` (a DECLARED must-work feature failed) —
 *  a heuristic no-delta is a SOFT note (see ``run``), never a forced fix on a button-less page. */
export function buildFindings(consoleEntries, pageErrors, behavior, textScan, behaviorHard = true) {
  const findings = [];
  const loc = (e) => (e.url ? ` (${e.url}${e.line ? ':' + e.line : ''})` : '');
  for (const e of pageErrors || []) {
    if (isRuntimeError(e)) findings.push(cleanText(`Uncaught exception: ${e.text}${loc(e)}`, 400));
  }
  for (const e of consoleEntries || []) {
    if (isRuntimeError(e)) findings.push(cleanText(`console.error: ${e.text}${loc(e)}`, 400));
  }
  if (textScan && (textScan.hasUndefined || textScan.hasNaN)) {
    const kinds = [textScan.hasUndefined ? '"undefined"' : null, textScan.hasNaN ? '"NaN"' : null].filter(Boolean).join(' and ');
    const sample = textScan.samples[0] ? ` (e.g. "${textScan.samples[0]}")` : '';
    findings.push(cleanText(`Rendered text contains ${kinds}${sample} — a value failed to compute and leaked into the UI; fix the computation, do NOT hide the text`, 400));
  }
  if (behaviorHard && behavior && behavior.ran && !behavior.ok && behavior.reason) {
    findings.push(cleanText(`Behavior smoke: ${behavior.reason}`, 400));
  }
  return findings;
}

/** Count the errors across both channels (belt for the "zero console errors = PASS" signal). */
export function errorCount(consoleEntries, pageErrors) {
  return (consoleEntries || []).filter(isRuntimeError).length + (pageErrors || []).filter(isRuntimeError).length;
}

/** The authoritative HARD verdict: a console/exception error, an ``undefined``/``NaN`` text leak, or
 *  a DECLARED-behavior failure forces another FIX iteration. A heuristic no-delta does NOT (soft). */
export function computeHard(consoleEntries, pageErrors, textScan, behaviorHard) {
  return errorCount(consoleEntries, pageErrors) > 0
    || !!(textScan && (textScan.hasUndefined || textScan.hasNaN))
    || !!behaviorHard;
}

// ===========================================================================
// IMPURE: CDP client, Edge launch, orchestration
// ===========================================================================

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--')) { out[a.slice(2)] = (i + 1 < argv.length && !argv[i + 1].startsWith('--')) ? argv[++i] : true; }
  }
  return out;
}

function freePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.on('error', reject);
    srv.listen(0, '127.0.0.1', () => { const p = srv.address().port; srv.close(() => resolve(p)); });
  });
}

function findEdge(explicit) {
  if (explicit && fs.existsSync(explicit)) return explicit;
  const cands = [
    'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
    'C:/Program Files/Microsoft/Edge/Application/msedge.exe',
  ];
  for (const c of cands) if (fs.existsSync(c)) return c;
  return 'msedge'; // rely on PATH
}

function httpGetJson(url, timeoutMs = 2000) {
  return new Promise((resolve, reject) => {
    const req = http.get(url, { timeout: timeoutMs }, (res) => {
      let body = '';
      res.on('data', (c) => (body += c));
      res.on('end', () => { try { resolve(JSON.parse(body)); } catch (e) { reject(e); } });
    });
    req.on('error', reject);
    req.on('timeout', () => req.destroy(new Error('timeout')));
  });
}

async function getPageTarget(port, deadline) {
  while (Date.now() < deadline) {
    try {
      const list = await httpGetJson(`http://127.0.0.1:${port}/json/list`);
      const page = Array.isArray(list) && list.find((t) => t.type === 'page' && t.webSocketDebuggerUrl);
      if (page) return page;
    } catch { /* not up yet */ }
    await sleep(200);
  }
  return null;
}

// Minimal CDP JSON-RPC client over the built-in global WebSocket.
class Cdp {
  constructor(ws) {
    this.ws = ws;
    this.nextId = 0;
    this.pending = new Map();
    this.handlers = [];
    ws.addEventListener('message', (ev) => {
      let msg;
      try { msg = JSON.parse(typeof ev.data === 'string' ? ev.data : ev.data.toString()); } catch { return; }
      if (msg.id != null && this.pending.has(msg.id)) {
        const { resolve, reject } = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        if (msg.error) reject(new Error(msg.error.message || 'CDP error'));
        else resolve(msg.result);
      } else if (msg.method) {
        for (const h of this.handlers) { try { h(msg.method, msg.params); } catch { /* handler isolation */ } }
      }
    });
  }
  on(fn) { this.handlers.push(fn); }
  send(method, params = {}) {
    const id = ++this.nextId;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, method, params }));
    });
  }
}

function connectWs(url, timeoutMs) {
  return new Promise((resolve, reject) => {
    // eslint-disable-next-line no-undef -- global WebSocket (Node >= 22)
    const ws = new WebSocket(url);
    const timer = setTimeout(() => { try { ws.close(); } catch {} reject(new Error('WS connect timeout')); }, timeoutMs);
    ws.addEventListener('open', () => { clearTimeout(timer); resolve(ws); });
    ws.addEventListener('error', (e) => { clearTimeout(timer); reject(new Error('WS error: ' + (e?.message || 'unknown'))); });
  });
}

async function evalJson(cdp, expression) {
  const r = await cdp.send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
  if (r && r.result && r.result.value !== undefined) return r.result.value;
  return null;
}

// A DOM snapshot expression (IIFE returning a JSON-serializable object). Records the structural
// axes a positive behavior smoke needs, plus an optional named region.
function snapshotJs(regionSelector) {
  const sel = JSON.stringify(regionSelector || '');
  return `(function(){
    try {
      var body = document.body || document.documentElement;
      var html = body ? body.innerHTML : '';
      var text = body ? (body.innerText || body.textContent || '') : '';
      var marks = document.querySelectorAll('svg, canvas, path, rect, circle, line, polyline, .bar, [data-series]').length;
      var canvasInk = 0;
      try {
        document.querySelectorAll('canvas').forEach(function(cv){
          try { var ctx = cv.getContext('2d'); if(!ctx) return; var d = ctx.getImageData(0,0,Math.min(cv.width,64),Math.min(cv.height,64)).data;
            for (var i=3;i<d.length;i+=4){ if(d[i]!==0){ canvasInk++; break; } } } catch(e){}
        });
      } catch(e){}
      var region = null, regionText = '';
      var rsel = ${sel};
      if (rsel) { try { region = document.querySelector(rsel); if(region){ regionText = (region.innerText||region.textContent||''); } } catch(e){} }
      return {
        htmlLen: html.length,
        textLen: text.length,
        innerText: String(text).slice(0, 4000),
        elementCount: document.getElementsByTagName('*').length,
        chartMarks: marks,
        canvasInk: canvasInk,
        regionHtmlLen: region ? region.innerHTML.length : -1,
        regionText: String(regionText).slice(0, 500)
      };
    } catch (e) { return { error: String(e) }; }
  })()`;
}

// Click the primary action. Uses spec.click when declared, else a heuristic (first visible, enabled
// primary control). Returns {clicked, selectorUsed, reason}. Never throws into the page.
function clickJs(clickSelector) {
  const sel = JSON.stringify(clickSelector || '');
  return `(function(){
    try {
      function visible(el){ if(!el) return false; var r=el.getBoundingClientRect(); var s=getComputedStyle(el);
        return r.width>0 && r.height>0 && s.visibility!=='hidden' && s.display!=='none' && !el.disabled; }
      var explicit = ${sel};
      var el = null, used = '';
      if (explicit) { el = document.querySelector(explicit); used = explicit; if(el && !visible(el)) el=null; }
      if (!el) {
        var order = ['button','[type=submit]','input[type=button]','[role=button]','a[href]'];
        for (var i=0;i<order.length && !el;i++){
          var list = document.querySelectorAll(order[i]);
          for (var j=0;j<list.length;j++){ if(visible(list[j])){ el=list[j]; used=order[i]; break; } }
        }
      }
      if (!el) return { clicked:false, selectorUsed: used, reason:'no visible, enabled primary action (button/submit/role=button/link) was found' };
      el.click();
      return { clicked:true, selectorUsed: used || el.tagName.toLowerCase(), reason:'' };
    } catch (e) { return { clicked:false, selectorUsed:'', reason:'click threw: '+String(e) }; }
  })()`;
}

function readSmokeSpec(appDir) {
  if (!appDir) return null;
  try {
    const p = path.join(appDir, 'blarai-smoke.json');
    if (!fs.existsSync(p)) return null;
    const spec = JSON.parse(fs.readFileSync(p, 'utf8'));
    if (spec && typeof spec === 'object') {
      return { click: typeof spec.click === 'string' ? spec.click : '', expectDelta: typeof spec.expectDelta === 'string' ? spec.expectDelta : '' };
    }
  } catch { /* fail-soft: no/garbled spec -> heuristic */ }
  return null;
}

function writeSidecar(sidecarPath, obj) {
  try { fs.writeFileSync(sidecarPath, JSON.stringify(obj)); } catch { /* best effort */ }
}

async function run() {
  const args = parseArgs(process.argv.slice(2));
  const url = args.url;
  const outPng = args.out;
  const sidecarPath = args['console-out'] || (outPng ? outPng + '.console.json' : null);
  const timeoutMs = Number(args['timeout-ms']) || 30000;
  const settleMs = Number(args['settle-ms']) || 1200;
  const appDir = args['app-dir'] || '';

  if (!url || !outPng || !sidecarPath) {
    if (sidecarPath) writeSidecar(sidecarPath, { captured: false, error: 'missing --url/--out/--console-out', console: [], pageErrors: [], findings: [] });
    console.error('capture-web-cdp: missing required --url/--out/--console-out');
    process.exit(2);
  }

  const spec = readSmokeSpec(appDir);
  const edge = findEdge(typeof args.edge === 'string' ? args.edge : '');
  const port = Number(args['debug-port']) || (await freePort());
  const profile = (typeof args['profile-dir'] === 'string' && args['profile-dir'])
    ? args['profile-dir']
    : path.join(os.tmpdir(), 'edge-cdp-' + Math.random().toString(36).slice(2));

  let child = null;
  let ws = null;
  const consoleEntries = [];
  const pageErrors = [];

  // Teardown is EXIT-SYNCHRONOUS, never scheduled (#1027): the 2026-07-21 leak (8 Edge trees x
  // ~9 msedge, ~7 cores, 8 profile dirs) had two causes here — `child.kill()` reaches only the
  // launcher PID while headless Edge re-execs into a DETACHED tree that outlives it, and the
  // profile rm was scheduled on a setTimeout that a same-tick process.exit() killed before it
  // ever fired. `process.on('exit')` runs on EVERY exit path (success, failSoft, fatal throw);
  // only synchronous work survives inside it. If the profile dir will not delete after the
  // PID-tree kill, something detached still holds it: escalate once to a kill-by-user-data-dir
  // sweep (the one join key every process in the tree carries), then retry the rm.
  const sleepSync = (ms) => { try { Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms); } catch {} };
  function teardownSync() {
    try { if (ws) ws.close(); } catch {}
    if (child && child.pid) {
      try { spawnSync('taskkill', ['/PID', String(child.pid), '/T', '/F'], { stdio: 'ignore', timeout: 10000 }); } catch {}
    }
    for (let attempt = 1; attempt <= 3; attempt++) {
      try { fs.rmSync(profile, { recursive: true, force: true }); } catch {}
      if (!fs.existsSync(profile)) return;
      if (attempt === 1) {
        const key = path.basename(profile);
        try {
          spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command',
            `Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object { $_.CommandLine -like '*${key}*' } | ForEach-Object { & taskkill.exe /PID $_.ProcessId /T /F } *> $null`,
          ], { stdio: 'ignore', timeout: 15000 });
        } catch {}
      }
      sleepSync(400);
    }
    // Still held after three tries: leave it rather than block exit — the caller re-sweeps by
    // this same profile-dir key (see --profile-dir above).
  }
  process.on('exit', teardownSync);

  const failSoft = (reason) => {
    writeSidecar(sidecarPath, { captured: false, error: cleanText(reason, 300), console: consoleEntries, pageErrors, findings: [] });
    console.error('capture-web-cdp: ' + reason);
    process.exit(2); // teardownSync (exit handler) kills the Edge tree + removes the profile dir
  };

  // A wedged CDP await (Edge stops answering mid-session) previously hung node forever — and
  // with it the calling ps1, so NO teardown ever ran anywhere. Hard wall-clock cap: the capture
  // either finishes or fail-softs; every exit runs teardownSync.
  setTimeout(() => failSoft('hard-deadline watchdog fired (CDP session wedged)'), timeoutMs + 15000);

  try {
    child = spawn(edge, [
      '--headless=new', '--disable-gpu', '--no-sandbox', '--no-first-run', '--no-default-browser-check',
      `--user-data-dir=${profile}`, `--remote-debugging-port=${port}`, '--remote-allow-origins=*',
      '--window-size=1280,900', 'about:blank',
    ], { stdio: 'ignore' });
    child.on('error', () => { /* handled by target poll timeout */ });
  } catch (e) {
    return failSoft('could not launch Edge: ' + (e && e.message));
  }

  const deadline = Date.now() + Math.min(timeoutMs, 15000);
  const target = await getPageTarget(port, deadline);
  if (!target) return failSoft('CDP endpoint /json/list produced no page target (Edge/remote-debugging unavailable)');

  try {
    ws = await connectWs(target.webSocketDebuggerUrl, 5000);
  } catch (e) {
    return failSoft('CDP WebSocket connect failed: ' + (e && e.message));
  }

  const cdp = new Cdp(ws);
  cdp.on((method, params) => {
    try {
      if (method === 'Runtime.consoleAPICalled') consoleEntries.push(fromConsoleApi(params));
      else if (method === 'Runtime.exceptionThrown') pageErrors.push(fromException(params));
      else if (method === 'Log.entryAdded') {
        const e = fromLogEntry(params.entry);
        if (e.level === 'error') pageErrors.push(e); else consoleEntries.push(e);
      }
    } catch { /* never let event handling abort the capture */ }
  });

  try {
    await cdp.send('Runtime.enable');
    await cdp.send('Log.enable');
    await cdp.send('Page.enable');
    await cdp.send('Emulation.setDeviceMetricsOverride', { width: 1280, height: 900, deviceScaleFactor: 1, mobile: false }).catch(() => {});

    const loaded = new Promise((res) => cdp.on((m) => { if (m === 'Page.loadEventFired') res(); }));
    await cdp.send('Page.navigate', { url });
    await Promise.race([loaded, sleep(Math.min(timeoutMs, 20000))]);
    await sleep(settleMs); // let deferred module JS run + async console/exception fire

    // ---- H9 behavior smoke: snapshot -> click primary action -> snapshot -> evaluate delta ----
    let behavior = { ran: false, ok: true, changed: false, reason: '' };
    let textScan = { hasUndefined: false, hasNaN: false, samples: [] };
    try {
      const before = await evalJson(cdp, snapshotJs(spec && spec.expectDelta));
      const click = await evalJson(cdp, clickJs(spec && spec.click));
      await sleep(500); // allow the action's async render to land
      const after = await evalJson(cdp, snapshotJs(spec && spec.expectDelta));
      textScan = scanRenderedText((after && after.innerText) || (before && before.innerText) || '');
      behavior = evaluateBehavior(before, after, spec, click);
    } catch (e) {
      behavior = { ran: false, ok: true, changed: false, reason: 'behavior smoke skipped: ' + cleanText(String(e), 120) };
    }

    // ---- screenshot via CDP (same session, same render the console came from) ----
    let shotOk = false;
    try {
      const shot = await cdp.send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false });
      if (shot && shot.data) { fs.writeFileSync(outPng, Buffer.from(shot.data, 'base64')); shotOk = fs.existsSync(outPng) && fs.statSync(outPng).size > 100; }
    } catch (e) {
      return failSoft('Page.captureScreenshot failed: ' + (e && e.message));
    }
    if (!shotOk) return failSoft('screenshot was empty/unwritten');

    // Spec-declared behavior is HARD (a must-work feature must work); a heuristic no-delta is SOFT.
    const specDeclared = !!(spec && (spec.click || spec.expectDelta));
    const behaviorHard = specDeclared && behavior.ran && !behavior.ok;
    const findings = buildFindings(consoleEntries, pageErrors, behavior, textScan, behaviorHard);
    const notes = (!behaviorHard && behavior.ran && !behavior.ok && behavior.reason)
      ? [cleanText(`Behavior note (heuristic, not enforced): ${behavior.reason}`, 400)] : [];
    const hard = computeHard(consoleEntries, pageErrors, textScan, behaviorHard);
    writeSidecar(sidecarPath, {
      captured: true,
      hard,
      url: cleanText(url, 300),
      console: consoleEntries,
      pageErrors,
      errorCount: errorCount(consoleEntries, pageErrors),
      textScan,
      behavior,
      specDeclared,
      behaviorHard,
      findings,
      notes,
    });

    process.exit(0); // teardownSync (exit handler) kills the Edge tree + removes the profile dir
  } catch (e) {
    return failSoft('CDP session error: ' + (e && e.message));
  }
}

// Only orchestrate when run as a script (import for the pure-fn unit tests must not launch Edge).
const isMain = (() => {
  try { return import.meta.url === pathToFileURL(process.argv[1] || '').href; }
  catch { return false; }
})();
if (isMain) {
  run().catch((e) => { console.error('capture-web-cdp fatal: ' + (e && e.message)); process.exit(2); });
}
