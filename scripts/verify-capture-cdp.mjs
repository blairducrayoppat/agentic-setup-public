// verify-capture-cdp.mjs — #823 H8/H9 unit suite for the PURE logic of capture-web-cdp.mjs.
// No browser, no network: exercises console/exception normalization, the runtime-error
// classification, the rendered-text undefined/NaN scan, the positive behavior-smoke verdict, and
// the verbatim-findings composition. Run: `node --test verify-capture-cdp.mjs`.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  cleanText, fromConsoleApi, fromException, fromLogEntry, isRuntimeError,
  scanRenderedText, evaluateBehavior, buildFindings, errorCount, computeHard,
  buildNonEntryFindings,
  assessPhoneWidth, phoneWidthFinding, assessA11yBasics, assessForms,
  FORMS_PROBE, aggregateForms,
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
  const calls = src.match(/assessForms\(await evalJson\(cdp, FORMS_PROBE\)\)/g) || [];
  assert.equal(calls.length, 2,
    'expected exactly two call sites — the entry page and the sweep. ' + calls.length + ' found');
  assert.ok(!/assessForms\(await evalJson\(cdp, \[/.test(src),
    'a forms probe was re-inlined as an array literal — use FORMS_PROBE');
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
