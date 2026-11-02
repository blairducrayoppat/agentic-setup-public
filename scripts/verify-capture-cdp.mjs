// verify-capture-cdp.mjs — #823 H8/H9 unit suite for the PURE logic of capture-web-cdp.mjs.
// No browser, no network: exercises console/exception normalization, the runtime-error
// classification, the rendered-text undefined/NaN scan, the positive behavior-smoke verdict, and
// the verbatim-findings composition. Run: `node --test verify-capture-cdp.mjs`.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { pathToFileURL, fileURLToPath } from 'node:url';
import {
  cleanText, fromConsoleApi, fromException, fromLogEntry, isRuntimeError,
  scanRenderedText, evaluateBehavior, buildFindings, errorCount, computeHard,
  buildNonEntryFindings,
  assessPhoneWidth, phoneWidthFinding, assessA11yBasics, assessForms,
  FORMS_PROBE, aggregateForms,
  CONTENT_WIDTH_PROBE, assessContentWidth, aggregateContentWidth, CONTENT_WIDTH_CANNOT_SEE,
  SUBMIT_CHAIN_HANDLE_PROBE, SUBMIT_CHAIN_SHAPE_PROBE, SUBMIT_BLIND_PROBE,
  hasSubmitListener, assessSubmitListeners, measureSubmitListeners,
  readSmokeSpec, isValidSmokeSelector, scanErrorText, ERROR_TEXT_PATTERNS,
  SMOKE_NOT_DECLARED, SMOKE_UNREADABLE, SMOKE_INVALID, SMOKE_HONOURED,
  SMOKE_ACTION_HOOK_MISSING, SMOKE_RESULT_HOOK_MISSING, SMOKE_DECLARED, SMOKE_UNAVAILABLE,
} from './capture-web-cdp.mjs';

test('cleanText strips control chars, collapses whitespace, caps length', () => {
  assert.equal(cleanText('a\x00b\nc\td'), 'a b c d');
  assert.equal(cleanText('x'.repeat(500), 10), 'xxxxxxxxxx');
  assert.equal(cleanText(null), '');
});

test('fromConsoleApi normalizes a console.error with location (+1 line)', () => {
  const e = fromConsoleApi({
    type: 'error',
    args: [{ type: 'string', value: 'sum is not a function' }],
    stackTrace: { callFrames: [{ url: 'http://x/app.js', lineNumber: 41 }] },
  });
  assert.equal(e.level, 'error');
  assert.equal(e.text, 'sum is not a function');
  assert.equal(e.url, 'http://x/app.js');
  assert.equal(e.line, 42);
  assert.ok(isRuntimeError(e));
});

test('console warning is NOT a runtime error', () => {
  const e = fromConsoleApi({ type: 'warning', args: [{ value: 'deprecated' }] });
  assert.equal(e.level, 'warning');
  assert.equal(isRuntimeError(e), false);
});

test('fromException surfaces the B5 thrown message verbatim (file/line)', () => {
  const e = fromException({
    exceptionDetails: {
      text: 'Uncaught',
      lineNumber: 11,
      url: 'http://x/chart.js',
      exception: { description: 'ReferenceError: sum is not defined' },
    },
  });
  assert.equal(e.level, 'error');
  assert.equal(e.text, 'ReferenceError: sum is not defined');
  assert.equal(e.url, 'http://x/chart.js');
  assert.equal(e.line, 12);
});

test('fromLogEntry maps a failed module load to an error', () => {
  const e = fromLogEntry({ level: 'error', text: 'Failed to load module script (MIME type)', url: 'http://x/main.mjs' });
  assert.equal(e.level, 'error');
  assert.ok(isRuntimeError(e));
});

test('scanRenderedText catches the exact B5 shape "OK (sum = undefined)"', () => {
  const s = scanRenderedText('Result panel\nOK (sum = undefined)\nfooter');
  assert.equal(s.hasUndefined, true);
  assert.equal(s.hasNaN, false);
  assert.ok(s.samples[0].includes('undefined'));
});

test('scanRenderedText flags NaN and ignores substrings inside words', () => {
  assert.equal(scanRenderedText('total = NaN').hasNaN, true);
  // "undefined" as a whole token only — "undefinedness" should NOT trip \bundefined\b via the
  // trailing word-boundary (there is none after "undefined" here).
  assert.equal(scanRenderedText('the undefinedness of it').hasUndefined, false);
  assert.equal(scanRenderedText('nothing wrong here').hasUndefined, false);
});

test('evaluateBehavior: a real click that changes the DOM is a PASS', () => {
  const before = { htmlLen: 100, elementCount: 10, chartMarks: 0, canvasInk: 0, textLen: 20 };
  const after = { htmlLen: 240, elementCount: 14, chartMarks: 6, canvasInk: 1, textLen: 55 };
  const v = evaluateBehavior(before, after, null, { clicked: true, selectorUsed: 'button' });
  assert.equal(v.ok, true);
  assert.equal(v.changed, true);
});

test('evaluateBehavior: a click with NO DOM delta is the cosmetic-hide tell (FAIL)', () => {
  const snap = { htmlLen: 100, elementCount: 10, chartMarks: 0, canvasInk: 0, textLen: 20 };
  const v = evaluateBehavior(snap, { ...snap }, null, { clicked: true, selectorUsed: 'button.primary' });
  assert.equal(v.ok, false);
  assert.ok(v.reason.includes('no visible change'));
});

test('evaluateBehavior: no clickable primary action -> FAIL with reason', () => {
  const v = evaluateBehavior({}, {}, null, { clicked: false, reason: 'no visible button' });
  assert.equal(v.ok, false);
  assert.ok(v.reason.includes('no visible button'));
});

test('evaluateBehavior: declared expectDelta region drives the verdict', () => {
  const before = { regionHtmlLen: 5, regionText: 'empty' };
  const afterChanged = { regionHtmlLen: 220, regionText: '5 bars' };
  const afterSame = { regionHtmlLen: 5, regionText: 'empty' };
  const spec = { expectDelta: '#chart' };
  assert.equal(evaluateBehavior(before, afterChanged, spec, { clicked: true }).ok, true);
  const miss = evaluateBehavior(before, afterSame, spec, { clicked: true });
  assert.equal(miss.ok, false);
  assert.ok(miss.reason.includes('#chart'));
});

test('buildFindings ranks exceptions first, carries the message VERBATIM (the B5 lock)', () => {
  const pageErrors = [fromException({ exceptionDetails: { url: 'http://x/chart.js', lineNumber: 41, exception: { description: 'ReferenceError: sum is not defined' } } })];
  const consoleEntries = [fromConsoleApi({ type: 'error', args: [{ value: 'render failed' }] })];
  const textScan = scanRenderedText('OK (sum = undefined)');
  const behavior = { ran: true, ok: false, reason: 'the primary action produced no visible change when clicked' };
  const f = buildFindings(consoleEntries, pageErrors, behavior, textScan);
  assert.ok(f[0].startsWith('Uncaught exception:'), 'exception ranks first');
  assert.ok(f[0].includes('sum is not defined'), 'the thrown message is verbatim');
  assert.ok(f[0].includes('chart.js:42'), 'file:line present');
  assert.ok(f.some((x) => x.startsWith('console.error:')));
  assert.ok(f.some((x) => x.includes('"undefined"')), 'the rendered-undefined finding is present');
  assert.ok(f.some((x) => x.startsWith('Behavior smoke:')));
});

test('buildFindings is empty on a clean page (zero-error PASS signal)', () => {
  assert.deepEqual(buildFindings([], [], { ran: true, ok: true, reason: '' }, { hasUndefined: false, hasNaN: false, samples: [] }), []);
});

test('errorCount counts errors across both channels, ignores warnings/info', () => {
  const con = [{ level: 'error' }, { level: 'warning' }, { level: 'info' }];
  const pe = [{ level: 'error' }];
  assert.equal(errorCount(con, pe), 2);
});

test('a heuristic (undeclared) behavior no-delta is SOFT — not a hard finding, not a forced fix', () => {
  const behavior = { ran: true, ok: false, reason: 'the primary action produced no visible change when clicked' };
  const clean = { hasUndefined: false, hasNaN: false, samples: [] };
  // buildFindings with behaviorHard=false omits the behavior line...
  assert.deepEqual(buildFindings([], [], behavior, clean, false), []);
  // ...and computeHard stays false (no errors, clean text, not a declared-behavior failure).
  assert.equal(computeHard([], [], clean, false), false);
});

test('a DECLARED behavior failure is HARD (forces a fix)', () => {
  const clean = { hasUndefined: false, hasNaN: false, samples: [] };
  assert.equal(computeHard([], [], clean, true), true);
  const behavior = { ran: true, ok: false, reason: 'the declared result region (#chart) did not change' };
  assert.ok(buildFindings([], [], behavior, clean, true).some((f) => f.startsWith('Behavior smoke:')));
});

test('computeHard: a console error alone is HARD even with clean text + no behavior issue', () => {
  const clean = { hasUndefined: false, hasNaN: false, samples: [] };
  assert.equal(computeHard([{ level: 'error' }], [], clean, false), true);
  assert.equal(computeHard([], [], { hasUndefined: true, hasNaN: false, samples: [] }, false), true);
  assert.equal(computeHard([], [], clean, false), false); // fully clean -> PASS signal
});

// ===========================================================================
// The DECLARED behavior contract (the blarai-smoke.json writer, 2026-08-06)
// ===========================================================================
//
// Until BlarAI's plan gained a writer for blarai-smoke.json, readSmokeSpec returned null on
// every run in existence: the declared arm below was unreachable and every web capture fell
// through to the heuristic, whose failures are only a soft note. These lock BOTH directions —
// that a declared contract is honoured, and that ABSENCE still yields exactly today's behavior.
// A control that is not tested OFF cannot be distinguished from one the test cannot reach.

test('isValidSmokeSelector: the ruler-minted contract selectors are accepted', () => {
  assert.equal(isValidSmokeSelector('[data-blarai-action="primary"]'), true);
  assert.equal(isValidSmokeSelector('[data-blarai-result="primary"]'), true);
  assert.equal(isValidSmokeSelector('#chart'), true);
  assert.equal(isValidSmokeSelector('.results'), true);
  assert.equal(isValidSmokeSelector('div > .out'), true);
});

test('isValidSmokeSelector: DENY-BY-DEFAULT — a selector list, a pseudo-class, a payload, junk', () => {
  assert.equal(isValidSmokeSelector('a,b'), false);          // a list hides a garbled half
  assert.equal(isValidSmokeSelector('button:hover'), false); // pseudo-class
  assert.equal(isValidSmokeSelector(':has(.x)'), false);     // functional notation
  assert.equal(isValidSmokeSelector('[onerror="alert(1)"]'), false);
  assert.equal(isValidSmokeSelector('x'.repeat(200)), false);
  assert.equal(isValidSmokeSelector(''), false);
  assert.equal(isValidSmokeSelector(null), false);
  assert.equal(isValidSmokeSelector(42), false);
});

test('isValidSmokeSelector: a REJECTION is linear-time — no catastrophic backtracking', () => {
  // REGRESSION LOCK. The validator used to be ONE regex:
  //   `(?:…|[a-zA-Z][a-zA-Z0-9]*)+(?:(?:\s*>\s*|\s+)(?:…|[a-zA-Z][a-zA-Z0-9]*)+)*`
  // — a nested quantifier over an alternation whose last branch matches a bare run of letters. V8
  // backtracks catastrophically on a near-miss: measured on this box at 66 ms for 20 characters,
  // 1.76 s for 24 and 47.2 s for 28, roughly 4x per two more. SMOKE_SELECTOR_MAX is 120, about
  // ninety characters PAST the point of no return, so the bound the design relied on bounded
  // nothing at all.
  //
  // Reachable: readSmokeSpec runs this over `blarai-smoke.json` from the app dir, and the writer
  // side runs it over a from_dict wire payload. A HANG is strictly worse than a rejection here —
  // every caller's try/catch is UNREACHABLE, because a wedged regex takes no error path.
  //
  // A real time bound, not a shape assertion: an implementation that reintroduces the nesting
  // fails this even while admitting exactly the same language.
  const shapes = [
    'a'.repeat(119) + '!',          // longest input the cap admits, near-missing at the very end
    '[' + 'a'.repeat(118) + '!',    // an attribute selector that never reaches its `="`
    'a>'.repeat(59) + '!',          // maximal child-combinator chain
    'a '.repeat(59) + '!',          // maximal descendant-combinator chain
  ];
  for (const s of shapes) {
    const started = process.hrtime.bigint();
    assert.equal(isValidSmokeSelector(s), false, `expected rejection for ${s.slice(0, 12)}…`);
    const elapsedMs = Number(process.hrtime.bigint() - started) / 1e6;
    assert.ok(elapsedMs < 250, `rejection took ${elapsedMs.toFixed(1)} ms — backtracking is back`);
  }
});

test('isValidSmokeSelector: the ASCII allowlist is spelled out, so both repos admit ONE language', () => {
  // `\w` is ASCII in JS and UNICODE-AWARE in Python, so the shorthand silently made acceptance.py
  // admit a strict SUPERSET of this — a selector one repo minted and the other refused, invisible
  // until a non-ASCII identifier appeared. Both sides now spell the classes out; these are the
  // cases that used to tell them apart.
  assert.equal(isValidSmokeSelector('café'), false);
  assert.equal(isValidSmokeSelector('#café'), false);
  assert.equal(isValidSmokeSelector('.café'), false);
  assert.equal(isValidSmokeSelector('[data-é="x"]'), false);
  assert.equal(isValidSmokeSelector('[data-x="café"]'), false);
  assert.equal(isValidSmokeSelector('中文'), false);
  // ...while the ASCII language is unchanged, in BOTH directions.
  assert.equal(isValidSmokeSelector('form div.card > span#out'), true);
  assert.equal(isValidSmokeSelector('[data-x="a b-c_1"]'), true);
  assert.equal(isValidSmokeSelector('a>b'), true);
  assert.equal(isValidSmokeSelector('a >b'), true);
  assert.equal(isValidSmokeSelector('a[b="c"]d'), true);
  assert.equal(isValidSmokeSelector('>a'), false);
  assert.equal(isValidSmokeSelector('a>'), false);
  assert.equal(isValidSmokeSelector('#1bad'), false);
});

test('readSmokeSpec: ABSENT contract -> not-declared, spec null (today, byte for byte)', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'smoke-none-'));
  const r = readSmokeSpec(dir);
  assert.equal(r.spec, null);
  assert.equal(r.status, SMOKE_NOT_DECLARED);
  assert.equal(readSmokeSpec('').status, SMOKE_NOT_DECLARED);
});

test('readSmokeSpec: a VALID contract is read whole, with its labels', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'smoke-ok-'));
  fs.writeFileSync(path.join(dir, 'blarai-smoke.json'), JSON.stringify({
    click: '[data-blarai-action="primary"]', expectDelta: '[data-blarai-result="primary"]',
    actionLabel: 'the Calculate button', resultLabel: 'the total below the form',
  }));
  const r = readSmokeSpec(dir);
  assert.equal(r.status, SMOKE_DECLARED);   // read, not yet exercised
  assert.equal(r.spec.click, '[data-blarai-action="primary"]');
  assert.equal(r.spec.actionLabel, 'the Calculate button');
});

test('readSmokeSpec: PRESENT-but-broken is NOT the same as absent (the whole point)', () => {
  const bad = fs.mkdtempSync(path.join(os.tmpdir(), 'smoke-bad-'));
  fs.writeFileSync(path.join(bad, 'blarai-smoke.json'), '{ not json');
  assert.equal(readSmokeSpec(bad).status, SMOKE_UNREADABLE);
  assert.equal(readSmokeSpec(bad).spec, null);

  const evil = fs.mkdtempSync(path.join(os.tmpdir(), 'smoke-evil-'));
  fs.writeFileSync(path.join(evil, 'blarai-smoke.json'), JSON.stringify({
    click: 'button:hover,#x', expectDelta: '#out',
  }));
  assert.equal(readSmokeSpec(evil).status, SMOKE_INVALID);   // validate-don't-repair: refused whole
  assert.equal(readSmokeSpec(evil).spec, null);
});

test('evaluateBehavior: a DECLARED action hook the delivery never grew is its own status', () => {
  const spec = { click: '[data-blarai-action="primary"]', expectDelta: '[data-blarai-result="primary"]',
                 actionLabel: 'the Calculate button', resultLabel: 'the total' };
  // The heuristic still clicked SOMETHING (clicked:true) and the DOM even changed — before this
  // change that read as a clean pass. explicitPresent:false makes the contract miss decidable.
  const v = evaluateBehavior({ htmlLen: 10, regionHtmlLen: 5 }, { htmlLen: 99, regionHtmlLen: 7 }, spec,
    { clicked: true, selectorUsed: 'button', explicitPresent: false, explicitVisible: false });
  assert.equal(v.ok, false);
  assert.equal(v.status, SMOKE_ACTION_HOOK_MISSING);
  assert.ok(v.reason.includes('the Calculate button'));
  assert.ok(v.reason.includes('data-blarai-action'));
});

test('evaluateBehavior: a marked but hidden/disabled control is reported as unusable', () => {
  const spec = { click: '[data-blarai-action="primary"]', expectDelta: '#out', actionLabel: 'the Go button' };
  const v = evaluateBehavior({ regionHtmlLen: 1 }, { regionHtmlLen: 1 }, spec,
    { clicked: true, explicitPresent: true, explicitVisible: false });
  assert.equal(v.ok, false);
  assert.equal(v.status, SMOKE_ACTION_HOOK_MISSING);
  assert.ok(/hidden or disabled/.test(v.reason));
});

test('evaluateBehavior: a DECLARED result hook that matches nothing is decidable, not inferred', () => {
  const spec = { click: '[data-blarai-action="primary"]', expectDelta: '[data-blarai-result="primary"]',
                 actionLabel: 'the Go button', resultLabel: 'the results panel' };
  // regionHtmlLen -1 on BOTH snapshots == querySelector matched nothing (snapshotJs contract).
  const v = evaluateBehavior({ regionHtmlLen: -1 }, { regionHtmlLen: -1 }, spec,
    { clicked: true, explicitPresent: true, explicitVisible: true });
  assert.equal(v.ok, false);
  assert.equal(v.status, SMOKE_RESULT_HOOK_MISSING);
  assert.ok(v.reason.includes('the results panel'));
});

test('evaluateBehavior: a DECLARED contract fully met is HONOURED', () => {
  const spec = { click: '[data-blarai-action="primary"]', expectDelta: '[data-blarai-result="primary"]',
                 actionLabel: 'the Calculate button', resultLabel: 'the total' };
  const v = evaluateBehavior({ regionHtmlLen: 4, regionText: '' }, { regionHtmlLen: 40, regionText: '12.50' },
    spec, { clicked: true, explicitPresent: true, explicitVisible: true });
  assert.equal(v.ok, true);
  assert.equal(v.status, SMOKE_HONOURED);
  assert.equal(v.reason, '');
});

test('THE OFF TEST: with NO contract the verdict is the heuristic one, tagged not-declared', () => {
  // This is the byte-identical-to-today path. It must stay a SOFT heuristic verdict — the same
  // shape the pre-writer runs produced — never a declared status and never a hard finding.
  const snap = { htmlLen: 10, elementCount: 3, chartMarks: 0, canvasInk: 0, textLen: 5 };
  const v = evaluateBehavior(snap, { ...snap }, null, { clicked: true, selectorUsed: 'button.primary' });
  assert.equal(v.ok, false);
  assert.equal(v.status, SMOKE_NOT_DECLARED);
  assert.ok(v.reason.includes('produced no visible change'));
  const clean = { hasUndefined: false, hasNaN: false, samples: [] };
  assert.deepEqual(buildFindings([], [], v, clean, false), []);   // still SOFT
  assert.equal(computeHard([], [], clean, false), false);
});

test('readSmokeSpec CANNOT mint honoured — reading a contract is not exercising one', () => {
  // The self-inflicted version of the very defect this change fixes: if the read step returned
  // "honoured" on a valid file, a capture whose behavior block never reached a verdict (a wedged
  // evaluate) would report a passing contract it never exercised. The verdict is evaluateBehavior's
  // to give, never the reader's.
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'smoke-prov-'));
  fs.writeFileSync(path.join(dir, 'blarai-smoke.json'), JSON.stringify({
    click: '#go', expectDelta: '#out', actionLabel: 'the Go button', resultLabel: 'the output',
  }));
  const r = readSmokeSpec(dir);
  assert.notEqual(r.status, SMOKE_HONOURED);
  assert.equal(r.status, SMOKE_DECLARED);
  assert.ok(r.spec);
});

test('a behavior smoke that never reached a verdict reports UNAVAILABLE, not a pass', () => {
  // The shape the run() catch produces. `ran:false` is what keeps `measured` false, and the status
  // must agree with it rather than inheriting a hopeful default.
  const wedged = { ran: false, ok: true, changed: false, status: SMOKE_UNAVAILABLE, reason: 'behavior smoke skipped: Runtime.evaluate timed out' };
  assert.equal(wedged.status, SMOKE_UNAVAILABLE);
  assert.notEqual(wedged.status, SMOKE_HONOURED);
  // `ok:true` here means "raised no finding", NOT "the contract passed" — the pairing with a
  // non-honoured status is what keeps those apart.
  assert.equal(wedged.ran, false);
});

// ---------------------------------------------------------------------------------------
// #1375 — the operator-visible failure text. He opened the delivered pottery site and read
// "Failed to load pieces." where the pottery should have been: both central pages fetched a
// data file that sat outside the served root and 404'd. The string is a CAUGHT rejection
// rendered into the DOM, so there is no console error and no uncaught exception — every error
// channel the capture watched stayed silent while the page displayed its own failure in plain
// English. These lock the scanner that closes that channel.

test('scanErrorText catches the exact string the operator read', () => {
  const r = scanErrorText(['Our Pieces', 'Filter by Category', 'All Mugs Bowls', 'Failed to load pieces.'].join('\n'));
  assert.equal(r.hasErrorText, true);
  assert.ok(r.matches.length >= 1);
  assert.match(r.matches[0], /Failed to load pieces/);
});

test('scanErrorText stays QUIET on a healthy page (a scanner that always fires is not a scanner)', () => {
  const r = scanErrorText(['Handmade Pottery', 'Six pieces available', 'Mugs Bowls Vases', 'Contact the studio'].join('\n'));
  assert.equal(r.hasErrorText, false);
  assert.deepEqual(r.matches, []);
});

test('scanErrorText covers the sibling phrasings a coder writes into a catch block', () => {
  for (const s of ['Could not load the gallery', 'Unable to load items',
                   'Error loading pieces', 'Something went wrong', 'Failed to fetch data']) {
    assert.equal(scanErrorText(s).hasErrorText, true, s);
  }
});

test('scanErrorText is null/undefined safe and never throws', () => {
  for (const v of [null, undefined, '', 0, {}]) {
    assert.equal(scanErrorText(v).hasErrorText, false);
  }
});

test('the pattern list is literal phrases, not a guess at what an error might look like', () => {
  // Guards the honest-scope property: every entry must be a fixed phrase. A pattern like /error/i
  // would fire on "Error handling is covered in our FAQ" and train everyone to ignore the finding.
  assert.ok(ERROR_TEXT_PATTERNS.length >= 5);
  assert.equal(scanErrorText('Our error handling policy is described in the FAQ.').hasErrorText, false);
  assert.equal(scanErrorText('This mug has no errors in its glaze.').hasErrorText, false);
});

// ---------------------------------------------------------------------------
// #1375 item 2 (advisory half) — findings for the pages BESIDE the entry.
//
// The defect these lock: on 2026-08-15 a real TypeError that broke contact.html
// sat in pages[1].pageErrors and reached no consumer, while the one published
// finding was a favicon.ico 404 from the entry page. `buildFindings` runs before
// the extra-page loop navigates anywhere, so it structurally cannot see them.
// ---------------------------------------------------------------------------

test('a runtime error on a NON-ENTRY page becomes a finding that names its page', () => {
  const pages = [
    { url: 'http://x/', entry: true, visited: true, consoleErrors: 1 },
    { url: 'http://x/contact.html', entry: false, visited: true, consoleErrors: 1,
      pageErrors: [{ source: 'exception', level: 'error',
                     text: "TypeError: Cannot set properties of null (setting 'textContent')",
                     url: 'http://x/app.js', line: 8 }] },
    { url: 'http://x/home.html', entry: false, visited: true, consoleErrors: 0, pageErrors: [] },
  ];
  const out = buildNonEntryFindings(pages);
  assert.equal(out.length, 1, 'exactly the one page that errored');
  assert.ok(out[0].includes('contact.html'), 'the finding must NAME the page it came from');
  assert.ok(out[0].includes('TypeError'));
  assert.ok(out[0].includes('app.js:8'), 'and keep the location');
});

test('the entry page is never double-counted here', () => {
  // buildFindings already covers the entry page. If this function also emitted it, every
  // entry-page error would appear twice and the count would stop meaning anything.
  const pages = [
    { url: 'http://x/', entry: true, visited: true,
      pageErrors: [{ source: 'exception', level: 'error', text: 'ReferenceError: boom' }] },
  ];
  assert.deepEqual(buildNonEntryFindings(pages), []);
});

test('a page that could not be visited is a finding, never silence', () => {
  // "Did not look" must not render as "looked and found nothing" — the same three-state
  // discipline the rest of the capture keeps.
  const pages = [
    { url: 'http://x/', entry: true, visited: true },
    { url: 'http://x/gone.html', entry: false, visited: false, error: 'navigate failed: timeout' },
  ];
  const out = buildNonEntryFindings(pages);
  assert.equal(out.length, 1);
  assert.ok(out[0].includes('NOT VISITED'));
  assert.ok(out[0].includes('gone.html'));
});

test('a clean multi-page capture produces NOTHING (the toggle)', () => {
  // Without this, a function hard-wired to always emit would pass every test above and
  // every capture would carry noise.
  const pages = [
    { url: 'http://x/', entry: true, visited: true, consoleErrors: 0 },
    { url: 'http://x/a.html', entry: false, visited: true, consoleErrors: 0, pageErrors: [] },
    { url: 'http://x/b.html', entry: false, visited: true, consoleErrors: 0, pageErrors: [],
      textScan: { hasUndefined: false, hasNaN: false, samples: [] } },
  ];
  assert.deepEqual(buildNonEntryFindings(pages), []);
});

test('leaked undefined/NaN on a non-entry page is reported with its page', () => {
  const pages = [
    { url: 'http://x/', entry: true, visited: true },
    { url: 'http://x/list.html', entry: false, visited: true, pageErrors: [],
      textScan: { hasUndefined: true, hasNaN: false, samples: ['Price: undefined'] } },
  ];
  const out = buildNonEntryFindings(pages);
  assert.equal(out.length, 1);
  assert.ok(out[0].includes('list.html'));
  assert.ok(out[0].includes('undefined'));
});

test('a warning on a non-entry page is not promoted to a finding', () => {
  // Precision guard: isRuntimeError gates this, same as the entry path. A console warning
  // is not a defect, and a finding list that includes warnings gets ignored wholesale.
  const pages = [
    { url: 'http://x/', entry: true, visited: true },
    { url: 'http://x/a.html', entry: false, visited: true,
      pageErrors: [{ source: 'console', level: 'warning', text: 'deprecated API' }] },
  ];
  assert.deepEqual(buildNonEntryFindings(pages), []);
});

// ---------------------------------------------------------------------------
// #1394 — the sweep's own ceiling can exceed its caller's budget. A sweep that
// is KILLED loses the per-page error text it exists to collect; a sweep that
// STOPS can name what it did not reach.
// ---------------------------------------------------------------------------

test('a page skipped for budget is a finding, and says WHY it was not visited', () => {
  // The distinction matters: a page that 404s is a defect in the deliverable; a page never
  // opened is a bound in the instrument. Both are "not visited" and only one is the coder's.
  const pages = [
    { url: 'http://x/', entry: true, visited: true },
    { url: 'http://x/late.html', entry: false, visited: false, skippedForBudget: true,
      error: 'not attempted — the 90s multi-page sweep budget was exhausted before this page was reached' },
  ];
  const out = buildNonEntryFindings(pages);
  assert.equal(out.length, 1);
  assert.ok(out[0].includes('NOT VISITED'));
  assert.ok(out[0].includes('late.html'), 'the finding must name the page');
  assert.ok(out[0].includes('budget'), 'and must say the instrument stopped, not that the page failed');
});

test('the default sweep budget fits inside the caller EXEC_SMOKE_TIMEOUT_S', () => {
  // THE RECONCILIATION #1394 asks for, asserted rather than left as arithmetic in a comment.
  // The two bounds were set in different files by different changes with nothing checking
  // that one fits inside the other.
  const src = fs.readFileSync(new URL('./capture-web-cdp.mjs', import.meta.url), 'utf8');
  const budget = Number(/sweep-budget-ms'\]\) \|\| (\d+)/.exec(src)[1]);
  const ENTRY_WAIT_MS = 20000;   // capture-web-cdp.mjs, Math.min(timeoutMs, 20000)
  const SETTLE_MS = 1200;
  const CALLER_BUDGET_MS = 120000; // shared/timeout_registry.py EXEC_SMOKE_TIMEOUT_S = 120.0

  const worstCase = ENTRY_WAIT_MS + SETTLE_MS + budget;
  assert.ok(worstCase <= CALLER_BUDGET_MS, (
    `the sweep can run ${worstCase}ms against a ${CALLER_BUDGET_MS}ms caller budget — being `
    + 'killed mid-sweep loses every per-page finding, which is what this budget exists to '
    + 'prevent. Lower the sweep budget or raise EXEC_SMOKE_TIMEOUT_S deliberately, once.'
  ));
  assert.ok(budget >= 60000, `a ${budget}ms sweep budget is too tight to reach B9's six pages`);
});

test('the sweep budget is read from an argument, not hardcoded at the call site', () => {
  // So the containing budget can be lowered in one place if EXEC_SMOKE_TIMEOUT_S ever moves,
  // rather than by hunting a literal through the loop.
  const src = fs.readFileSync(new URL('./capture-web-cdp.mjs', import.meta.url), 'utf8');
  assert.ok(/args\['sweep-budget-ms'\]/.test(src), 'the budget must be overridable');
  assert.ok(/pagesSkippedForBudget/.test(src), 'the count must reach the sidecar');
});

// ---------------------------------------------------------------------------
// DoD row 15 — "the layout survives a phone width". The row names five things a
// delivered site must survive; links landed in #1345 and the console has the CDP
// tier, but a phone-width check did not exist at all.
// ---------------------------------------------------------------------------

test('content wider than the phone viewport is a finding that quotes the overflow', () => {
  const a = assessPhoneWidth({ scrollWidth: 520, innerWidth: 390, culprit: 'div.gallery' });
  assert.equal(a.measured, true);
  assert.equal(a.overflows, true);
  assert.equal(a.overflowPx, 130);
  const f = phoneWidthFinding(a);
  assert.ok(f.includes('130px'), 'the finding must quote the measured overflow, not just assert one');
  assert.ok(f.includes('390px'));
  assert.ok(f.includes('div.gallery'), 'and name the widest element so a human can adjudicate it');
});

test('a layout that fits produces NO finding (the toggle)', () => {
  const a = assessPhoneWidth({ scrollWidth: 390, innerWidth: 390 });
  assert.equal(a.overflows, false);
  assert.equal(phoneWidthFinding(a), '');
});

test('sub-pixel and hairline overflow is NOT convicted', () => {
  // Precision-first: a 1-2px border or a rounding artefact routinely pushes scrollWidth over on
  // layouts that are fine, and a rule that nags about those gets muted — which costs the real
  // findings too. The tolerance is a real number, not zero.
  for (const sw of [391, 393, 398]) {
    const a = assessPhoneWidth({ scrollWidth: sw, innerWidth: 390 });
    assert.equal(a.overflows, false, `${sw}px against a 390px viewport must not convict`);
  }
  // …but a real overflow just past the tolerance still does.
  assert.equal(assessPhoneWidth({ scrollWidth: 399, innerWidth: 390 }).overflows, true);
});

test('an unmeasurable layout is NOT reported as fitting', () => {
  // The three-state discipline: "could not measure" and "measured and it fits" are different
  // answers. An override that will not apply must never render as a pass.
  for (const bad of [null, undefined, {}, { scrollWidth: 'x', innerWidth: 390 }]) {
    const a = assessPhoneWidth(bad);
    assert.equal(a.measured, false, 'an unreadable measurement claims to have measured');
    assert.equal(a.overflows, false);
    assert.equal(phoneWidthFinding(a), '', 'and produces no finding either way');
  }
});

test('the phone pass restores the desktop viewport', () => {
  // The saved PNG and the extra-page sweep must both see the same 1280x900 page a desktop
  // visitor gets; a phone override left applied would silently change what every later stage
  // grades.
  const src = fs.readFileSync(new URL('./capture-web-cdp.mjs', import.meta.url), 'utf8');
  const phoneIdx = src.indexOf('width: 390');
  assert.ok(phoneIdx > 0, 'the phone override must exist');
  const after = src.slice(phoneIdx);
  assert.ok(after.includes('width: 1280'), 'the desktop override must be restored after it');
});

test('the phone finding is ADVISORY — it never reaches computeHard', () => {
  // #1345 precedent: a new way for a build to fail is the operator ceremony, not a wiring
  // decision. computeHard takes console entries, page errors, textScan and behaviorHard —
  // and must not grow a phone-width argument without that ceremony.
  const src = fs.readFileSync(new URL('./capture-web-cdp.mjs', import.meta.url), 'utf8');
  const sig = /export function computeHard\(([^)]*)\)/.exec(src)[1];
  assert.ok(!/phone/i.test(sig), `computeHard grew a phone-width input: ${sig}`);
});

// ---------------------------------------------------------------------------
// DoD row 15 — "navigable by keyboard and screen reader". The narrowest
// defensible slice: three DOM facts a screen-reader or keyboard user cannot
// work around. NOT an accessibility audit; contrast, focus-visible, tab ORDER
// and ARIA correctness are named as out of scope in the function's docstring.
// ---------------------------------------------------------------------------

test('an image with NO alt attribute is a finding', () => {
  const r = assessA11yBasics({ imagesMissingAlt: 2, imgExample: 'bowl.png',
                               unlabelledFields: 0, fieldExample: '', h1Count: 1 });
  assert.equal(r.measured, true);
  assert.equal(r.findings.length, 1);
  assert.ok(r.findings[0].includes('2 image'));
  assert.ok(r.findings[0].includes('bowl.png'), 'name an example so it is adjudicable');
});

test('alt="" is CORRECT and must never be convicted', () => {
  // THE PRECISION TRAP, and the reason the probe uses hasAttribute rather than a truthiness
  // check: an empty alt is the idiomatic marker for a decorative image. A scan that flagged it
  // would punish exactly the deliverables that got it right — the same mistake the prose scan
  // avoids by parsing instead of grepping. A decorative image therefore contributes ZERO to
  // imagesMissingAlt, so a page full of them reports nothing here.
  const r = assessA11yBasics({ imagesMissingAlt: 0, imgExample: '',
                               unlabelledFields: 0, fieldExample: '', h1Count: 1 });
  assert.deepEqual(r.findings, []);
});

test('a form field with no announceable label is a finding', () => {
  const r = assessA11yBasics({ imagesMissingAlt: 0, imgExample: '',
                               unlabelledFields: 3, fieldExample: 'email', h1Count: 1 });
  assert.equal(r.findings.length, 1);
  assert.ok(r.findings[0].includes('3 form field'));
  assert.ok(r.findings[0].includes('email'));
});

test('a page with no <h1> is a finding, and one with an h1 is not', () => {
  assert.equal(assessA11yBasics({ imagesMissingAlt: 0, unlabelledFields: 0, h1Count: 0 })
                 .findings.length, 1);
  assert.deepEqual(assessA11yBasics({ imagesMissingAlt: 0, unlabelledFields: 0, h1Count: 1 })
                     .findings, []);
});

test('a clean page produces NOTHING (the toggle)', () => {
  const r = assessA11yBasics({ imagesMissingAlt: 0, imgExample: '',
                               unlabelledFields: 0, fieldExample: '', h1Count: 2 });
  assert.equal(r.measured, true);
  assert.deepEqual(r.findings, []);
});

test('an unmeasurable page is NOT reported as accessible', () => {
  for (const bad of [null, undefined, {}, { imagesMissingAlt: 'x' }]) {
    const r = assessA11yBasics(bad);
    assert.equal(r.measured, false, 'an unread page claimed to have been read');
    assert.deepEqual(r.findings, []);
  }
});

test('the in-page probe is valid JavaScript', () => {
  // This lock exists because the probe's first draft was NOT. It interpolated an id into a
  // `label[for="..."]` selector, and those double quotes terminated the enclosing string —
  // a malformed page script that would have failed at runtime inside the browser, where the
  // catch would have recorded it as "could not measure" and looked like a quiet degrade.
  // Rewritten to walk `htmlFor`, which also removes an injection surface: an id is untrusted
  // page content and does not belong inside a selector string.
  const src = fs.readFileSync(new URL('./capture-web-cdp.mjs', import.meta.url), 'utf8');
  const m = /assessA11yBasics\(await evalJson\(cdp, \[([\s\S]*?)\]\.join\(''\)\)\)/.exec(src);
  assert.ok(m, 'the probe is no longer assembled as a joined array — update this lock deliberately');
  const probe = eval('[' + m[1] + '].join("")');
  assert.doesNotThrow(() => new Function('return ' + probe), 'the page probe is malformed JS');
  assert.ok(!probe.includes('label[for='), 'an id must not be interpolated into a selector');
});

test('the a11y findings are ADVISORY — computeHard never sees them', () => {
  const src = fs.readFileSync(new URL('./capture-web-cdp.mjs', import.meta.url), 'utf8');
  const sig = /export function computeHard\(([^)]*)\)/.exec(src)[1];
  assert.ok(!/a11y|alt|label/i.test(sig), `computeHard grew an accessibility input: ${sig}`);
});

// ---------------------------------------------------------------------------
// DoD row 15 — "forms submit". The check does NOT submit: submitting is a side
// effect on someone else's software, and a grader that mutates what it grades
// is a worse defect than the one it looks for. It asks whether the form COULD
// be submitted and whether submitting would obviously lose the user's data.
// ---------------------------------------------------------------------------

test('a form with no submit path at all is a finding', () => {
  const r = assessForms({ formCount: 1, noSubmitPath: 1, wouldLoseData: 0,
                          noSubmitExample: 'contact', loseDataExample: '' });
  assert.equal(r.findings.length, 1);
  assert.ok(r.findings[0].includes('contact'));
  assert.ok(r.findings[0].includes('Enter'), 'it must say why a text input would have counted');
});

// UPDATED DELIBERATELY, 2026-08-16 (#1433). This case now has to state `scriptCount: 0`, which
// is the condition that makes the verdict true rather than an assumption it used to smuggle.
test('a form with neither action nor handler is a finding — the data goes nowhere', () => {
  const r = assessForms({ formCount: 1, noSubmitPath: 0, wouldLoseData: 1, scriptCount: 0,
                          noSubmitExample: '', loseDataExample: 'contact-form' });
  assert.equal(r.findings.length, 1);
  assert.ok(r.findings[0].includes('contact-form'));
  assert.ok(r.findings[0].includes('reloads'), 'name the consequence, not just the omission');
  assert.equal(r.loseDataUndecidable, 0);
});

test('#1433 FALSE POSITIVE: a scripted page is never convicted of losing data', () => {
  // THE NEAR-TWIN, and the reason it matters now. `addEventListener('submit', ...)` is the
  // normal way to wire a form and is invisible to this probe. While the check ran on the entry
  // page only this almost never fired; per-page it would fire on nearly every correct JS form.
  // Measured on the delivered pottery site, whose contact form has exactly this shape.
  const r = assessForms({ formCount: 1, noSubmitPath: 0, wouldLoseData: 1, scriptCount: 2,
                          noSubmitExample: '', loseDataExample: 'contactForm' });
  assert.deepEqual(r.findings, [], 'a form that may have a listener must not be convicted');
  assert.equal(r.loseDataUndecidable, 1, 'and "could not tell" must be recorded, not dropped');
  assert.equal(r.measured, true);
});

test('an undecidable form is distinguishable from a clean one', () => {
  const clean = assessForms({ formCount: 1, noSubmitPath: 0, wouldLoseData: 0, scriptCount: 2 });
  const unknown = assessForms({ formCount: 1, noSubmitPath: 0, wouldLoseData: 1, scriptCount: 2 });
  assert.deepEqual(clean.findings, []);
  assert.deepEqual(unknown.findings, []);
  // Both are silent. Only `loseDataUndecidable` separates "fine" from "nothing could tell",
  // which is why it is published rather than kept as a local.
  assert.equal(clean.loseDataUndecidable, 0);
  assert.equal(unknown.loseDataUndecidable, 1);
  assert.notDeepEqual(clean, unknown);
});

test('a missing scriptCount reads as undecidable, not as a conviction', () => {
  // An older probe, or a fixture written before #1433, does not know whether a script exists.
  // Not knowing must never become an accusation.
  const r = assessForms({ formCount: 1, noSubmitPath: 0, wouldLoseData: 1 });
  assert.deepEqual(r.findings, []);
  assert.equal(r.loseDataUndecidable, 1);
});

test('the probe reports scriptCount, or the rule above cannot be decided', () => {
  assert.ok(FORMS_PROBE.includes("querySelectorAll('script').length"),
    'the undecidable guard needs scriptCount from the probe');
});

test('an action-only form and a handler-only form are BOTH fine', () => {
  // Precision-first, and the reason this cannot fire on a correctly-built server-posted form:
  // a plain HTML form with an action needs no JavaScript at all, and a JS form needs no
  // action. Only the PAIR being absent is a defect.
  const r = assessForms({ formCount: 2, noSubmitPath: 0, wouldLoseData: 0 });
  assert.deepEqual(r.findings, []);
  assert.equal(r.formCount, 2);
});

test('a page with no forms produces nothing (the toggle)', () => {
  const r = assessForms({ formCount: 0, noSubmitPath: 0, wouldLoseData: 0 });
  assert.equal(r.measured, true, 'no forms is a MEASURED result, not an unmeasured one');
  assert.deepEqual(r.findings, []);
});

test('an unmeasurable page is not reported as having working forms', () => {
  for (const bad of [null, undefined, {}, { formCount: 'x' }]) {
    const r = assessForms(bad);
    assert.equal(r.measured, false);
    assert.deepEqual(r.findings, []);
  }
});

// UPDATED DELIBERATELY, 2026-08-16 (#1433). This lock used to scrape the probe out of the
// single inline call site with a regex, and its own failure message said to update it when the
// call shape changed. The probe now runs on every swept page, so it is ONE exported constant and
// this lock reads the real thing instead of a copy of its source text — strictly stronger, and
// it can no longer be defeated by the call moving. The safety assertions are unchanged: they are
// the reason a read-only probe is allowed to run five times instead of once.
test('the forms probe is valid JavaScript and submits nothing', () => {
  assert.equal(typeof FORMS_PROBE, 'string');
  assert.ok(FORMS_PROBE.includes("querySelectorAll('form')"), 'this is not the forms probe');
  assert.doesNotThrow(() => new Function('return ' + FORMS_PROBE), 'the forms probe is malformed JS');
  // THE SAFETY LOCK. This check must never acquire a side effect on the graded deliverable.
  for (const forbidden of ['.submit(', '.click(', 'requestSubmit', 'dispatchEvent']) {
    assert.ok(!FORMS_PROBE.includes(forbidden),
      `the forms probe calls ${forbidden} — it must READ the DOM, never act on it`);
  }
});

test('there is exactly ONE forms probe, and every call site uses it', () => {
  // The point of hoisting was to stop two copies drifting apart. If someone re-inlines a probe
  // at a call site, the constant stops being the thing that runs and the lock above stops
  // proving anything about the capture.
  const src = fs.readFileSync(new URL('./capture-web-cdp.mjs', import.meta.url), 'utf8');
  const calls = src.match(/evalJson\(cdp, FORMS_PROBE\)/g) || [];
  assert.equal(calls.length, 2,
    'expected exactly two call sites — the entry page and the sweep. ' + calls.length + ' found');
  assert.ok(!/assessForms\(await evalJson\(cdp, \[/.test(src),
    'a forms probe was re-inlined as an array literal — use FORMS_PROBE');
  // #1434 STRENGTHENS this lock rather than relaxing it. The wiring is now part of what must not
  // drift: if one call site asks the browser about listeners and the other does not, the entry
  // page and the swept pages get adjudicated by DIFFERENT rules — the browser at one and the
  // attributes alone at the other — which is precisely the two-copies-drifting-apart failure
  // this test was written to catch, wearing a different hat.
  const wired = src.match(
    /submitListeners: assessSubmitListeners\(await measureSubmitListeners\(cdp\)/g) || [];
  assert.equal(wired.length, 2,
    'both forms call sites must supply the #1434 listener decision. ' + wired.length + ' found');
  // #1434 REVIEW FIX, locked: both call sites must ALSO pass the expected count (wouldLoseData),
  // or an undercounted listener census reads as a confident clean pass at whichever site forgot.
  const counted = src.match(/measureSubmitListeners\(cdp\),\s*fm2?\.wouldLoseData\)/g) || [];
  assert.equal(counted.length, 2,
    'both call sites must pass the expected form count. ' + counted.length + ' found');
});

// ---------------------------------------------------------------------------
// DoD row 15 — #1433. The forms answer is now aggregated across the pages the
// sweep actually visited. The defect being retired: the check ran on the entry
// page only, and its `formCount: 0` was published top-level, so a site whose
// form lives on contact.html reported as a site with no forms.
//
// The whole value of this aggregate is that it counts only pages that were
// CHECKED. Every test below is about that denominator.
// ---------------------------------------------------------------------------

test('#1433 REGRESSION: a form on a non-entry page is counted', () => {
  // This is the exact shape of run 20260816-134142-bd: entry page clean, contact page carries
  // the real form. Before the fix this aggregate did not exist and the answer was 0.
  const r = aggregateForms([
    { entry: true, url: 'http://x/', forms: { measured: true, formCount: 0, findings: [] } },
    { entry: false, url: 'http://x/contact.html', forms: { measured: true, formCount: 1, findings: [] } },
    { entry: false, url: 'http://x/pieces.html', forms: { measured: true, formCount: 0, findings: [] } },
  ]);
  assert.equal(r.measured, true);
  assert.equal(r.formCount, 1, 'the contact page form must reach the total');
  assert.equal(r.pagesChecked, 3);
  assert.equal(r.pagesWithForms, 1);
});

test('an unchecked site and a site with no forms do not read the same', () => {
  const nothingChecked = aggregateForms([
    { entry: true, url: 'http://x/', forms: { measured: false, findings: [] } }, // probe threw
    { entry: false, url: 'http://x/a.html', visited: false },                    // never opened
  ]);
  assert.equal(nothingChecked.measured, false, 'no page checked is NOT a measured zero');
  assert.equal(nothingChecked.pagesChecked, 0);

  const checkedAndEmpty = aggregateForms([
    { entry: true, url: 'http://x/', forms: { measured: true, formCount: 0, findings: [] } },
  ]);
  assert.equal(checkedAndEmpty.measured, true);
  assert.equal(checkedAndEmpty.formCount, 0);
  assert.equal(checkedAndEmpty.pagesChecked, 1);
  // The two must be distinguishable, which is the entire point of publishing pagesChecked.
  assert.notDeepEqual(nothingChecked, checkedAndEmpty);
});

test('a page SKIPPED FOR BUDGET is never counted as checked', () => {
  // #1394's budget stop must not become coverage. A truncated sweep reports less coverage,
  // never the same coverage with fewer forms.
  //
  // BOTH shapes are asserted deliberately. Toggle-proving this on 2026-08-16 showed the
  // no-`forms`-key version alone stays green even with the `measured !== true` guard deleted,
  // because it is really exercising the absence check. A skipped page that a later refactor
  // initialises to `{measured: false}` is the case that guard exists for, so it is pinned here
  // rather than assumed — a lock that goes green for a weaker reason than it claims is the
  // defect this file keeps finding in everything else.
  for (const skipped of [
    { entry: false, url: 'http://x/contact.html', visited: false, skippedForBudget: true },
    { entry: false, url: 'http://x/contact.html', visited: false, skippedForBudget: true,
      forms: { measured: false, findings: [] } },
  ]) {
    const r = aggregateForms([
      { entry: true, url: 'http://x/', forms: { measured: true, formCount: 0, findings: [] } },
      skipped,
    ]);
    assert.equal(r.pagesChecked, 1, 'the skipped page must not inflate the denominator');
    assert.equal(r.formCount, 0);
  }
});

test('a page whose probe failed is not counted, and cannot fake a zero', () => {
  for (const bad of [undefined, null, {}, { measured: false, findings: [] },
                     { measured: true, formCount: 'x' }]) {
    const r = aggregateForms([
      { entry: true, url: 'http://x/', forms: { measured: true, formCount: 0, findings: [] } },
      { entry: false, url: 'http://x/b.html', visited: true, forms: bad },
    ]);
    assert.equal(r.pagesChecked, 1, `an unmeasured page was counted: ${JSON.stringify(bad)}`);
  }
});

test('findings carry the page they came from, and the marker survives truncation', () => {
  const long = 'z'.repeat(600);
  const r = aggregateForms([
    { entry: true, url: 'http://x/', forms: { measured: true, formCount: 1, findings: ['entry defect'] } },
    { entry: false,
      url: 'http://x/contact.html',
      forms: { measured: true, formCount: 1, findings: ['1 form(s) have neither an action' + long] } },
  ]);
  assert.equal(r.findings.length, 2);
  assert.ok(!r.findings[0].includes('[page:'), 'the entry page needs no page marker');
  assert.ok(r.findings[1].includes('[page: http://x/contact.html]'),
    'a finding a reader cannot locate is one they cannot act on');
  // The marker is placed FIRST precisely so the cap truncates the message, not the attribution.
  assert.ok(r.findings[1].indexOf('[page:') < 40);
});

test('an empty or absent page list is unmeasured, not clean (the toggle)', () => {
  for (const empty of [[], null, undefined]) {
    const r = aggregateForms(empty);
    assert.equal(r.measured, false);
    assert.equal(r.pagesChecked, 0);
    assert.deepEqual(r.findings, []);
  }
});

test('the forms findings are ADVISORY — computeHard never sees them', () => {
  const src = fs.readFileSync(new URL('./capture-web-cdp.mjs', import.meta.url), 'utf8');
  const sig = /export function computeHard\(([^)]*)\)/.exec(src)[1];
  assert.ok(!/form/i.test(sig), `computeHard grew a forms input: ${sig}`);
});

// ---------------------------------------------------------------------------
// DoD row 15 — #1435. The DESKTOP half of "the layout survives a width".
//
// The defect: delivered pages with no width constraint, so every heading and
// paragraph began at pixel zero and ran the full width of the operator's
// monitor. His verdict was "not good".
//
// The phone check passed and was structurally incapable of failing: it asks
// whether content is WIDER than the viewport, and unconstrained content at
// 390px is not wider than 390px.
//
// TWO decisions carry this check, and the fixtures below are chosen to break it
// if either is undone:
//   1. It measures WHERE THE GLYPHS ARE (Range line boxes), not where the
//      element box is. A centred heading in a full-bleed band spans the window
//      and its text sits in the middle; a left-aligned heading with no wrapper
//      spans the window and its text starts at zero. The box reports those
//      identically.
//   2. It measures at a viewport WIDER than the 1280 screenshot. At 1280 a
//      correct `max-width: 1200px` container and a missing one measured 33px
//      and 32px apart on the real deliveries — indistinguishable.
//
// Every number labelled MEASURED was read off the banked deliveries by running
// this capture against them, not invented for the test.
//
// A NOTE ON THE SOURCE-READING LOCKS BELOW, earned three times over while
// toggle-proving this section on 2026-08-17. A lock that asserts a TOKEN is
// present proves less than it reads as proving, because the token survives the
// change that breaks the behaviour:
//   * `paddingLeft` stayed in the probe while the arithmetic reverted to the
//     border box;
//   * `rule.cssRules` stayed in the probe while its guard became `if(false)`;
//   * `width: 1280` stayed in the finally while a second wide override was
//     appended after it.
// All three were GREEN against a real sabotage. Each is now pinned on the
// expression or the ORDER rather than the name. Any lock added here must be
// toggle-proved the same way before it is trusted.
// ---------------------------------------------------------------------------

const blk = (gutterPx, chars, tag = 'p', undefinedClasses = []) =>
  ({ tag, chars, gutterPx, undefinedClasses });
const page = (blocks, viewportPx = 1585, stylesheetsRead = 1) =>
  ({ viewportPx, blocks, stylesheetsRead });

// MEASURED — 20260816-210245 home.html at 1585px. `.hero`, `.intro-content` and
// `.intro-card` are applied by the HTML and defined by no rule in styles.css,
// which defines `.container` and never uses it.
const UNWRAPPED_HOME = page([
  blk(0, 29, 'h1', ['hero']), blk(0, 141, 'p', ['hero']),
  blk(676, 16, 'h2'),
  blk(0, 14, 'h3', ['intro-card', 'intro-content']), blk(0, 145, 'p', ['intro-card', 'intro-content']),
  blk(0, 19, 'h3', ['intro-card', 'intro-content']), blk(0, 143, 'p', ['intro-card', 'intro-content']),
  blk(0, 21, 'h3', ['intro-card', 'intro-content']), blk(0, 130, 'p', ['intro-card', 'intro-content']),
  blk(672, 17, 'h2'), blk(323, 11, 'h3'), blk(209, 43), blk(738, 11, 'h3'),
  blk(617, 43), blk(338, 11, 'h3'), blk(264, 43),
]);

// MEASURED — 20260816-070923 home.html at 1585px. THE TRUE NEGATIVE: the same
// site, the same five pages, fourteen hours earlier, with the container
// applied. Its nearest text to the window edge is 209px away.
const WRAPPED_HOME = page([
  blk(498, 29, 'h1'), blk(481, 71), blk(225, 16, 'h2'), blk(225, 160),
  blk(225, 157), blk(225, 176), blk(209, 18, 'h3'), blk(209, 39),
  blk(619, 19, 'h3'), blk(619, 31), blk(417, 15, 'h3'), blk(341, 31),
]);

// MEASURED — 20260817-070902, the delivery that is wrapped on SOME pages. These
// two are the per-page split, from ONE run.
//   contact.html: `.contact-container` is defined -> a neat centred card.
//   pieces.html:  `.page-container` is applied and defined NOWHERE -> the page
//                 title runs flush to the left edge while the card grid below
//                 it is laid out correctly.
const MIXED_CONTACT = page([blk(711, 10, 'h1'), blk(615, 48)], 1585);
const MIXED_GALLERY = page([
  blk(0, 18, 'h1', ['page-header', 'page-container']),
  blk(0, 34, 'p', ['page-header', 'page-container']),
  blk(85, 11, 'h3', ['page-container']), blk(36, 42, 'p', ['page-container']),
  blk(351, 11, 'h3', ['page-container']), blk(301, 39, 'p', ['page-container']),
  blk(609, 10, 'h3', ['page-container']), blk(576, 33, 'p', ['page-container']),
  blk(619, 10, 'h3', ['page-container']), blk(563, 31, 'p', ['page-container']),
  blk(351, 11, 'h3', ['page-container']), blk(298, 31, 'p', ['page-container']),
  blk(65, 15, 'h3', ['page-container']), blk(49, 38, 'p', ['page-container']),
], 1600);

// MEASURED — 20260817-070902 home.html at 1585px. THE CENTRED-HEADING NEAR-TWIN.
// Its two `.section-header` elements are `text-align: center` inside full-bleed
// sections: their BOXES touch both window edges and measured gutter 0 when this
// check read boxes at 1280. Their glyphs are 690px from the edge.
const MIXED_HOME = page([
  blk(498, 29, 'h1'), blk(562, 52), blk(693, 16, 'h2.section-header'),
  blk(40, 9, 'h3'), blk(40, 184), blk(568, 11, 'h3'), blk(568, 173),
  blk(343, 14, 'h3'), blk(50, 167), blk(690, 17, 'h2.section-header'),
  blk(198, 15, 'h3'), blk(128, 42), blk(725, 14, 'h3'), blk(659, 41),
  blk(200, 15, 'h3'), blk(149, 37),
]);

// MEASURED — 20260816-210245 contact.html at 1600px. The thinnest page that is
// still unmistakably the defect: three blocks, all flush against the edge.
const UNWRAPPED_CONTACT = page([
  blk(0, 10, 'h1', ['contact-header', 'contact-container']),
  blk(0, 102, 'p', ['contact-header', 'contact-container']),
  blk(0, 36, 'p', ['form-footer', 'contact-container']),
], 1600);

test('#1435 REGRESSION: the unwrapped delivery is convicted', () => {
  const r = assessContentWidth(UNWRAPPED_HOME);
  assert.equal(r.measured, true);
  assert.equal(r.judgeable, true);
  assert.equal(r.unconstrained, true, 'the page the operator called "not good" must be reported');
  assert.equal(r.edgeBlocks, 8);
  assert.equal(r.blocksMeasured, 16);
  assert.equal(r.minGutterPx, 0);
  assert.equal(r.findings.length, 1);
});

test('#1435 TRUE NEGATIVE: the wrapped delivery of the same site is NOT convicted', () => {
  // A check that flags both is worthless. This decides whether the rule measures the container
  // or measures pottery websites.
  const r = assessContentWidth(WRAPPED_HOME);
  assert.equal(r.measured, true);
  assert.equal(r.judgeable, true, 'the page has plenty of body text — it IS judgeable');
  assert.equal(r.unconstrained, false, 'a correctly wrapped page was convicted');
  assert.equal(r.edgeBlocks, 0, 'nothing on a wrapped page comes near the window edge');
  assert.deepEqual(r.findings, []);
  // NULL, not 0. "No block came near the edge" and "a block sits 0px from the edge" are opposite
  // facts, and a zero here would state the second on every page that is fine.
  assert.equal(r.minGutterPx, null, 'a clean page reports 0px from the edge');
  assert.equal(assessContentWidth(UNWRAPPED_HOME).minGutterPx, 0);
});

test('#1435 the finding reads as English for one class and for several', () => {
  const one = assessContentWidth({ viewportPx: 1600, stylesheetsRead: 1, blocks: [
    blk(0, 30, 'h1', ['page-container']), blk(0, 40, 'p', ['page-container'])] });
  assert.ok(one.findings[0].includes('The wrapper class "page-container" is applied'), one.findings[0]);
  assert.ok(one.findings[0].includes('so it constrains nothing'));
  const two = assessContentWidth(MIXED_GALLERY);
  assert.ok(two.findings[0].includes('The wrapper classes "page-header", "page-container" are applied'),
    two.findings[0]);
  assert.ok(two.findings[0].includes('so they constrain nothing'));
});

test('#1435 THE PER-PAGE SPLIT: one delivery, contact clean and gallery flagged', () => {
  // THE BAR. A delivery is not uniformly wrapped or unwrapped. `20260817-070902` renders its
  // contact page as a neat centred card and its gallery page flush to the left edge, because
  // `.contact-container` is defined and `.page-container` is applied and defined nowhere. A
  // whole-site verdict would hide one behind the other. If this check cannot produce the split
  // it is measuring the wrong thing.
  const contact = assessContentWidth(MIXED_CONTACT);
  const gallery = assessContentWidth(MIXED_GALLERY);
  assert.equal(contact.unconstrained, false, 'the wrapped contact page must pass');
  assert.equal(gallery.unconstrained, true, 'the unwrapped gallery page must fail');

  // …and the SAME RUN must report both, per page, without a site-level verdict either way.
  const agg = aggregateContentWidth([
    { entry: true, url: 'http://x/', contentWidth: assessContentWidth(MIXED_HOME) },
    { entry: false, url: 'http://x/pieces.html', contentWidth: gallery },
    { entry: false, url: 'http://x/contact.html', contentWidth: contact },
  ]);
  assert.equal(agg.pagesChecked, 3);
  assert.equal(agg.pagesUnconstrained, 1, 'exactly one of these three pages is broken');
  assert.equal(agg.findings.length, 1);
  assert.ok(agg.findings[0].includes('/pieces.html'), 'the finding must name the broken page');
  // No site-wide boolean anywhere in the aggregate: counts only.
  for (const [k, v] of Object.entries(agg)) {
    if (k === 'measured') continue;
    assert.notEqual(typeof v, 'boolean', `the aggregate grew a site-level verdict: ${k}`);
  }
});

test('#1435 NEAR-TWIN: a centred heading in a full-bleed band is NOT convicted', () => {
  // The near-twin that motivated measuring glyphs. `20260817-070902`'s two `.section-header`
  // elements are text-align:center inside full-bleed sections. Their BOXES touch both window
  // edges — this check read them as gutter 0 when it measured boxes — and their glyphs are
  // 690px from the edge. The page is correct and must stay silent.
  const r = assessContentWidth(MIXED_HOME);
  assert.equal(r.judgeable, true);
  assert.equal(r.unconstrained, false, 'a centred full-bleed heading was convicted');
  assert.equal(r.edgeBlocks, 0);
  assert.deepEqual(r.findings, []);
});

test('#1435 THE POINT: the phone check cannot tell any of these apart', () => {
  // The reason this rule exists. No page here overflows a phone viewport — unconstrained content
  // at 390px is not wider than 390px — so `assessPhoneWidth` returns an IDENTICAL verdict for a
  // broken page and a fine one. That is the sidecar line the delivered run actually banked:
  // {measured:true, overflows:false, overflowPx:0, widthPx:390}.
  const phone = assessPhoneWidth({ scrollWidth: 390, innerWidth: 390 });
  assert.equal(phone.overflows, false);
  assert.equal(phoneWidthFinding(phone), '');
  assert.deepEqual(phone, assessPhoneWidth({ scrollWidth: 390, innerWidth: 390 }));
  // …while this check separates them. If that stops being true it has stopped closing the gap.
  assert.notEqual(assessContentWidth(UNWRAPPED_HOME).unconstrained,
                  assessContentWidth(WRAPPED_HOME).unconstrained);
  assert.notEqual(assessContentWidth(MIXED_GALLERY).unconstrained,
                  assessContentWidth(MIXED_CONTACT).unconstrained);
});

test('#1435 the thinnest real defect page still speaks', () => {
  const r = assessContentWidth(UNWRAPPED_CONTACT);
  assert.equal(r.judgeable, true);
  assert.equal(r.unconstrained, true);
  assert.equal(r.edgeChars, 148);
});

test('#1435 ONE block at the edge is never a verdict', () => {
  // A pull-quote, a breadcrumb, a full-bleed caption. One element against the edge is a design
  // choice; two carrying real words is a page with nothing holding its content in.
  const one = assessContentWidth(page([blk(0, 400, 'p.pull-quote'), blk(200, 300), blk(200, 300)]));
  assert.equal(one.edgeBlocks, 1);
  assert.equal(one.unconstrained, false);
  assert.deepEqual(one.findings, []);
  // Two blocks that are only labels do not convict either — the words have to be real.
  const tiny = assessContentWidth(page([blk(0, 9, 'h3'), blk(0, 9, 'h3'), blk(300, 400)]));
  assert.equal(tiny.edgeBlocks, 2);
  assert.equal(tiny.unconstrained, false, '18 characters is not a page running edge-to-edge');
  // …and two blocks carrying real words do.
  assert.equal(assessContentWidth(page([blk(0, 30, 'h1'), blk(0, 40), blk(300, 400)])).unconstrained,
    true);
});

test('#1435 the gutter tolerance is a real number, and it bites at the stated value', () => {
  const at = (g) => assessContentWidth(page([blk(g, 200), blk(g, 200), blk(400, 200)]));
  assert.equal(at(24).unconstrained, true, '24px of clear space is not a page container');
  assert.equal(at(25).unconstrained, false, 'past the tolerance the page is left alone');
  assert.equal(at(36).unconstrained, false, 'the nearest CORRECT card text measured 36px');
  // The tolerance is a parameter, so a caller can widen it without editing the rule.
  assert.equal(assessContentWidth(page([blk(40, 200), blk(40, 200)]), 48).unconstrained, true);
});

test('#1435 THE VERDICT NEVER COMES FROM CLASS NAMES', () => {
  // The delivery uses `container`, `page-container`, `max-width-container`, `contact-container`,
  // `header-container` and `hero-content`, and only some are defined. A name-matching rule would
  // have read `page-container` as a success. So a page whose text is properly inset is CLEAN
  // however many undefined wrapper classes its ancestors carry — geometry decides, names only
  // explain.
  const insetButOddlyNamed = page([
    blk(300, 200, 'p', ['page-container', 'max-width-container']),
    blk(300, 200, 'p', ['page-container']),
    blk(300, 200, 'p', ['page-container']),
  ]);
  const r = assessContentWidth(insetButOddlyNamed);
  assert.equal(r.unconstrained, false, 'a class name produced a verdict');
  assert.deepEqual(r.findings, []);
  assert.deepEqual(r.undefinedClasses, [], 'undefined classes are only reported for edge blocks');
});

test('#1435 an undefined wrapper class is named as the CAUSE, once the geometry convicts', () => {
  // The sharpest form of this defect: a class applied in the HTML that the stylesheet never
  // defines. Every file looks correct in isolation and the page has no container at all.
  const r = assessContentWidth(MIXED_GALLERY);
  assert.equal(r.unconstrained, true);
  assert.ok(r.undefinedClasses.includes('page-container'));
  assert.ok(r.findings[0].includes('page-container'),
    'the finding must name the wrapper that constrains nothing');
  assert.ok(/defined in no stylesheet/.test(r.findings[0]));
});

test('#1435 an unreadable stylesheet is NOT an accusation', () => {
  // A cross-origin sheet cannot be enumerated. "I could not read the CSS" must never be
  // published as "the class is undefined" — the same three-state discipline as everything else.
  const noSheets = assessContentWidth({
    viewportPx: 1600, stylesheetsRead: 0,
    blocks: [blk(0, 30, 'h1', ['page-container']), blk(0, 40, 'p', ['page-container'])],
  });
  assert.equal(noSheets.unconstrained, true, 'the geometry verdict does not depend on the CSS');
  assert.deepEqual(noSheets.undefinedClasses, [], 'a class was accused with no stylesheet read');
  assert.ok(!/defined in no stylesheet/.test(noSheets.findings[0]),
    'the finding claimed a class was undefined without reading a stylesheet');
});

test('#1435 a page with no body text is JUDGEABLE=false, not clean', () => {
  const r = assessContentWidth(page([]));
  assert.equal(r.measured, true, 'the page WAS looked at');
  assert.equal(r.judgeable, false, 'and there was no body text to judge');
  assert.equal(r.unconstrained, false);
  assert.deepEqual(r.findings, []);
  assert.notEqual(r.judgeable, assessContentWidth(WRAPPED_HOME).judgeable);
});

test('#1435 an unmeasurable page is NOT reported as well laid out', () => {
  for (const bad of [null, undefined, {}, { viewportPx: 1600 },
                     { viewportPx: 0, blocks: [] }, { viewportPx: 'x', blocks: [] },
                     { viewportPx: 1600, blocks: 'nope' }]) {
    const r = assessContentWidth(bad);
    assert.equal(r.measured, false,
      'an unreadable measurement claimed to have measured: ' + JSON.stringify(bad));
    assert.equal(r.judgeable, false);
    assert.equal(r.unconstrained, false);
    assert.deepEqual(r.findings, []);
  }
});

test('#1435 a garbage block is skipped, not counted as inset', () => {
  // A block whose gutter did not read must not quietly become a wide-gutter block — that would
  // be a silent fail-open on the denominator.
  const r = assessContentWidth(page([blk(0, 200), blk(0, 200), null, { chars: 5000 },
                                     { tag: 'p', chars: 5000, gutterPx: 'x' }]));
  assert.equal(r.blocksMeasured, 2, 'unreadable blocks were counted');
  assert.equal(r.textChars, 400, 'and their characters must not reach the denominator either');
  assert.equal(r.unconstrained, true);
});

test('#1435 the finding quotes the numbers a human needs to adjudicate it', () => {
  const f = assessContentWidth(UNWRAPPED_HOME).findings[0];
  assert.ok(f.includes('1585px'), 'the width it was measured at');
  assert.ok(f.includes('8 of 16'), 'the count');
  assert.ok(f.includes('within 0px'), 'how close to the edge');
  assert.ok(/Headers, navs, footers and fixed banners were excluded/.test(f),
    'it must say what it did NOT count, or a coder will "fix" the nav');
  assert.ok(/Advisory: a padded left-aligned hero or sidebar may false-positive/.test(f),
    'and that the padded-hero / sidebar shape is a known over-report');
  // It must FIT. A message the cap truncates mid-sentence loses the exclusion clause above,
  // which is the half that stops a coder from "fixing" correct design.
  assert.ok(f.endsWith('contentWidth.cannotSee).'), 'the finding is being truncated: ' + f.slice(-40));
});

test('#1435 the example points at text a human can find on the screenshot', () => {
  const r = assessContentWidth({ viewportPx: 1600, stylesheetsRead: 1, blocks: [
    { tag: 'h1', chars: 20, gutterPx: 0, text: 'Our Ceramic Pieces', undefinedClasses: [] },
    { tag: 'p', chars: 141, gutterPx: 0, text: 'Discover the beauty of handcrafted cerami',
      undefinedClasses: [] },
  ] });
  assert.ok(r.example.startsWith('p '), 'the tag must still lead');
  assert.ok(r.example.includes('Discover the beauty'),
    'the example must quote the widest-read block, not the first');
  assert.ok(r.findings[0].includes('Discover the beauty'));
  const noText = assessContentWidth(page([blk(0, 200), blk(0, 200)]));
  assert.equal(noText.example, 'p');
  assert.ok(noText.findings[0].includes('(e.g. p)'));
});

// --- the probe ---------------------------------------------------------------

test('#1435 the probe is valid JavaScript and touches nothing', () => {
  assert.equal(typeof CONTENT_WIDTH_PROBE, 'string');
  assert.doesNotThrow(() => new Function('return ' + CONTENT_WIDTH_PROBE),
    'the content-width probe is malformed JS');
  // THE SAFETY LOCK, same standing as the forms probe's: this runs on every swept page and must
  // never acquire a side effect on the deliverable it grades. `.style.` rather than `.style`,
  // because `document.styleSheets` is a READ this probe legitimately makes.
  for (const forbidden of ['.click(', '.submit(', 'dispatchEvent', 'requestSubmit',
                           '.style.', '.style=', 'innerHTML', 'setAttribute', 'getSelection']) {
    assert.ok(!CONTENT_WIDTH_PROBE.includes(forbidden),
      'the content-width probe calls ' + forbidden + ' — it must READ the layout, never change it');
  }
});

test('#1435 the probe measures GLYPHS, not the element box', () => {
  // Decision 1 of the two this check rests on. A centred heading in a full-bleed band has a box
  // touching both window edges and text nowhere near them; reading the box convicts it. Measured
  // on 20260817-070902: its `.section-header` elements read gutter 0 by box and 690 by glyph.
  assert.ok(CONTENT_WIDTH_PROBE.includes('createRange'),
    'the glyph measurement is gone — the probe is back to reading element boxes');
  assert.ok(CONTENT_WIDTH_PROBE.includes('selectNodeContents'));
  assert.ok(CONTENT_WIDTH_PROBE.includes('getClientRects'));
  // The NEAREST edge, not both: a short left-aligned title at x=0 has a huge right-hand gutter
  // and is still flush against the window.
  assert.ok(CONTENT_WIDTH_PROBE.includes('Math.min(lo, vw-hi)'),
    'the gutter is no longer the distance to the nearest window edge');
  // clientWidth, not innerWidth: a scrollbar makes them differ by ~15px, which would read as a
  // phantom right-hand gutter on every page long enough to scroll.
  assert.ok(CONTENT_WIDTH_PROBE.includes('clientWidth'));
  // Text LEAVES only, so an <li> wrapping a <p> cannot be counted twice.
  assert.ok(CONTENT_WIDTH_PROBE.includes('el.querySelector(sel)'));
});

test('#1435 the probe excludes page chrome, or it convicts every correct site', () => {
  for (const tag of ['header', 'nav', 'footer',
                     '[role=banner]', '[role=navigation]', '[role=contentinfo]']) {
    assert.ok(CONTENT_WIDTH_PROBE.includes(tag), 'page chrome is no longer excluded: ' + tag);
  }
  assert.ok(CONTENT_WIDTH_PROBE.includes('closest('),
    'the exclusion must walk ancestors — a paragraph INSIDE a footer is footer text');
});

test('#1435 the probe walks grouping rules when collecting defined classes', () => {
  // A class defined only inside an @media breakpoint is DEFINED. Without the recursion it would
  // be reported as a wrapper the stylesheet never defines — an accusation about correct CSS.
  // The RECURSION, not merely the name. Toggle-proving this on 2026-08-17 showed the guard
  // could be changed to `if(false)` with the substring `rule.cssRules` still present and nothing
  // going red — the same weak-lock shape this file keeps finding: pinning an input rather than
  // the thing that uses it.
  assert.ok(CONTENT_WIDTH_PROBE.includes('if(rule.cssRules)walk(rule.cssRules);'),
    '@media / @supports blocks are no longer walked — a class defined only inside a breakpoint '
    + 'would be reported as one the stylesheet never defines');
  assert.ok(CONTENT_WIDTH_PROBE.includes('sheetsRead'),
    'the probe must report how many stylesheets it could read, or the claim is ungated');
});

test('#1435 measured at a viewport wide enough to separate a container from none', () => {
  // Decision 2. At 1280 a correct `max-width: 1200px` container and a missing container measured
  // 33px and 32px apart on the real deliveries. The measurement has to happen where they differ.
  const src = fs.readFileSync(new URL('./capture-web-cdp.mjs', import.meta.url), 'utf8');
  const m = /const CONTENT_WIDTH_VIEWPORT_PX = (\d+);/.exec(src);
  assert.ok(m, 'the measurement viewport constant is gone');
  assert.ok(Number(m[1]) >= 1440,
    `measuring at ${m[1]}px cannot separate a 1200px container from no container`);
  assert.ok(/width: CONTENT_WIDTH_VIEWPORT_PX/.test(src),
    'the override no longer uses the constant');
});

test('#1435 the wide override is restored even when the probe throws', () => {
  // A width override left applied would silently change the screenshot, the design critic's
  // input, the phone pass and every page swept afterwards. `finally`, not "after the call".
  const src = fs.readFileSync(new URL('./capture-web-cdp.mjs', import.meta.url), 'utf8');
  const fn = /async function measureContentWidth[\s\S]*?\n}/.exec(src);
  assert.ok(fn, 'measureContentWidth is gone');
  assert.ok(/\}\s*finally\s*\{/.test(fn[0]), 'the restore is no longer in a finally block');
  const finallyBody = fn[0].slice(fn[0].search(/\}\s*finally\s*\{/));
  assert.ok(finallyBody.includes('width: 1280'), 'the 1280x900 viewport is not restored');
  // The 1280 override must be the LAST one the helper performs. Toggle-proving this on
  // 2026-08-17 showed a second wide override appended after the restore leaves the page at 1600
  // while this lock still found its `width: 1280` and stayed green — presence is not order.
  assert.ok(finallyBody.lastIndexOf('width: 1280')
            > finallyBody.lastIndexOf('CONTENT_WIDTH_VIEWPORT_PX'),
    'the wide viewport is re-applied after the restore — every later stage would grade it');
});

test('#1435 the desktop measurement happens BEFORE the phone override AND before the smoke click', () => {
  // Measured after the 390px override it would ask the same blind question the phone check
  // already asks (the #1241 shape). Measured after the heuristic click it describes whatever
  // page the click navigated to; the browser-driven lock below proves the behaviour, this pins
  // the order.
  const src = fs.readFileSync(new URL('./capture-web-cdp.mjs', import.meta.url), 'utf8');
  const entryProbe = src.indexOf('entryContentWidth = assessContentWidth');
  const phoneOverride = src.indexOf('width: 390');
  const clickCall = src.indexOf('evalJson(cdp, clickJs(');
  assert.ok(entryProbe > 0 && phoneOverride > 0 && clickCall > 0);
  assert.ok(entryProbe < phoneOverride, 'the desktop width is being measured at the phone viewport');
  assert.ok(entryProbe < clickCall, 'the entry width is measured AFTER the smoke click, which may navigate');
});

test('#1435 there is exactly ONE content-width probe, and every call site uses it', () => {
  const src = fs.readFileSync(new URL('./capture-web-cdp.mjs', import.meta.url), 'utf8');
  const calls = src.match(/assessContentWidth\(await measureContentWidth\(cdp, settleMs\)\)/g) || [];
  assert.equal(calls.length, 2,
    'expected exactly two call sites — the entry page and the sweep. ' + calls.length + ' found');
  const probeUses = src.match(/evalJson\(cdp, CONTENT_WIDTH_PROBE\)/g) || [];
  assert.equal(probeUses.length, 1,
    'the probe must be evaluated in ONE place, inside measureContentWidth, or a call site can '
    + 'measure at the wrong viewport');
});

// --- the aggregate: counts, never a site-wide verdict -------------------------

test('#1435 the aggregate counts only pages that were actually checked', () => {
  const r = aggregateContentWidth([
    { entry: true, url: 'http://x/', contentWidth: assessContentWidth(WRAPPED_HOME) },
    { entry: false, url: 'http://x/a.html', contentWidth: assessContentWidth(UNWRAPPED_HOME) },
    { entry: false, url: 'http://x/empty.html', contentWidth: assessContentWidth(page([])) },
  ]);
  assert.equal(r.measured, true);
  assert.equal(r.pagesChecked, 3);
  assert.equal(r.pagesJudged, 2, 'the page with no body text was checked but could not be judged');
  assert.equal(r.pagesUnconstrained, 1);
  assert.equal(r.findings.length, 1);
});

test('#1435 an unchecked site and a well-laid-out site do not read the same', () => {
  const nothingChecked = aggregateContentWidth([
    { entry: true, url: 'http://x/', contentWidth: { measured: false, findings: [] } },
    { entry: false, url: 'http://x/a.html', visited: false },
  ]);
  assert.equal(nothingChecked.measured, false, 'no page checked is NOT a measured pass');
  assert.equal(nothingChecked.pagesChecked, 0);

  const checkedAndClean = aggregateContentWidth([
    { entry: true, url: 'http://x/', contentWidth: assessContentWidth(WRAPPED_HOME) },
  ]);
  assert.equal(checkedAndClean.measured, true);
  assert.equal(checkedAndClean.pagesChecked, 1);
  assert.equal(checkedAndClean.pagesUnconstrained, 0);
  assert.notDeepEqual(nothingChecked, checkedAndClean);
});

test('#1435 a page SKIPPED FOR BUDGET never inflates the denominator', () => {
  // Both shapes, for the reason #1433 spelled out: the no-key version alone goes green even with
  // the `measured !== true` guard deleted, so it proves less than it looks like it does.
  for (const skipped of [
    { entry: false, url: 'http://x/c.html', visited: false, skippedForBudget: true },
    { entry: false, url: 'http://x/c.html', visited: false, skippedForBudget: true,
      contentWidth: { measured: false, judgeable: false, unconstrained: false, findings: [] } },
  ]) {
    const r = aggregateContentWidth([
      { entry: true, url: 'http://x/', contentWidth: assessContentWidth(WRAPPED_HOME) },
      skipped,
    ]);
    assert.equal(r.pagesChecked, 1, 'a page that was never opened was counted as checked');
    assert.equal(r.pagesUnconstrained, 0);
  }
});

test('#1435 findings carry their page, and the marker survives truncation', () => {
  const r = aggregateContentWidth([
    { entry: true, url: 'http://x/', contentWidth: assessContentWidth(UNWRAPPED_HOME) },
    { entry: false, url: 'http://x/contact.html', contentWidth: assessContentWidth(UNWRAPPED_CONTACT) },
  ]);
  assert.equal(r.findings.length, 2);
  assert.ok(!r.findings[0].includes('[page:'), 'the entry page needs no marker');
  assert.ok(r.findings[1].includes('[page: http://x/contact.html]'),
    'a finding a reader cannot locate is one they cannot act on');
  assert.ok(r.findings[1].indexOf('[page:') < 40,
    'the cap must truncate the message, not the attribution');
});

test('#1435 an empty or absent page list is unmeasured, not clean (the toggle)', () => {
  for (const empty of [[], null, undefined]) {
    const r = aggregateContentWidth(empty);
    assert.equal(r.measured, false);
    assert.equal(r.pagesChecked, 0);
    assert.equal(r.pagesJudged, 0);
    assert.deepEqual(r.findings, []);
  }
});

test('#1435 the content-width finding is ADVISORY — computeHard never sees it', () => {
  // The operator was asked directly on 2026-08-16 whether "the page has no margins" should fail
  // a build or just be reported. His answer: "probably just reported." Promoting it to blocking
  // is a new way for a build to fail, which is his ceremony and not a wiring decision (#1345).
  const src = fs.readFileSync(new URL('./capture-web-cdp.mjs', import.meta.url), 'utf8');
  const sig = /export function computeHard\(([^)]*)\)/.exec(src)[1];
  assert.ok(!/width|container|layout|gutter|edge/i.test(sig),
    'computeHard grew a content-width input: ' + sig);
  assert.ok(/computeHard\(consoleEntries, pageErrors, textScan, behaviorHard\)/.test(src),
    'the computeHard call site grew an argument');
});


// =============================================================================================
// #1435 BROWSER-DRIVEN LOCKS. Everything above drives pure functions over supplied numbers; the
// probe itself (CONTENT_WIDTH_PROBE) and the entry-page ordering only exist in a real browser, and
// substring assertions on the probe text certify that text is present, not that it works (three
// precision guards survived a mutation of themselves with 108/108 green). These tests execute the
// probe in real headless Edge over CDP and run the real CLI against linked pages.
// Skipped LOUDLY (a printed line and skipped tests, never a silent pass) when no browser exists.
// One browser at a time; torn down by user-data-dir key so no Edge child outlives the run.
// =============================================================================================

const EDGE_CANDIDATES = [
  process.env.EDGE_PATH || '',
  'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
  'C:/Program Files/Microsoft/Edge/Application/msedge.exe',
].filter(Boolean);
const EDGE = EDGE_CANDIDATES.find((c) => fs.existsSync(c)) || null;
const HERE = path.dirname(fileURLToPath(import.meta.url));
const sleepMs = (ms) => new Promise((r) => setTimeout(r, ms));

function killEdgeByKey(key) {
  if (process.platform !== 'win32') return;
  try {
    spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command',
      `Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object { $_.CommandLine -like '*${key}*' } | ForEach-Object { & taskkill.exe /PID $_.ProcessId /T /F } *> $null`],
    { stdio: 'ignore', timeout: 20000 });
  } catch { /* best effort */ }
}

/** One shared headless browser for the browser-driven locks; null when unavailable. */
async function launchBrowser() {
  if (!EDGE) return null;
  const key = 'w1435-' + Math.random().toString(36).slice(2);
  const profile = path.join(os.tmpdir(), key);
  const port = 20000 + Math.floor(Math.random() * 20000);
  const child = spawn(EDGE, ['--headless=new', '--disable-gpu', '--no-sandbox', '--no-first-run',
    '--no-default-browser-check', `--user-data-dir=${profile}`, `--remote-debugging-port=${port}`,
    '--remote-allow-origins=*', '--window-size=1280,900', 'about:blank'], { stdio: 'ignore' });
  child.on('error', () => {});
  let target = null;
  for (let i = 0; i < 60 && !target; i++) {
    try {
      const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
      target = list.find((t) => t.type === 'page' && t.webSocketDebuggerUrl) || null;
    } catch { /* not up yet */ }
    if (!target) await sleepMs(250);
  }
  const close = () => {
    try { child.kill(); } catch {}
    try { spawnSync('taskkill', ['/PID', String(child.pid), '/T', '/F'], { stdio: 'ignore' }); } catch {}
    killEdgeByKey(key);
    try { fs.rmSync(profile, { recursive: true, force: true }); } catch {}
  };
  if (!target) { close(); return null; }
  const ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((res, rej) => { ws.addEventListener('open', res); ws.addEventListener('error', () => rej(new Error('ws'))); });
  let id = 0; const pending = new Map(); const loadWaiters = [];
  ws.addEventListener('message', (ev) => {
    const m = JSON.parse(String(ev.data));
    if (m.id && pending.has(m.id)) {
      const p = pending.get(m.id); pending.delete(m.id);
      if (m.error) p.rej(new Error(m.error.message)); else p.res(m.result);
    } else if (m.method === 'Page.loadEventFired') { while (loadWaiters.length) loadWaiters.shift()(); }
  });
  const send = (method, params = {}) => new Promise((res, rej) => {
    const i = ++id; pending.set(i, { res, rej }); ws.send(JSON.stringify({ id: i, method, params }));
  });
  await send('Page.enable');
  const measure = async (url, width = 1600) => {
    await send('Emulation.setDeviceMetricsOverride', { width, height: 900, deviceScaleFactor: 1, mobile: false });
    const loaded = new Promise((r) => loadWaiters.push(r));
    await send('Page.navigate', { url });
    await Promise.race([loaded, sleepMs(8000)]);
    await sleepMs(250);
    const r = await send('Runtime.evaluate', { expression: CONTENT_WIDTH_PROBE, returnByValue: true });
    return assessContentWidth(r.result.value);
  };
  return { measure, close };
}

const pageHtml = (css, body) => `<!doctype html><html><head><meta charset="utf-8"><style>body{margin:0;font:16px/1.5 sans-serif}${css}</style></head><body>${body}</body></html>`;
const LOREM = 'The quick brown fox jumps over the lazy dog near the riverbank today.';
const para = (n = 3, style = '') => Array.from({ length: n }, (_, i) => `<p${style ? ` style="${style}"` : ''}>${LOREM} Paragraph ${i}.</p>`).join('');
const CONTAINED = (inner) => `<main style="max-width:800px;margin:0 auto">${inner}</main>`;

/** name -> { html, unconstrained, why }. Each fixture names the guard it exercises. */
const WIDTH_FIXTURES = {
  'contained': { html: pageHtml('', CONTAINED(para(4))), unconstrained: false, why: 'positive control: contained page' },
  'flush': { html: pageHtml('', para(4)), unconstrained: true, why: 'positive control: flush page' },
  // header/footer skip: the ONLY edge text is page chrome, main is contained.
  'chrome-only': { html: pageHtml('', `<header>${para(2)}</header>${CONTAINED(para(3))}<footer>${para(2)}</footer>`), unconstrained: false, why: 'chrome skip' },
  // nearest-edge: text flush against the RIGHT edge only.
  'right-flush': { html: pageHtml('p{text-align:right;margin:0}', para(4)), unconstrained: true, why: 'right edge counts, not only left' },
  // leaf check: ONE flush paragraph wrapped in an li. Counted once => no verdict; twice => convicted.
  'leaf-li-p': { html: pageHtml('ul{list-style:none;margin:0;padding:0}', `<ul><li><p style="margin:0">${LOREM} ${LOREM}</p></li></ul>`), unconstrained: false, why: 'leaf check' },
  // visibility:hidden still lays out (Range rects exist); only the explicit skip keeps it out.
  'hidden': { html: pageHtml('', CONTAINED(para(3)) + para(3, 'visibility:hidden')), unconstrained: false, why: 'hidden skip' },
  // fixed cookie banner / sticky / opacity 0 / clipped sr-only / parked off-screen skip-link
  'fixed-banner': { html: pageHtml('.ck{position:fixed;bottom:0;left:0;right:0;background:#eee}', CONTAINED(para(3)) + `<div class="ck">${para(2)}</div>`), unconstrained: false, why: 'fixed element skip' },
  'sticky-bar': { html: pageHtml('.st{position:sticky;top:0}', CONTAINED(para(3)) + `<div class="st">${para(2)}</div>`), unconstrained: false, why: 'sticky element skip' },
  'opacity-zero': { html: pageHtml('', CONTAINED(para(3)) + `<div style="opacity:0">${para(2)}</div>`), unconstrained: false, why: 'opacity:0 skip' },
  'sr-only': { html: pageHtml('.sr{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0,0,0,0)}', CONTAINED(para(3)) + `<div class="sr">${para(2)}</div>`), unconstrained: false, why: 'visually-hidden clipped skip' },
  'offscreen': { html: pageHtml('.off{position:absolute;left:-9999px}', CONTAINED(para(3)) + `<div class="off">${para(2)}</div>`), unconstrained: false, why: 'parked off-screen skip' },
};
// Documented over-report / under-report shapes (CONTENT_WIDTH_CANNOT_SEE). Pinned so the list stays true.
const DOCUMENTED_SHAPES = {
  'hero-padded-20': { html: pageHtml('.hero{padding:0 20px}', `<div class="hero">${para(2)}</div>` + CONTAINED(para(3))), unconstrained: true, why: 'left-aligned full-bleed hero with 20px padding reads flush (over-report)' },
  'aside-16': { html: pageHtml('aside{float:left;padding:0 16px;width:200px}ul{list-style:none;margin:0;padding:0}', `<aside><ul><li>${LOREM}</li><li>${LOREM}</li></ul></aside>` + CONTAINED(para(3))), unconstrained: true, why: 'docs-style aside at 16px padding reads flush (over-report)' },
  'one-flush-paragraph': { html: pageHtml('', `<p>${LOREM} ${LOREM} ${LOREM}</p>`), unconstrained: false, why: 'single flush paragraph needs >=2 blocks (false negative)' },
  'div-text': { html: pageHtml('', `<div>${LOREM} ${LOREM}</div><div>${LOREM} ${LOREM}</div>`), unconstrained: false, why: 'div/span text is never measured (false negative)' },
};

const NO_BROWSER = !EDGE;
if (NO_BROWSER) console.error('#1435 BROWSER-DRIVEN LOCKS SKIPPED: no Edge found (set EDGE_PATH). The probe and the entry-row ordering are NOT executed by this run.');
const bTest = (name, fn) => test(name, { skip: NO_BROWSER ? 'no browser available (loud skip)' : false, timeout: 120000 }, fn);

let sharedBrowser = null, fixtureDir = null;
async function browser() {
  if (!sharedBrowser) {
    sharedBrowser = await launchBrowser();
    assert.ok(sharedBrowser, 'headless Edge did not start');
    fixtureDir = fs.mkdtempSync(path.join(os.tmpdir(), 'w1435-fx-'));
    for (const [n, f] of Object.entries({ ...WIDTH_FIXTURES, ...DOCUMENTED_SHAPES })) fs.writeFileSync(path.join(fixtureDir, n + '.html'), f.html);
  }
  return sharedBrowser;
}
test.after(() => {
  if (sharedBrowser) sharedBrowser.close();
  if (fixtureDir) fs.rmSync(fixtureDir, { recursive: true, force: true });
});

for (const [name, fx] of Object.entries(WIDTH_FIXTURES)) {
  bTest(`#1435 BROWSER probe: ${name} -> unconstrained=${fx.unconstrained} (${fx.why})`, async () => {
    const b = await browser();
    const r = await b.measure(pathToFileURL(path.join(fixtureDir, name + '.html')).href);
    assert.equal(r.measured, true);
    assert.equal(r.unconstrained, fx.unconstrained,
      `${name}: expected unconstrained=${fx.unconstrained}, got ${r.unconstrained} (${r.edgeBlocks} of ${r.blocksMeasured} blocks at the edge)`);
  });
}
for (const [name, fx] of Object.entries(DOCUMENTED_SHAPES)) {
  bTest(`#1435 BROWSER documented shape: ${name} (${fx.why})`, async () => {
    const b = await browser();
    const r = await b.measure(pathToFileURL(path.join(fixtureDir, name + '.html')).href);
    assert.equal(r.unconstrained, fx.unconstrained, `the cannot-see list claims: ${fx.why}`);
  });
}

test('#1435 the cannot-see list names the over-report and false-negative shapes, and is published', () => {
  const all = CONTENT_WIDTH_CANNOT_SEE.join('\n');
  for (const needle of ['hero', 'sidebar', 'banner', 'single flush paragraph', 'div or span', '400 blocks', 'cookie']) {
    assert.ok(all.includes(needle), 'the cannot-see list no longer mentions: ' + needle);
  }
  assert.deepEqual(aggregateContentWidth([]).cannotSee, [...CONTENT_WIDTH_CANNOT_SEE]);
});

/** Run the REAL CLI against a file:// entry URL; returns the parsed sidecar. */
function runCapture(entryUrl, outDir, tag, extra = []) {
  const out = path.join(outDir, tag + '.png');
  const side = path.join(outDir, tag + '.json');
  const profile = path.join(os.tmpdir(), 'w1435cli-' + tag + '-' + Math.random().toString(36).slice(2));
  const r = spawnSync(process.execPath, [path.join(HERE, 'capture-web-cdp.mjs'), '--url', entryUrl, '--out', out,
    '--console-out', side, '--profile-dir', profile, '--settle-ms', '300', ...extra],
  { encoding: 'utf8', timeout: 90000 });
  killEdgeByKey(path.basename(profile));
  assert.ok(fs.existsSync(side), 'no sidecar written: ' + (r.stderr || '').slice(0, 300));
  return JSON.parse(fs.readFileSync(side, 'utf8'));
}

bTest('#1435 BROWSER ENTRY ROW: each single-URL run measures ITS OWN page even when the smoke click navigates', async () => {
  // a.html is contained and its first control is a link to b.html; b.html is flush and links
  // back to a.html. Before the fix the heuristic click navigated first and the entry row
  // described the OTHER page in both polarities.
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'w1435-clk-'));
  try {
    fs.writeFileSync(path.join(dir, 'a.html'), pageHtml('', `<nav><a href="b.html">to b</a></nav>${CONTAINED(para(3).replace(/<p>/g, '<p>PageA '))}`));
    fs.writeFileSync(path.join(dir, 'b.html'), pageHtml('', `<nav><a href="a.html">to a</a></nav>${para(3).replace(/<p>/g, '<p>PageB ')}`));
    const a = runCapture(pathToFileURL(path.join(dir, 'a.html')).href, dir, 'a');
    const b = runCapture(pathToFileURL(path.join(dir, 'b.html')).href, dir, 'b');
    assert.equal(a.pages[0].contentWidth.unconstrained, false, 'contained a.html was reported unconstrained (b.html was measured)');
    assert.equal(b.pages[0].contentWidth.unconstrained, true, 'flush b.html was reported clean (a.html was measured)');
    assert.equal(a.contentWidth.pagesUnconstrained, 0);
    assert.equal(b.contentWidth.pagesUnconstrained, 1);
    assert.ok(b.findings.some((f) => f.includes('PageB')), 'the finding must quote the page that was measured');
    assert.ok(!a.findings.some((f) => f.includes('PageB')));
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

// ---------------------------------------------------------------------------
// #1434 — the "would lose data" clause decided by asking the browser, not the attributes.
// ---------------------------------------------------------------------------

test('#1434 a submit listener is found, and another event type is not mistaken for one', () => {
  assert.equal(hasSubmitListener({ listeners: [{ type: 'submit' }] }), true);
  assert.equal(hasSubmitListener({ listeners: [{ type: 'click' }, { type: 'input' }] }), false);
});

test('#1434 an unreadable listener reply is NOT a "no listener" answer', () => {
  // The three-state discipline, one level down: a reply this cannot parse must never be folded
  // into the same bucket as a form the browser confirmed has nothing attached.
  for (const bad of [null, undefined, {}, { listeners: 'x' }]) {
    assert.equal(hasSubmitListener(bad), false, 'unreadable must not claim a listener');
  }
  // ...and the assess layer keeps it as undecided rather than convicting on it.
  const a = assessSubmitListeners({ readable: false, forms: [false] });
  assert.equal(a.decided, false);
  assert.equal(a.measured, false);
});

test('#1434 a form with its own submit listener is vindicated, not convicted', () => {
  const a = assessSubmitListeners({ readable: true, forms: [true] });
  assert.equal(a.decided, true);
  assert.equal(a.handled, 1);
  assert.equal(a.unhandled, 0);
});

test('#1434 THE NEAR-TWIN: delegation on an ancestor still handles the form', () => {
  // document.addEventListener('submit', ...) handles every form on the page. A form with no
  // listener of its OWN is not evidence of anything until the delegation targets are asked —
  // and a check that convicted this would convict correct sites and get switched off.
  // Delegation is decided per form by the chain walk (and the window): each reading arrives as
  // true when ANY node on that form's path holds a listener.
  const a = assessSubmitListeners({ readable: true, forms: [true, true] });
  assert.equal(a.decided, true);
  assert.equal(a.handled, 2, 'delegation must vindicate every form on the page');
  assert.equal(a.unhandled, 0);
});

test('#1434 a form with no listener anywhere IS convicted', () => {
  const a = assessSubmitListeners({ readable: true, forms: [false] });
  assert.equal(a.unhandled, 1);
  const f = assessForms({
    formCount: 1, noSubmitPath: 0, wouldLoseData: 1, scriptCount: 3,
    loseDataExample: 'contactForm', submitListeners: a,
  });
  assert.equal(f.loseDataUndecidable, 0, 'the browser answered, so nothing is undecidable');
  assert.equal(f.findings.length, 1);
  assert.ok(f.findings[0].includes('contactForm'));
  assert.ok(/browser reports no submit listener on the form, any of its ancestors or the window/
    .test(f.findings[0]), 'the finding must say exactly what was asked');
  assert.ok(/not inspected/.test(f.findings[0]), 'and what was NOT asked (click/keypress)');
  assert.ok(!/asked directly/.test(f.findings[0]), 'no claim wider than the question');
});

test('#1434 THE TOGGLE: the exact case that convicted a correct form now reads clean', () => {
  // Run 20260816-134142-bd: <form id="contactForm"> with no action, no onsubmit, wired by an
  // inline form.addEventListener('submit', e => e.preventDefault()). The old rule emitted
  // "submitting reloads the page and throws the typed values away" — false on both halves.
  const decided = assessSubmitListeners({ readable: true, forms: [true] });
  const f = assessForms({
    formCount: 1, noSubmitPath: 0, wouldLoseData: 1, scriptCount: 4,
    loseDataExample: 'contactForm', submitListeners: decided,
  });
  assert.deepEqual(f.findings, [], 'a correctly wired form must produce NO finding');
  assert.equal(f.loseDataUndecidable, 0, 'and must not be parked as undecidable either');
  assert.equal(f.submitListeners.decided, true);
  assert.equal(f.submitListeners.handled, 1);
});

test('#1434 without introspection the honest "undecidable" fallback is preserved', () => {
  // Removing the old behaviour would be a regression: when the browser could not be asked and a
  // script might have wired the form, "we could not tell" is still the only true answer.
  const f = assessForms({ formCount: 1, noSubmitPath: 0, wouldLoseData: 1, scriptCount: 3 });
  assert.equal(f.loseDataUndecidable, 1);
  assert.deepEqual(f.findings, []);
  assert.equal(f.submitListeners.decided, false);
  // ...and a scriptless page is still convicted on its own terms.
  const g = assessForms({ formCount: 1, noSubmitPath: 0, wouldLoseData: 1, scriptCount: 0 });
  assert.equal(g.findings.length, 1);
  assert.ok(/loads no script/.test(g.findings[0]));
});

// ---------------------------------------------------------------------------
// #1434 REVIEW FIXES. An independent review reproduced a false conviction against real Edge:
// a listener on a React-18-style root container (a div one level below body) was convicted,
// because the delegation check asked only document/body/documentElement. These lock the fix.
// ---------------------------------------------------------------------------

test('#1434-fix the chain probe WALKS ANCESTORS, it does not ask a fixed node list', () => {
  // The whole defect was a hardcoded 3-node list. The mechanism must be a walk, so a listener
  // on ANY ancestor -- a root container div, a wrapper, a fieldset -- is found.
  assert.ok(SUBMIT_CHAIN_HANDLE_PROBE.includes('parentNode'),
    'the chain probe must walk parentNode; a fixed node list is the defect being retired');
  assert.ok(/while\(n\)\{out\.push\(n\);n=n\.parentNode;\}/.test(SUBMIT_CHAIN_HANDLE_PROBE),
    'it must push the node then ascend, so the form ITSELF is included alongside its ancestors');
  assert.ok(SUBMIT_CHAIN_SHAPE_PROBE.includes('parentNode'),
    'the shape probe must walk the SAME chain, or the lengths cannot attribute the handles');
});

test('#1434-fix the chain probes agree on which forms are doubtful', () => {
  // Both probes must select the same population by the same rule, or handle attribution silently
  // shifts by one form and every verdict after it is about the wrong element.
  for (const probe of [SUBMIT_CHAIN_HANDLE_PROBE, SUBMIT_CHAIN_SHAPE_PROBE]) {
    assert.ok(probe.includes("getAttribute('action')"));
    assert.ok(probe.includes("getAttribute('onsubmit')"));
    assert.ok(probe.includes('if(act||onsub)continue;'));
    assert.doesNotThrow(() => new Function(`return ${probe}`), 'probe must be valid JavaScript');
  }
});

test('#1434-fix SAFETY: the chain probes enumerate and never interact', () => {
  // Same lock as the original probes: walking the DOM is a read.
  for (const probe of [SUBMIT_CHAIN_HANDLE_PROBE, SUBMIT_CHAIN_SHAPE_PROBE]) {
    for (const forbidden of ['.submit(', '.click(', '.focus(', 'dispatchEvent', 'requestSubmit',
      'addEventListener', 'fetch(', 'XMLHttpRequest', '.value=', 'setAttribute', 'innerHTML=']) {
      assert.ok(!probe.includes(forbidden), `chain probe must not contain ${forbidden}`);
    }
  }
});

test('#1434-fix THE TOGGLE: an UNDERCOUNTED census is UNDECIDED, never a clean pass', () => {
  // Review finding 2, reproduced by the reviewer: the listener census and the attribute census are
  // separate round trips, so the census can return fewer forms than wouldLoseData counted. The old
  // code reported decided:true / unhandled:0 / findings:[] for forms it never asked about.
  const short = assessSubmitListeners({ readable: true, forms: [true] }, 5);
  assert.equal(short.decided, false, 'a short census must NOT read as decided');
  assert.equal(short.shortfall, 4, 'and it must say how many forms went unasked');
  const f = assessForms({
    formCount: 5, noSubmitPath: 0, wouldLoseData: 5, scriptCount: 3, submitListeners: short,
  });
  assert.equal(f.loseDataUndecidable, 5,
    'the forms that were never asked about must be published as UNDECIDABLE');
  assert.deepEqual(f.findings, [], 'and must not produce a confident finding either way');
});

test('#1434-fix a COMPLETE census still decides normally', () => {
  // The guard must not turn every honest full census into undecidable.
  const full = assessSubmitListeners({ readable: true, forms: [true, true] }, 2);
  assert.equal(full.decided, true);
  assert.equal(full.handled, 2);
  const f = assessForms({ formCount: 2, noSubmitPath: 0, wouldLoseData: 2, scriptCount: 3,
    submitListeners: full });
  assert.equal(f.loseDataUndecidable, 0);
  assert.deepEqual(f.findings, []);
});

test('#1434-fix an absent expected count does not break the old contract', () => {
  // Back-compat: callers that pass no count behave exactly as before.
  const a = assessSubmitListeners({ readable: true, forms: [false] });
  assert.equal(a.decided, true);
  assert.equal(a.unhandled, 1);
});

// ---------------------------------------------------------------------------
// #1434 second review (2026-10-29). EXECUTING tests of measureSubmitListeners against a fake CDP
// client, and a lock on which CDP traffic it may send.
// ---------------------------------------------------------------------------

/** A fake page. forms: [{chain:[nodeName...]}] (form first, document last). listeners: nodeName ->
 *  event types. Node names are unique per form (e.g. 'f0','f0-div'). */
function fakePage({ forms, listeners = {}, windowListeners = [], blind = 0, unreadable = false, windowNoHandle = false }) {
  const sent = [];
  const flat = forms.flatMap((f) => f.chain);
  const cdp = {
    sent,
    async send(method, params = {}) {
      sent.push({ method, params });
      if (unreadable) throw new Error('target closed');
      if (method === 'Runtime.evaluate') {
        if (params.expression === SUBMIT_CHAIN_SHAPE_PROBE) {
          return { result: { value: { lengths: forms.map((f) => f.chain.length) } } };
        }
        if (params.expression === SUBMIT_CHAIN_HANDLE_PROBE) return { result: { objectId: 'arr' } };
        if (params.expression === 'window') return windowNoHandle ? { result: {} } : { result: { objectId: 'win' } };
        if (params.expression === SUBMIT_BLIND_PROBE) return { result: { value: { blind } } };
        throw new Error('unexpected expression ' + params.expression);
      }
      if (method === 'Runtime.getProperties') {
        return { result: flat.map((n, i) => ({ name: String(i), value: { objectId: 'node:' + n } })) };
      }
      if (method === 'DOMDebugger.getEventListeners') {
        const id = params.objectId;
        const types = id === 'win' ? windowListeners : (listeners[id.replace('node:', '')] || []);
        return { listeners: types.map((type) => ({ type })) };
      }
      if (method === 'Runtime.releaseObject') return {};
      throw new Error('unexpected CDP method ' + method);
    },
  };
  return cdp;
}
const chain = (p) => [p, p + '-div', p + '-body', p + '-html', p + '-document'];

test('#1434-r2 measureSubmitListeners EXECUTES: own listener -> handled, none -> unhandled', async () => {
  const a = await measureSubmitListeners(fakePage({ forms: [{ chain: chain('f0') }], listeners: { f0: ['submit'] } }));
  assert.deepEqual(a.forms, [true]);
  assert.equal(a.readable, true);
  const b = await measureSubmitListeners(fakePage({ forms: [{ chain: chain('f0') }] }));
  assert.deepEqual(b.forms, [false], 'no listener anywhere must read as unhandled');
  assert.equal(assessSubmitListeners(b, 1).unhandled, 1);
});

test('#1434-r2 measureSubmitListeners: ancestor listener handles only its own form', async () => {
  const r = await measureSubmitListeners(fakePage({
    forms: [{ chain: chain('f0') }, { chain: chain('f1') }], listeners: { 'f1-div': ['submit'] },
  }));
  assert.deepEqual(r.forms, [false, true]);
});

test('#1434-r2 a WINDOW listener handles every form (review finding 1)', async () => {
  const r = await measureSubmitListeners(fakePage({
    forms: [{ chain: chain('f0') }, { chain: chain('f1') }], windowListeners: ['submit'],
  }));
  assert.deepEqual(r.forms, [true, true]);
  const clickOnly = await measureSubmitListeners(fakePage({
    forms: [{ chain: chain('f0') }], windowListeners: ['click'],
  }));
  assert.deepEqual(clickOnly.forms, [false], 'a non-submit window listener must not vindicate');
});

test('#1434-r2 measureSubmitListeners: any CDP failure is unreadable, never a conviction', async () => {
  const r = await measureSubmitListeners(fakePage({ forms: [{ chain: chain('f0') }], unreadable: true }));
  assert.equal(r.readable, false);
  const a = assessSubmitListeners(r, 1);
  assert.equal(a.decided, false);
  assert.equal(a.unhandled, 0);
});

test('#1434-r2 window evaluate yielding no objectId is unreadable, never a conviction (review finding 2)', async () => {
  const r = await measureSubmitListeners(fakePage({
    forms: [{ chain: chain('f0') }], windowNoHandle: true,
  }));
  assert.equal(r.readable, false, 'a browser that will not hand back window must not manufacture a reading');
  assert.deepEqual(r.forms, []);
  const a = assessSubmitListeners(r, 1);
  assert.equal(a.decided, false);
  assert.equal(a.unhandled, 0, 'never a conviction');
});

test('#1434-r2 the window handle is released (review finding 3)', async () => {
  const cdp = fakePage({ forms: [{ chain: chain('f0') }] });
  await measureSubmitListeners(cdp);
  const released = cdp.sent.filter((x) => x.method === 'Runtime.releaseObject').map((x) => x.params.objectId);
  assert.ok(released.includes('win'), 'window handle must be released; released: ' + released.join(','));
  assert.ok(released.includes('arr'), 'the array handle must be released too');
});

test('#1434-r2 aggregateForms carries blind spots: shadow/iframe-only page is not a clean zero (review finding 1)', () => {
  const blindPage = { entry: true, url: 'http://x/', forms: { measured: true, formCount: 0, findings: [],
    submitListeners: { decided: false, checked: 0, handled: 0, unhandled: 0, blindSpots: 2, reason: 'no-forms-examined' } } };
  const r = aggregateForms([blindPage]);
  assert.equal(r.formCount, 0);
  assert.deepEqual(r.findings, []);
  assert.equal(r.blindSpots, 2);
  assert.equal(r.pagesWithBlindSpots, 1);
  assert.equal(r.pagesWithUnreadForms, 1, 'formCount 0 beside blind spots must not read as looked-and-empty');
  const clean = aggregateForms([{ entry: true, url: 'http://x/', forms: { measured: true, formCount: 0, findings: [],
    submitListeners: { decided: false, checked: 0, handled: 0, unhandled: 0, blindSpots: 0, reason: 'no-forms-examined' } } }]);
  assert.equal(clean.blindSpots, 0);
  assert.equal(clean.pagesWithUnreadForms, 0);
  assert.notDeepEqual(r, clean);
  const mixed = aggregateForms([blindPage,
    { entry: false, url: 'http://x/b', forms: { measured: true, formCount: 1, findings: [],
      submitListeners: { decided: true, checked: 1, handled: 1, unhandled: 0, blindSpots: 1 } } }]);
  assert.equal(mixed.blindSpots, 3);
  assert.equal(mixed.pagesWithBlindSpots, 2);
  assert.equal(mixed.pagesWithUnreadForms, 1);
});

test('#1434-r2 zero forms examined is NOT decided (review finding 2)', async () => {
  const r = await measureSubmitListeners(fakePage({ forms: [], blind: 2 }));
  assert.equal(r.readable, true);
  const a = assessSubmitListeners(r);
  assert.equal(a.decided, false, 'checked 0 must never read as a clean pass');
  assert.equal(a.reason, 'no-forms-examined');
  assert.equal(a.blindSpots, 2, 'the page has 2 places the census cannot see; the sidecar must say so');
  const f = assessForms({ formCount: 0, noSubmitPath: 0, wouldLoseData: 0, scriptCount: 1, submitListeners: a });
  assert.equal(f.submitListeners.decided, false);
  assert.equal(f.submitListeners.reason, 'no-forms-examined');
});

test('#1434-r2 blind spots (shadow roots / iframes) ride along with a decided reading', async () => {
  const r = await measureSubmitListeners(fakePage({ forms: [{ chain: chain('f0') }], blind: 3 }));
  const a = assessSubmitListeners(r, 1);
  assert.equal(a.decided, true);
  assert.equal(a.blindSpots, 3);
  const f = assessForms({ formCount: 1, noSubmitPath: 0, wouldLoseData: 1, scriptCount: 1, submitListeners: a });
  assert.equal(f.submitListeners.blindSpots, 3);
  assert.ok(SUBMIT_BLIND_PROBE.includes('shadowRoot') && SUBMIT_BLIND_PROBE.includes('iframe'));
  assert.doesNotThrow(() => new Function(`return ${SUBMIT_BLIND_PROBE}`));
});

test('#1434-r2 CDP ALLOWLIST LOCK: only reads cross the wire', async () => {
  const ALLOWED = new Set(['Runtime.evaluate', 'Runtime.getProperties', 'Runtime.releaseObject',
    'DOMDebugger.getEventListeners']);
  const EXPRESSIONS = new Set([SUBMIT_CHAIN_SHAPE_PROBE, SUBMIT_CHAIN_HANDLE_PROBE, SUBMIT_BLIND_PROBE, 'window']);
  const scenarios = [
    { forms: [{ chain: chain('f0') }, { chain: chain('f1') }], listeners: { f0: ['submit'] } },
    { forms: [{ chain: chain('f0') }], windowListeners: ['submit'] },
    { forms: [] },
  ];
  for (const sc of scenarios) {
    const cdp = fakePage(sc);
    await measureSubmitListeners(cdp);
    assert.ok(cdp.sent.length > 0);
    for (const { method, params } of cdp.sent) {
      assert.ok(ALLOWED.has(method), `measureSubmitListeners must not send ${method}`);
      assert.ok(!('functionDeclaration' in params), 'no function may be called on a page object');
      if (method === 'Runtime.evaluate') {
        assert.ok(EXPRESSIONS.has(params.expression), 'only the known read-only expressions may be evaluated');
      }
    }
  }
  // Source-level backstop: the function body must not name a mutating CDP method.
  const src = fs.readFileSync(new URL('./capture-web-cdp.mjs', import.meta.url), 'utf8');
  const body = src.slice(src.indexOf('export async function measureSubmitListeners'));
  const fnBody = body.slice(0, body.search(/\r?\n\}\r?\n/));
  for (const bad of ['callFunctionOn', 'Input.', 'dispatchEvent', 'DOM.', '.submit(', 'requestSubmit', '.click(']) {
    assert.ok(!fnBody.includes(bad), `measureSubmitListeners must not contain ${bad}`);
  }
});

test('#1434-r2 SAFETY: the blind probe enumerates and never interacts', () => {
  for (const forbidden of ['.submit(', '.click(', '.focus(', 'dispatchEvent', 'requestSubmit',
    'addEventListener', 'fetch(', 'setAttribute', 'innerHTML=']) {
    assert.ok(!SUBMIT_BLIND_PROBE.includes(forbidden));
  }
});

test('#1434-r2 the published sidecar carries no always-false delegated field', () => {
  const f = assessForms({ formCount: 1, noSubmitPath: 0, wouldLoseData: 1, scriptCount: 1,
    submitListeners: assessSubmitListeners({ readable: true, forms: [true] }, 1) });
  assert.ok(!('delegated' in f.submitListeners));
});
