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
//   { "click": "<css selector for the primary action>", "expectDelta": "<css selector that must change>",
//     "actionLabel": "<plain words>", "resultLabel": "<plain words>" }
// When absent, a heuristic picks the first visible enabled primary control. The rendered-text
// `undefined`/`NaN` scan is ALWAYS on and needs no declaration (it is the direct B5 catch).
//
// WHO WRITES THE SPEC. BlarAI's PLAN does, never the coder: shared/fleet/acceptance.py derives it
// (`_smoke_spec_from_plan`), the AO seeds it into the baseline every candidate inherits so the coder
// is TOLD the two DOM hooks to place, and the swap driver re-writes the plan's bytes immediately
// before each capture so a candidate cannot edit the exam it is about to sit. Until that writer
// existed nothing wrote this file at all, so the declared arm below was unreachable and EVERY web
// build fell through to the heuristic — whose failures are only a soft note.
//
// THE SPEC IS UNTRUSTED INPUT HERE. Its selectors reach `document.querySelector`, so they are
// re-validated against a narrow allowlist (`isValidSmokeSelector`) before use, and a spec that fails
// validation is REFUSED rather than half-honoured. A declared hook that matches NO element gets its
// own status — never a silent degrade to the heuristic, which is the same defect one layer up. The
// sidecar's `smoke` block always states which happened, so "no spec was declared", "a spec was
// declared and its hooks are missing" and "a spec was declared and exercised" are three
// distinguishable readings rather than one.

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

/** Operator-visible failure text the CODER ITSELF authored (#1375).
 *
 *  On 2026-08-10 the operator opened the delivered pottery site and read **"Failed to load
 *  pieces."** where the pottery should have been. Two pages fetched `./data/pieces.json`, the
 *  file sat outside the served root, and the browser 404'd. Nothing caught it, and the reason is
 *  worth stating precisely: that string is a CAUGHT rejection rendered into the DOM, so there is
 *  no console error and no uncaught exception. Every error channel the capture watches stayed
 *  silent while the page displayed its own failure in plain English.
 *
 *  `scanRenderedText` above catches the leaked-value shapes (`undefined`, `NaN`). This catches the
 *  deliberate ones: a page whose NORMAL rendered state is an apology is broken, however clean its
 *  console. Kept deliberately short and literal — every entry is a phrase a coder writes into a
 *  catch block, not a guess at what an error might look like. */
export const ERROR_TEXT_PATTERNS = [
  /failed to load/i,
  /could not load/i,
  /unable to load/i,
  /error loading/i,
  /something went wrong/i,
  /failed to fetch/i,
];
export function scanErrorText(innerText) {
  const text = String(innerText ?? '');
  const out = { hasErrorText: false, matches: [] };
  for (const re of ERROR_TEXT_PATTERNS) {
    const m = re.exec(text);
    if (!m) continue;
    out.hasErrorText = true;
    const start = Math.max(0, m.index - 24);
    const end = Math.min(text.length, m.index + m[0].length + 40);
    out.matches.push(cleanText(text.slice(start, end), 100));
  }
  return out;
}

/** Decide whether the primary-action click produced a POSITIVE behavior (H9). ``before``/``after``
 *  are DOM snapshots ({elementCount, htmlLen, chartMarks, canvasInk, textLen}); ``spec`` may name an
 *  ``expectDelta`` region the snapshot recorded under ``regionHtmlLen``. A delta in ANY structural
 *  axis (or the named region) counts; no delta on a real click is the "cosmetic hide" tell. */
export function evaluateBehavior(before, after, spec, click) {
  const b = before || {}, a = after || {};
  const c = click || {};
  // ---- DECLARED path: the plan named the hooks and the coder was told to place them ----
  // Each miss is named separately and carries its own status, because the FIX differs: an
  // absent hook is "add the attribute to your button", a dead one is "wire the button up".
  // Falling back to the heuristic here — which is what happened before the declared arm had
  // a writer — turns "the contract was not met" into "no delta was seen", a softer and
  // wronger statement.
  if (spec && spec.click) {
    const label = cleanText(spec.actionLabel || 'the main control', 80);
    if (c.explicitPresent === false) {
      return { ran: true, ok: false, changed: false, status: SMOKE_ACTION_HOOK_MISSING,
        reason: `${label} is missing its required marker: no element matches ${cleanText(spec.click, 80)}. `
          + `Add that attribute to the control a person uses to make the page do its main job.` };
    }
    if (c.explicitVisible === false) {
      return { ran: true, ok: false, changed: false, status: SMOKE_ACTION_HOOK_MISSING,
        reason: `${label} carries its marker (${cleanText(spec.click, 80)}) but is hidden or disabled, `
          + `so a person cannot use it.` };
    }
  }
  if (!c.clicked) {
    return { ran: true, ok: false, changed: false, status: SMOKE_ACTION_HOOK_MISSING,
      reason: c.reason ? cleanText(c.reason) : 'no primary action could be found or clicked' };
  }
  if (spec && spec.expectDelta) {
    const rLabel = cleanText(spec.resultLabel || 'the result region', 80);
    // regionHtmlLen is -1 exactly when querySelector matched nothing (see snapshotJs), so an
    // ABSENT result region is decidable rather than inferred from "it did not change".
    if ((a.regionHtmlLen ?? -1) < 0 && (b.regionHtmlLen ?? -1) < 0) {
      return { ran: true, ok: false, changed: false, status: SMOKE_RESULT_HOOK_MISSING,
        reason: `${rLabel} is missing its required marker: no element matches `
          + `${cleanText(spec.expectDelta, 80)}. Add that attribute to the part of the page that `
          + `changes when the main control is used.` };
    }
    const changed = (a.regionHtmlLen ?? -1) !== (b.regionHtmlLen ?? -2) || (a.regionText ?? '') !== (b.regionText ?? '');
    return { ran: true, ok: changed, changed, status: SMOKE_HONOURED,
      reason: changed ? '' : `${rLabel} (${cleanText(spec.expectDelta, 80)}) did not change after `
        + `${cleanText(spec.actionLabel || 'the main control', 80)} was used` };
  }
  const changed = (a.htmlLen !== b.htmlLen) || (a.elementCount !== b.elementCount)
    || (a.chartMarks !== b.chartMarks) || (a.canvasInk !== b.canvasInk) || (a.textLen !== b.textLen);
  return { ran: true, ok: changed, changed, status: SMOKE_NOT_DECLARED,
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
/** #1375 item 2, ADVISORY HALF. Findings for the pages BESIDE the entry point.
 *
 *  `buildFindings` above runs on the entry page only, because it is called before the
 *  extra-page loop navigates anywhere. So on 2026-08-15 a real `TypeError: Cannot set
 *  properties of null` that broke `contact.html` was recorded in `pages[1].pageErrors` and
 *  reached NO consumer, while the single published finding was a `favicon.ico` 404 from the
 *  entry page. `hard` read True — earned by the missing favicon. The record already
 *  disagreed with itself: `errorCount` is computed at write time from the accumulated
 *  arrays and said 2, while `findings` said 1.
 *
 *  Each finding NAMES ITS PAGE, because "an uncaught exception" is a different fact from
 *  "an uncaught exception on the contact page" when five pages shipped.
 *
 *  DELIBERATELY DOES NOT FEED `computeHard`. Promoting these to hard creates new build
 *  failures, which is the operator's ceremony rather than a wiring decision (#1345). This
 *  makes the defect VISIBLE; flipping it to blocking is one call site away and is his. */
export function buildNonEntryFindings(pages) {
  const out = [];
  for (const p of pages || []) {
    if (!p || p.entry) continue;
    const where = p.url ? ` [page: ${p.url}]` : '';
    if (p.visited === false) {
      // An unvisited page is not a clean page. Same three-state discipline the rest of this
      // file keeps: "did not look" must never render as "looked and found nothing".
      out.push(cleanText(`Page NOT VISITED${where}: ${p.error || 'navigation did not complete'}`, 400));
      continue;
    }
    for (const e of p.pageErrors || []) {
      if (isRuntimeError(e)) {
        const loc = e.url ? ` (${e.url}${e.line ? ':' + e.line : ''})` : '';
        out.push(cleanText(`Uncaught exception${where}: ${e.text}${loc}`, 400));
      }
    }
    if (p.textScan && (p.textScan.hasUndefined || p.textScan.hasNaN)) {
      const kinds = [p.textScan.hasUndefined ? '"undefined"' : null,
                     p.textScan.hasNaN ? '"NaN"' : null].filter(Boolean).join(' and ');
      out.push(cleanText(`Rendered text contains ${kinds}${where} — a value failed to compute and leaked into the UI`, 400));
    }
  }
  return out;
}

/** DoD row 15: "the layout survives a phone width".
 *
 *  The row names five things a delivered site must survive — links resolve, forms submit, the
 *  console is clean, THE LAYOUT SURVIVES A PHONE WIDTH, and the page is navigable by keyboard
 *  and screen reader. Links landed in #1345 and the console has the CDP tier; a phone-width
 *  check did not exist at all, and it is the cheapest of the remaining three because the
 *  capture is already driving a browser with device metrics overridden.
 *
 *  ONE DEFECT, DETERMINISTICALLY: content wider than the viewport, which a phone shows as a
 *  horizontal scrollbar and a page you have to drag sideways to read. `scrollWidth` past
 *  `innerWidth` is exactly that and needs no rendering judgement.
 *
 *  PRECISION-FIRST, because a false positive here nags a coder into "fixing" correct markup —
 *  the standing rule for every rule in this family. Sub-pixel rounding and a stray 1-2px
 *  border routinely push scrollWidth over by a hair on layouts that are fine, so the tolerance
 *  is a real number rather than zero, and the finding names the measured overflow so a human
 *  can adjudicate it in seconds rather than trusting the verdict.
 *
 *  Pure: takes measured numbers, returns a decision. The measuring lives in `run`. */
export function assessPhoneWidth(metrics, tolerancePx = 8) {
  if (!metrics || typeof metrics.scrollWidth !== 'number' || typeof metrics.innerWidth !== 'number') {
    // "Could not measure" is NOT "fits". A capture that failed to read the numbers says so.
    return { measured: false, overflows: false, overflowPx: 0 };
  }
  const overflowPx = Math.round(metrics.scrollWidth - metrics.innerWidth);
  return {
    measured: true,
    overflows: overflowPx > tolerancePx,
    overflowPx: overflowPx > 0 ? overflowPx : 0,
    widthPx: metrics.innerWidth,
    culprit: typeof metrics.culprit === 'string' ? metrics.culprit : '',
  };
}

/** The finding line for a phone-width overflow, or '' when there is nothing to say. */
export function phoneWidthFinding(assessment) {
  if (!assessment || !assessment.measured || !assessment.overflows) return '';
  const where = assessment.culprit ? ` (widest element: ${assessment.culprit})` : '';
  return cleanText(
    `Layout overflows a ${assessment.widthPx}px phone width by ${assessment.overflowPx}px${where}`
    + ' — the page scrolls sideways on a phone', 400);
}

/** DoD row 15: "the page is navigable by keyboard and screen reader".
 *
 *  The narrowest defensible slice of a large subject. This does NOT audit accessibility — it
 *  checks three facts a screen-reader or keyboard user cannot work around, each decidable from
 *  the DOM with no rendering judgement and no model:
 *
 *    - an `<img>` with NO `alt` ATTRIBUTE AT ALL. Note the precision trap, which is the whole
 *      reason this rule is written this way: `alt=""` is CORRECT and idiomatic for a decorative
 *      image, and a scan that flagged it would convict the deliverables that got it right —
 *      the same mistake `placeholder_prose` avoids by parsing rather than grepping. Only a
 *      MISSING attribute is a defect: the screen reader then announces the file name.
 *    - a form control with no accessible name by any route (label[for], wrapping label,
 *      aria-label, aria-labelledby, title). A field a screen reader can only call "edit text".
 *    - no `<h1>` anywhere. Heading navigation is the primary way a screen-reader user skims a
 *      page; a page with no top-level heading has no entry point.
 *
 *  What it deliberately does NOT check, because a named limit is usable and an unnamed one
 *  reads as coverage: colour contrast, focus-visible styling, tab ORDER, ARIA correctness,
 *  live regions, or anything requiring a real assistive technology. Those need judgement or a
 *  screen reader, and this is a lint.
 *
 *  Pure: takes counts measured in the page, returns findings. */
export function assessA11yBasics(m) {
  if (!m || typeof m.imagesMissingAlt !== 'number') {
    return { measured: false, findings: [] };
  }
  const out = [];
  if (m.imagesMissingAlt > 0) {
    const eg = m.imgExample ? ` (e.g. ${m.imgExample})` : '';
    out.push(cleanText(
      `${m.imagesMissingAlt} image(s) have no alt attribute${eg} — a screen reader reads the file `
      + 'name instead. Use alt="" only if the image is decorative', 400));
  }
  if (m.unlabelledFields > 0) {
    const eg = m.fieldExample ? ` (e.g. ${m.fieldExample})` : '';
    out.push(cleanText(
      `${m.unlabelledFields} form field(s) have no label a screen reader can announce${eg}`, 400));
  }
  if (m.h1Count === 0) {
    out.push(cleanText(
      'the page has no <h1> — heading navigation is how a screen-reader user skims a page', 400));
  }
  return { measured: true, findings: out };
}

/** DoD row 15: "forms submit".
 *
 *  WHAT THIS DOES NOT DO, first, because the gap between the row's words and this check is the
 *  most important thing about it: it does NOT submit the form. Submitting is a side effect on
 *  someone else's software — it can POST to a live endpoint, mutate a store, or navigate away
 *  mid-capture — and a grader that mutates what it grades is a worse defect than the one it
 *  looks for. What is checked is whether the form COULD be submitted and whether submitting it
 *  would obviously lose the user's data. Actual submission stays with the behaviour smoke,
 *  which is declared by the plan and consented to per-build.
 *
 *  Two defects, both decidable from the DOM and both unambiguous:
 *
 *    - A form with NO SUBMIT PATH. No `<button>`/`<input type=submit>`, and no single-line
 *      text input (which browsers submit on Enter). Nothing the user can do sends it.
 *    - A form that would NAVIGATE AWAY AND LOSE ITS DATA: no `action`, no `onsubmit`, AND no
 *      script on the page that could have attached a listener. The default action reloads the
 *      page and the typed values are gone. The last clause is not decoration — see the block
 *      inside the function: without it this rule convicts every form wired the normal way, with
 *      `addEventListener`, which this probe cannot see. Measured on the pottery site's own
 *      contact form on 2026-08-16, where it was wrong on both halves of its own sentence.
 *
 *  Precision-first: a form with an `action` is FINE even with no JavaScript, and a form with a
 *  handler is fine with no action. Only the pair being absent is a defect, which is why this
 *  cannot fire on a correctly-built server-posted form. */
export function assessForms(m) {
  if (!m || typeof m.formCount !== 'number') return { measured: false, findings: [] };
  const out = [];
  if (m.noSubmitPath > 0) {
    const eg = m.noSubmitExample ? ` (e.g. ${m.noSubmitExample})` : '';
    out.push(cleanText(
      `${m.noSubmitPath} form(s) have no way to submit them${eg} — no submit control and no `
      + 'text input the browser would submit on Enter', 400));
  }
  // THE UNDECIDABLE CASE, added 2026-08-16 (#1433) after this rule fired on correct markup.
  //
  // This check reads the `action` attribute and `onsubmit` (attribute and property). A handler
  // attached with `addEventListener('submit', ...)` is invisible to all three — the docstring
  // above has always said so, and the rule did not act on its own stated limitation. That was
  // survivable while the probe ran on the entry page only, which almost never carries a form.
  // Running it on every swept page makes it fire constantly, because addEventListener IS the
  // normal, correct way to wire a form.
  //
  // Measured on the delivered pottery site: `<form id="contactForm">` with no action and no
  // onsubmit, and an inline `form.addEventListener('submit', e => e.preventDefault())`. The
  // finding's own words — "submitting reloads the page and throws the typed values away" —
  // are false about that page twice over: there is a handler, and preventDefault stops the
  // reload. A gate that cries wolf gets switched off, and a switched-off gate protects nothing.
  //
  // So the defect is only ASSERTED where no script could have attached a listener. Anywhere
  // else it is counted as undecidable and named as such. A page with no scripts at all and a
  // form with no action genuinely does lose the data, and that case still convicts.
  let loseDataUndecidable = 0;
  if (m.wouldLoseData > 0) {
    // `scriptCount` absent means an older probe that never reported it — which is exactly the
    // state of not knowing whether a listener could exist, so it reads as undecidable too.
    const scriptless = m.scriptCount === 0;
    if (scriptless) {
      const eg = m.loseDataExample ? ` (e.g. ${m.loseDataExample})` : '';
      out.push(cleanText(
        `${m.wouldLoseData} form(s) have neither an action nor a submit handler${eg}, and the `
        + 'page loads no script that could attach one — submitting reloads the page and throws '
        + 'the typed values away', 400));
    } else {
      loseDataUndecidable = m.wouldLoseData;
    }
  }
  return {
    measured: true,
    formCount: m.formCount,
    // Published rather than dropped: "we could not tell" is a result, and a reader who sees
    // findings: [] beside loseDataUndecidable: 1 knows the difference between a form that is
    // fine and a form nothing could adjudicate. #1434 is the instrument that would decide it.
    loseDataUndecidable,
    findings: out,
  };
}

/** The forms probe, hoisted to ONE definition (#1433).
 *
 *  It used to be an inline joined array at the single entry-page call site. It now runs on every
 *  page the sweep visits, and two copies of a DOM probe is two things to keep in step — so there
 *  is one, exported, and the safety lock in `verify-capture-cdp.mjs` pins THIS constant rather
 *  than a call-shape regex that would have to be re-taught every time the call moves.
 *
 *  THE SAFETY PROPERTY IS UNCHANGED AND IS THE REASON THIS CAN RUN PER-PAGE AT ALL: it reads the
 *  DOM and submits nothing. No `.submit()`, no `.click()`, no dispatched event. Running a
 *  read-only probe on five pages is five reads; running a submitting one would be five side
 *  effects on someone else's software, which `assessForms`'s own docstring rules out. */
export const FORMS_PROBE = [
  '(function(){',
  "var fs=document.querySelectorAll('form');",
  "var noSub=0, lose=0, nse='', lde='';",
  'for(var i=0;i<fs.length;i++){var f=fs[i];',
  "var sub=f.querySelector('button:not([type=button]),input[type=submit],input[type=image]');",
  "var texty=f.querySelector('input:not([type=checkbox]):not([type=radio]):not([type=button]):not([type=hidden])');",
  "var name=(f.getAttribute('id')||f.getAttribute('name')||('form '+(i+1)));",
  'if(!sub&&!texty){noSub++;if(!nse)nse=name;}',
  "var act=f.getAttribute('action');",
  "var onsub=f.getAttribute('onsubmit')||f.onsubmit;",
  'if(!act&&!onsub){lose++;if(!lde)lde=name;}}',
  'return {formCount:fs.length, noSubmitPath:noSub, wouldLoseData:lose,',
  ' noSubmitExample:nse, loseDataExample:lde,',
  // #1433. Whether ANY script is loaded on this page, which is what makes the "would lose data"
  // rule decidable. An addEventListener submit handler is invisible to the attribute reads
  // above, so the rule may only convict where no script could have attached one.
  " scriptCount:document.querySelectorAll('script').length};})()",
].join('');

/** DoD row 15's "forms submit" clause, aggregated across the pages actually looked at (#1433).
 *
 *  THE DEFECT THIS EXISTS TO RETIRE. The forms check ran once, on the entry page, before the
 *  multi-page sweep began — and its answer was published as a TOP-LEVEL field, so it read as a
 *  fact about the site. Run `20260816-134142-bd` delivered a pottery site whose `contact.html`
 *  carries a real contact form, visited five pages, and banked `forms.formCount: 0`. That number
 *  was true about `index.html` and false about the site, and nothing in the record said which.
 *  Same shape as `files_scanned: 0` reported as a coder who wrote no tests (#1416): the check was
 *  not wrong about what it measured, it was wrong about what its answer COVERED.
 *
 *  THE THREE-STATE DISCIPLINE, which is the whole point:
 *    - `measured: false`            — no page was checked. Never "the forms are fine".
 *    - `pagesChecked: n, formCount: 0` — n pages were checked and genuinely have no forms.
 *    - `pagesChecked: n, formCount: k` — k forms were found and assessed across those n pages.
 *  An aggregate of zero across five checked pages and an unchecked site are different facts, and
 *  `pagesChecked` is what separates them. A page the sweep SKIPPED FOR BUDGET, one that failed to
 *  navigate, and one whose probe threw all carry no `forms` at all — so they are not counted, and
 *  a budget-truncated sweep can never inflate the denominator into looking like coverage.
 *
 *  Findings carry their page, because a finding a reader cannot locate is a finding they cannot
 *  act on. The marker is placed FIRST so that `cleanText`'s cap truncates the message rather than
 *  the attribution.
 *
 *  Pure: takes the pages array, returns a decision. The measuring lives in `run`. */
export function aggregateForms(pages) {
  const out = { measured: false, pagesChecked: 0, pagesWithForms: 0, formCount: 0, findings: [] };
  for (const p of pages || []) {
    const f = p && p.forms;
    // `measured !== true` covers every way a page can lack an answer: never visited, skipped for
    // budget, navigated but the probe threw. All three must read as "not checked", never as zero.
    if (!f || f.measured !== true || typeof f.formCount !== 'number') continue;
    out.measured = true;
    out.pagesChecked += 1;
    out.formCount += f.formCount;
    if (f.formCount > 0) out.pagesWithForms += 1;
    const where = p.entry ? '' : ` [page: ${p.url}]`;
    for (const finding of f.findings || []) out.findings.push(cleanText(`Forms${where}: ${finding}`, 500));
  }
  return out;
}

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
// primary control). Returns {clicked, selectorUsed, reason, explicitPresent, explicitVisible}.
// The two explicit* flags are what make a DECLARED miss reportable: a declared hook that matched no
// element (`explicitPresent:false`) is a delivery defect, while a declared hook that matched a hidden
// or disabled element (`explicitVisible:false`) is a different one — and the heuristic fallback below
// would have made both look identical to a working click. Never throws into the page.
function clickJs(clickSelector) {
  const sel = JSON.stringify(clickSelector || '');
  return `(function(){
    try {
      function visible(el){ if(!el) return false; var r=el.getBoundingClientRect(); var s=getComputedStyle(el);
        return r.width>0 && r.height>0 && s.visibility!=='hidden' && s.display!=='none' && !el.disabled; }
      var explicit = ${sel};
      var el = null, used = '', explicitPresent = null, explicitVisible = null;
      if (explicit) {
        var found = null;
        try { found = document.querySelector(explicit); } catch(e) { found = null; }
        explicitPresent = !!found;
        explicitVisible = visible(found);
        el = explicitVisible ? found : null;
        used = explicit;
      }
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

/** The declared-spec statuses. Every capture reports exactly one, and they are deliberately
 *  distinguishable: "the check did not run" must never read like "the check ran and found
 *  nothing". SMOKE_NOT_DECLARED is the honest no-op (no contract for this product); UNREADABLE
 *  and INVALID mean a contract WAS present and could not be honoured — a defect in the writer,
 *  not in the delivery; the two *_HOOK_MISSING are defects in the DELIVERY (the coder was told
 *  to place the hook and did not); HONOURED is the only one that means the declared behavior
 *  was actually exercised. */
export const SMOKE_NOT_DECLARED = 'not-declared';
export const SMOKE_UNREADABLE = 'unreadable';
export const SMOKE_INVALID = 'invalid-selector';
export const SMOKE_ACTION_HOOK_MISSING = 'action-hook-missing';
export const SMOKE_RESULT_HOOK_MISSING = 'result-hook-missing';
export const SMOKE_HONOURED = 'honoured';
/** A contract was read and validated but the smoke has not run yet — and might not (the block is
 *  wrapped, and a page that wedges the evaluate never reaches a verdict). Reading a file is not
 *  exercising a contract, so the read step deliberately CANNOT mint 'honoured'. */
export const SMOKE_DECLARED = 'declared';
/** The smoke did not reach a verdict at all (an evaluate that threw). Not a pass, not a failure. */
export const SMOKE_UNAVAILABLE = 'unavailable';

/** Length cap on a declared selector (mirrors acceptance.py's `_SMOKE_SELECTOR_MAX`). */
const SMOKE_SELECTOR_MAX = 120;

/** One simple selector: [attr="value"] | #id | .class | tag. Mirrors acceptance.py's
 *  `_CSS_SIMPLE_SELECTOR` — the two must admit the same language or a spec the ruler minted
 *  would be refused here (or, worse, the reverse). ASCII classes are spelled out rather than
 *  written `\w` on BOTH sides: JS's `\w` is ASCII and Python's is Unicode-aware, so the
 *  shorthand made the two sides disagree about every non-ASCII identifier. `y` (sticky) so it
 *  can be matched AT A POSITION by the scanner below rather than anchored to the whole string. */
const _CSS_SIMPLE = '(?:\\[[A-Za-z][A-Za-z0-9_-]*="[A-Za-z0-9_ -]{1,40}"\\]|#[A-Za-z][A-Za-z0-9_-]*|\\.[A-Za-z][A-Za-z0-9_-]*|[A-Za-z][A-Za-z0-9]*)';
const _CSS_SIMPLE_RE = new RegExp(_CSS_SIMPLE, 'y');

/** The whitespace a combinator may be built from. Spelled out for the same cross-repo reason
 *  as the identifier classes: an explicit set means the same thing on both sides. */
const _CSS_SPACE = ' \t\n\r\f\v';

/** Linear-time recogniser for the selector allowlist: compounds (one or more simple selectors
 *  written back to back) separated by a descendant (whitespace) or child (`>`) combinator.
 *
 *  The obvious single regex — `(?:…|tag)+(?:(?:\s*>\s*|\s+)(?:…|tag)+)*` — is a nested
 *  quantifier over an alternation whose last branch matches a bare run of letters, and V8
 *  backtracks catastrophically on it: measured 66 ms at 20 characters, 1.76 s at 24, 47.2 s at
 *  28. The `SMOKE_SELECTOR_MAX` cap does not bound that at all. Greedy consumption without
 *  backtracking is sound here because the four branches have DISJOINT first characters
 *  (`[`, `#`, `.`, a letter) and a shorter match of any branch can only be followed by another
 *  match of the same branch. Every iteration advances at least one character. */
function scanCssSelector(text) {
  let pos = 0;
  const end = text.length;
  for (;;) {
    let simples = 0;
    while (pos < end) {
      _CSS_SIMPLE_RE.lastIndex = pos;
      const m = _CSS_SIMPLE_RE.exec(text);
      if (!m) break;
      pos = _CSS_SIMPLE_RE.lastIndex;
      simples++;
    }
    if (!simples) return false;          // a character the allowlist does not admit
    if (pos >= end) return true;
    const combinatorStart = pos;
    while (pos < end && _CSS_SPACE.includes(text[pos])) pos++;
    if (pos < end && text[pos] === '>') {
      pos++;
      while (pos < end && _CSS_SPACE.includes(text[pos])) pos++;
    }
    if (pos === combinatorStart) return false;  // compound ended on an inadmissible character
    if (pos >= end) return false;               // a trailing combinator names no second compound
  }
}

/** True iff `selector` is a CSS selector the smoke contract may carry. DENY-BY-DEFAULT: a
 *  selector list (comma), a pseudo-class, functional notation, an over-long string or a
 *  non-string is refused. This is a trust boundary — the value ends up in the page's own
 *  `document.querySelector` — so it is validated here even though the writer validated it too.
 *  The length cap is a SIZE bound, not a time bound: the scan is linear, so a rejection costs
 *  the same as an acceptance and no input can wedge the capture. */
export function isValidSmokeSelector(selector) {
  if (typeof selector !== 'string') return false;
  const s = selector.trim();
  if (!s || s.length > SMOKE_SELECTOR_MAX) return false;
  return scanCssSelector(s);
}

/** One-line, control-stripped label for the findings text. Empty when unusable. */
function smokeLabel(raw) {
  return typeof raw === 'string' ? cleanText(raw, 80) : '';
}

/** Read the DECLARED behavior spec from <app-dir>/blarai-smoke.json.
 *
 *  ALWAYS returns `{spec, status}` — never a bare null — because the CALLER must be able to
 *  tell "no contract was declared" from "a contract was declared and I could not use it".
 *  Collapsing those two into a null is exactly how the declared arm stayed invisible for as
 *  long as it did. `spec` is null unless BOTH selectors clear `isValidSmokeSelector`;
 *  validate-don't-repair, so a half-valid spec is refused whole. */
export function readSmokeSpec(appDir) {
  if (!appDir) return { spec: null, status: SMOKE_NOT_DECLARED };
  const p = path.join(appDir, 'blarai-smoke.json');
  let raw;
  try {
    if (!fs.existsSync(p)) return { spec: null, status: SMOKE_NOT_DECLARED };
    raw = JSON.parse(fs.readFileSync(p, 'utf8'));
  } catch {
    return { spec: null, status: SMOKE_UNREADABLE };   // present but broken: NOT the same as absent
  }
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return { spec: null, status: SMOKE_UNREADABLE };
  const click = typeof raw.click === 'string' ? raw.click.trim() : '';
  const expectDelta = typeof raw.expectDelta === 'string' ? raw.expectDelta.trim() : '';
  if (!isValidSmokeSelector(click) || !isValidSmokeSelector(expectDelta)) {
    return { spec: null, status: SMOKE_INVALID };
  }
  return {
    spec: {
      click,
      expectDelta,
      actionLabel: smokeLabel(raw.actionLabel) || 'the main control',
      resultLabel: smokeLabel(raw.resultLabel) || 'the result region',
    },
    status: SMOKE_DECLARED,   // read, not yet exercised — the verdict comes from evaluateBehavior
  };
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

  const smokeRead = readSmokeSpec(appDir);
  const spec = smokeRead.spec;
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
    // Both the initial value and the catch below carry status UNAVAILABLE, never a passing one: a
    // smoke that did not reach a verdict must not be readable as one that did.
    let behavior = { ran: false, ok: true, changed: false, status: SMOKE_UNAVAILABLE, reason: '' };
    let textScan = { hasUndefined: false, hasNaN: false, samples: [] };
    let entryInnerText = '';   // kept so the error-text scan reads the same DOM the textScan did
    try {
      const before = await evalJson(cdp, snapshotJs(spec && spec.expectDelta));
      const click = await evalJson(cdp, clickJs(spec && spec.click));
      await sleep(500); // allow the action's async render to land
      const after = await evalJson(cdp, snapshotJs(spec && spec.expectDelta));
      entryInnerText = (after && after.innerText) || (before && before.innerText) || '';
      textScan = scanRenderedText(entryInnerText);
      behavior = evaluateBehavior(before, after, spec, click);
    } catch (e) {
      behavior = { ran: false, ok: true, changed: false, status: SMOKE_UNAVAILABLE,
        reason: 'behavior smoke skipped: ' + cleanText(String(e), 120) };
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
    // The declared-spec honesty record. `measured` answers the only question a reader of a
    // green report actually needs — did the DECLARED behavior get exercised, or did the run
    // simply not have a contract to exercise? Those are different facts and this is the one
    // place that keeps them apart. `status` is the finer reading (see the SMOKE_* constants);
    // when the read succeeded, the BEHAVIOR's own status wins, because a contract can be
    // perfectly readable and still name hooks the delivery never grew.
    const smoke = {
      declared: specDeclared,
      measured: specDeclared && behavior.ran && behavior.status === SMOKE_HONOURED,
      status: spec ? (behavior.status || SMOKE_UNAVAILABLE) : smokeRead.status,
      click: spec ? spec.click : '',
      expectDelta: spec ? spec.expectDelta : '',
      actionLabel: spec ? spec.actionLabel : '',
      resultLabel: spec ? spec.resultLabel : '',
    };
    // A contract that was PRESENT and could not be read/validated is a writer defect, and the
    // capture must say so out loud rather than quietly running the heuristic — a silent
    // degrade here is indistinguishable from a product that simply had no contract.
    if (!spec && smokeRead.status !== SMOKE_NOT_DECLARED) {
      notes.push(cleanText(
        `Behavior contract present but not usable (${smokeRead.status}): blarai-smoke.json could not `
        + `be read or its selectors failed validation, so the declared check did NOT run and this `
        + `capture fell back to the heuristic.`, 400));
    }
    // ---- EVERY DELIVERED PAGE, not just the entry (#1375, #1367) ---------------------
    // The floor rendered ONE page of a five-page site. `pieces.html` and `piece-detail.html`
    // were never opened by any instrument, so "served + loaded + zero console errors" was
    // earned on the entry page and reported for the product. The operator found both dead
    // pages himself, in under a minute, by clicking.
    //
    // ADVISORY BY CONSTRUCTION, and that is deliberate. Each extra page is recorded in its own
    // `pages[]` entry; NOTHING is merged into the top-level `console`/`pageErrors` arrays that
    // `swap_ops._web_console_error_lines` reads. So this capture cannot newly RED a build that
    // passes today -- a new way for a build to fail is the operator's ceremony, not a wiring
    // decision (the #1345 precedent, where link_lint shipped advisory for exactly this reason).
    // Promoting it is then a one-line reader change in BlarAI plus his say-so, against evidence
    // that will by then exist.
    //
    // Absent `--extra-pages` this whole block is a no-op and the sidecar is byte-identical.
    // DoD row 15, the phone-width slice. Runs AFTER the desktop screenshot and text scan, so
    // nothing above it sees a different viewport and the saved PNG is still the 1280x900 one
    // the design critic grades. The override is restored immediately afterwards for the same
    // reason — the extra-page sweep below must measure the same page a desktop visitor gets.
    //
    // 390x844 is a common phone viewport (iPhone 12-15 class). Fail-soft in every direction:
    // an override that will not apply, or a measurement that will not read, leaves
    // measured=false, which `assessPhoneWidth` treats as "could not measure" and NEVER as
    // "fits" — the three-state discipline the rest of this file keeps.
    // DoD row 15's keyboard/screen-reader slice. Measured on the DESKTOP viewport, before the
    // phone override below, because these are DOM facts and the phone pass would only add
    // reflow noise to them.
    let a11y = { measured: false, findings: [] };
    try {
      // The label lookup walks `htmlFor` rather than building a `label[for="..."]` selector.
      // That is not style: an id is untrusted page content, and interpolating it into a
      // selector string is both an injection surface and — as this line proved on its first
      // draft — a quoting hazard inside an already-quoted probe.
      a11y = assessA11yBasics(await evalJson(cdp, [
        '(function(){',
        "var imgs=document.querySelectorAll('img'), miss=0, ie='';",
        // hasAttribute, NOT alt==='' — an empty alt is the CORRECT decorative marker and
        // convicting it would punish the deliverables that got it right.
        "for(var i=0;i<imgs.length;i++){if(!imgs[i].hasAttribute('alt')){miss++;",
        "if(!ie)ie=(imgs[i].getAttribute('src')||'img').split('/').pop();}}",
        "var lbs=document.querySelectorAll('label');",
        "var fs=document.querySelectorAll('input:not([type=hidden]),select,textarea');",
        "var un=0, fe='';",
        'for(var j=0;j<fs.length;j++){var f=fs[j];',
        "var named=!!(f.getAttribute('aria-label')||f.getAttribute('aria-labelledby')||f.getAttribute('title'));",
        'if(!named&&f.id){for(var k=0;k<lbs.length;k++){if(lbs[k].htmlFor===f.id){named=true;break;}}}',
        "if(!named){named=!!f.closest('label');}",
        "if(!named){un++;if(!fe)fe=(f.getAttribute('name')||f.tagName.toLowerCase());}}",
        'return {imagesMissingAlt:miss, imgExample:ie, unlabelledFields:un, fieldExample:fe,',
        " h1Count:document.querySelectorAll('h1').length};})()",
      ].join('')));
    } catch { /* leaves measured=false — "could not look" is never "nothing to find" */ }

    // DoD row 15's forms slice, ENTRY PAGE. Reads the DOM only — see assessForms on why nothing
    // is submitted. `onsubmit` is read as an ATTRIBUTE and via the property, because a handler
    // attached with addEventListener is invisible to both and that limit is named in the
    // sidecar rather than guessed at.
    //
    // #1433: this is no longer the whole measurement. The same probe runs on every page the
    // sweep visits below, and `aggregateForms` combines them — because a site's contact form is
    // on the contact page, and looking only here published an entry-page fact as a site fact.
    let entryForms = { measured: false, findings: [] };
    try {
      entryForms = assessForms(await evalJson(cdp, FORMS_PROBE));
    } catch { /* leaves measured=false — never "the forms are fine" */ }

    let phoneWidth = { measured: false, overflows: false, overflowPx: 0 };
    try {
      await cdp.send('Emulation.setDeviceMetricsOverride',
                     { width: 390, height: 844, deviceScaleFactor: 1, mobile: true });
      await sleep(Math.min(settleMs, 800));   // let a responsive layout reflow
      const m = await evalJson(cdp, "(function(){"
        + "var d=document.documentElement, b=document.body;"
        + "var sw=Math.max(d?d.scrollWidth:0, b?b.scrollWidth:0);"
        + "var iw=window.innerWidth||0, worst='', wmax=0;"
        + "var els=document.querySelectorAll('body *');"
        + "for(var i=0;i<els.length && i<2000;i++){var r=els[i].getBoundingClientRect();"
        + "if(r.right>wmax){wmax=r.right;worst=els[i].tagName.toLowerCase()+"
        + "(els[i].className&&typeof els[i].className==='string'?'.'+els[i].className.split(' ')[0]:'');}}"
        + "return {scrollWidth:sw, innerWidth:iw, culprit:(wmax>iw+8?worst:'')};})()");
      phoneWidth = assessPhoneWidth(m);
    } catch { /* leaves measured=false — an unmeasured layout is never a passing one */ }
    try {
      await cdp.send('Emulation.setDeviceMetricsOverride',
                     { width: 1280, height: 900, deviceScaleFactor: 1, mobile: false });
      await sleep(200);
    } catch { /* the desktop override is best-effort; the sweep below still navigates */ }

    const entrySnapshot = {
      url: cleanText(url, 300),
      entry: true,
      // Set explicitly, not left to default. A record whose `visited` is absent reads the same
      // as one whose navigation failed, and "unvisited" must never be confusable with "clean"
      // -- the same three-state discipline the rest of this file keeps (#1241).
      visited: true,
      consoleErrors: errorCount(consoleEntries, pageErrors),
      textScan,
      errorText: scanErrorText(entryInnerText),
      // #1433. Per-page, exactly as `consoleErrors` already is. The top-level `forms` below is
      // now an AGGREGATE over these, so the per-page answers are what a reader adjudicates.
      forms: entryForms,
    };
    const pages = [entrySnapshot];
    const extraPages = String(args['extra-pages'] || '')
      .split(',').map((s) => s.trim()).filter(Boolean);
    // #1394. The sweep has a wall-clock budget, and a sweep that stops must SAY what it did
    // not visit. Arithmetic from the ticket: the 12-page cap times the 10s per-page wait plus
    // settle, on top of the entry page's 20s, reaches ~144s against the caller's 120s
    // EXEC_SMOKE_TIMEOUT_S. Latent at B9's six pages (~77s worst case, and real pages do not
    // exhaust their navigation timeout) — but the operator's stated direction is "a relatively
    // complex website with multiple pages", and past ~10 pages being KILLED mid-sweep goes from
    // accidental to routine. Killed is the bad shape: the caller's timeout takes the whole
    // capture, so the per-page error text this loop exists to collect is lost with it.
    //
    // So: stop deliberately and record the remainder, rather than be stopped and record
    // nothing. An unattempted page is `visited: false`, which `buildNonEntryFindings` already
    // renders as a NOT VISITED finding — "did not look" must never read as "looked and found
    // nothing", which is the #1241 shape this ticket names.
    const sweepBudgetMs = Number(args['sweep-budget-ms']) || 90000;
    const sweepDeadline = Date.now() + sweepBudgetMs;
    let budgetStopped = false;
    for (const pageUrl of extraPages) {
      const cBefore = consoleEntries.length;
      const eBefore = pageErrors.length;
      const rec = { url: cleanText(pageUrl, 300), entry: false, visited: false };
      if (budgetStopped || Date.now() >= sweepDeadline) {
        budgetStopped = true;
        rec.error = cleanText(
          `not attempted — the ${Math.round(sweepBudgetMs / 1000)}s multi-page sweep budget was `
          + 'exhausted before this page was reached', 200);
        rec.skippedForBudget = true;
        pages.push(rec);
        continue;
      }
      try {
        const pLoaded = new Promise((res) => cdp.on((m) => { if (m === 'Page.loadEventFired') res(); }));
        await cdp.send('Page.navigate', { url: pageUrl });
        await Promise.race([pLoaded, sleep(Math.min(timeoutMs, 10000))]);
        await sleep(settleMs);
        const snap = await evalJson(cdp, "(function(){return {innerText: document.body ? document.body.innerText : ''};})()");
        const innerText = (snap && snap.innerText) || '';
        // Slice, never re-read: the shared arrays accumulate across navigations, so a page's
        // own errors are exactly the entries appended since it started loading.
        const myConsole = consoleEntries.slice(cBefore);
        const myErrors = pageErrors.slice(eBefore);
        rec.visited = true;
        rec.consoleErrors = errorCount(myConsole, myErrors);
        rec.pageErrors = myErrors;
        rec.textScan = scanRenderedText(innerText);
        rec.errorText = scanErrorText(innerText);
        // #1433. DoD row 15's forms slice, on THIS page. Its own try/catch, because a probe
        // that throws must cost this page its forms answer and nothing else — the navigation,
        // the console slice and the text scan above are already banked and must survive.
        // Left ABSENT on failure rather than set to a zero: `aggregateForms` counts only pages
        // whose answer is `measured: true`, so an absence lowers coverage instead of faking it.
        try {
          rec.forms = assessForms(await evalJson(cdp, FORMS_PROBE));
        } catch { /* no `forms` key — "did not look", never "looked and found nothing" */ }
      } catch (e) {
        // A page that cannot be visited is recorded as NOT VISITED -- never as clean. An
        // unvisited page and a page with no findings must not read the same.
        rec.error = cleanText('navigate failed: ' + (e && e.message), 200);
      }
      pages.push(rec);
    }

    // #1375 item 2 (advisory). Appended AFTER the extra-page loop, because that is the first
    // moment the non-entry pages exist. `hard` above is deliberately left as computed from the
    // entry page: surfacing these must not newly fail a build.
    const nonEntryFindings = buildNonEntryFindings(pages);
    for (const f of nonEntryFindings) findings.push(f);
    // DoD row 15's phone-width slice, ADVISORY like its siblings: it joins `findings` (which
    // the operator and the reviewer read) and is deliberately kept out of `computeHard`, so it
    // cannot newly RED a build that passes today. Promoting it is a one-line reader change
    // plus his say-so — the #1345 precedent, same as link_lint and the non-entry findings.
    const phoneFinding = phoneWidthFinding(phoneWidth);
    if (phoneFinding) findings.push(phoneFinding);
    for (const f of a11y.findings) findings.push(f);   // ADVISORY, same as the two above
    // #1433. Computed HERE, after the sweep, because this is the first moment every page's forms
    // answer exists — the same reason `buildNonEntryFindings` is computed here and not earlier.
    // `hard` is deliberately left as computed from the entry page: like its siblings, this is
    // ADVISORY and is kept out of `computeHard`, so a per-page forms defect cannot newly RED a
    // build that passes today. Promoting it is a reader change plus the operator's say-so.
    const forms = aggregateForms(pages);
    for (const f of forms.findings) findings.push(f); // ADVISORY


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
      smoke,
      findings,
      // How many of `findings` came from pages beside the entry, so a reader can tell which
      // ones `hard` above accounts for and which it does not. Without this the list is
      // honest and the relationship between the list and the verdict is not.
      nonEntryFindingCount: nonEntryFindings.length,
      // #1394: published so a reader can tell a sweep that finished from one that ran out of
      // time. `pagesVisited < pagesRequested` alone cannot say WHY — a page that 404s and a
      // page never opened are both "not visited", and only one of them is a defect in the
      // deliverable rather than a bound in the instrument.
      sweepBudgetMs,
      pagesSkippedForBudget: pages.filter((p) => p.skippedForBudget).length,
      // Published whole, not as a bool: "did not measure" and "measured and it fits" are
      // different answers, and the overflow figure is what makes the finding adjudicable.
      phoneWidth,
      a11y,
      // #1433: an AGGREGATE over `pages[].forms`, not the entry page's answer. `pagesChecked`
      // is the field that makes it readable — `formCount: 0` with `pagesChecked: 5` is a site
      // with no forms, and `measured: false` is a site nothing looked at. Before this, both
      // rendered identically as `formCount: 0` and the second was being read as the first.
      forms,
      notes,
      pages,
      pagesRequested: extraPages.length + 1,
      pagesVisited: pages.filter((p) => p.entry || p.visited).length,
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
