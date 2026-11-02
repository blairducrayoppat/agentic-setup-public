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
    // #1434. THE BROWSER'S OWN ANSWER OUTRANKS BOTH ATTRIBUTE READS. `addEventListener` is the
    // normal way to wire a form and is invisible to `action`/`onsubmit`, so before listener
    // introspection existed this clause could only say "undecidable" on any page carrying a
    // script — which is nearly every page. That was honest and it was not a measurement.
    // When `DOMDebugger.getEventListeners` answered, "undecidable" is no longer available:
    // a form is convicted only when the browser reports no submit listener on it AND none on
    // any delegation target, and vindicated when one exists.
    const listeners = m.submitListeners;
    if (listeners && listeners.decided === true) {
      if (listeners.unhandled > 0) {
        const eg = m.loseDataExample ? ` (e.g. ${m.loseDataExample})` : '';
        out.push(cleanText(
          `${listeners.unhandled} form(s) have no action, no onsubmit and no submit listener${eg}`
          + ' — the browser reports no submit listener on the form, any of its ancestors or the'
          + ' window — so a native submit would reload the page and throw the typed values away'
          + ' (click and keypress handlers were not inspected)', 400));
      }
      // Decided and handled: nothing to say, and `loseDataUndecidable` stays 0. That zero is
      // the whole point of this ticket — the clause is now measurable in VERDICT, not only in
      // coverage (DoD row 15).
    } else if (m.scriptCount === 0) {
      // Introspection unavailable, but no script could have attached a listener anyway. The
      // pre-#1434 conviction, kept because it is still sound on its own terms.
      const eg = m.loseDataExample ? ` (e.g. ${m.loseDataExample})` : '';
      out.push(cleanText(
        `${m.wouldLoseData} form(s) have neither an action nor a submit handler${eg}, and the `
        + 'page loads no script that could attach one — submitting reloads the page and throws '
        + 'the typed values away', 400));
    } else {
      // Could not ask the browser, and a script might have wired it. Still undecidable, and
      // still published rather than dropped.
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
    // #1434: published so a reader can tell "no forms lose data" from "the browser was never
    // asked". decided:false with loseDataUndecidable:0 means there was nothing to adjudicate.
    // `blindSpots` = shadow hosts + iframes the document-level form census cannot see into;
    // `decided:false` with `reason` says why no verdict was reached (never a clean pass).
    submitListeners: (m.submitListeners && m.submitListeners.decided === true)
      ? { decided: true, checked: m.submitListeners.checked,
          handled: m.submitListeners.handled, unhandled: m.submitListeners.unhandled,
          blindSpots: m.submitListeners.blindSpots || 0 }
      : { decided: false, checked: 0, handled: 0, unhandled: 0,
          blindSpots: (m.submitListeners && m.submitListeners.blindSpots) || 0,
          reason: (m.submitListeners && m.submitListeners.reason) || 'not-measured' },
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

/** #1434 REVIEW FIX: every node that could legitimately hold a delegated submit listener for a
 *  given form -- the form itself, then EVERY ancestor up to and including document. The window sits above
 *  document on the event path and is asked separately by measureSubmitListeners.
 *
 *  THE DEFECT THIS RETIRES, found by independent review and reproduced against real Edge. The
 *  first version asked only `document`, `document.body` and `document.documentElement`. React 17+
 *  binds delegated listeners to the ROOT CONTAINER element (`createRoot(container)`), not to
 *  document -- so `<body><div id="root"><form>...` with the listener on `#root` was CONVICTED,
 *  one DOM level past what was checked. That is the same false-conviction class #1434 exists to
 *  retire, wearing a different depth, and the new wording made it worse by claiming "the browser
 *  was asked directly" rather than hedging.
 *
 *  Returns a FLAT handle array: form0, its ancestors..., form1, its ancestors..., in order. The
 *  companion SHAPE probe below returns the chain lengths by value, so the caller can attribute
 *  each handle back to its form. Flat because Runtime.getProperties enumerates one array level. */
export const SUBMIT_CHAIN_HANDLE_PROBE = [
  '(function(){',
  "var fs=document.querySelectorAll('form'), out=[];",
  'for(var i=0;i<fs.length;i++){var f=fs[i];',
  "var act=f.getAttribute('action');",
  "var onsub=f.getAttribute('onsubmit')||f.onsubmit;",
  'if(act||onsub)continue;',
  'var n=f;',
  'while(n){out.push(n);n=n.parentNode;}',
  '}',
  'return out;})()',
].join('');

/** #1434 REVIEW FIX: the chain LENGTHS, by value, so a flat handle list can be split per form. */
export const SUBMIT_CHAIN_SHAPE_PROBE = [
  '(function(){',
  "var fs=document.querySelectorAll('form'), lens=[];",
  'for(var i=0;i<fs.length;i++){var f=fs[i];',
  "var act=f.getAttribute('action');",
  "var onsub=f.getAttribute('onsubmit')||f.onsubmit;",
  'if(act||onsub)continue;',
  'var n=f,c=0;',
  'while(n){c++;n=n.parentNode;}',
  'lens.push(c);',
  '}',
  'return {lengths:lens};})()',
].join('');

/** Forms the document-level `querySelectorAll('form')` cannot see: shadow hosts (elements with a
 *  shadowRoot) plus iframes, counted by value. Read-only. */
export const SUBMIT_BLIND_PROBE = [
  "(function(){var c=0,all=document.querySelectorAll('*');",
  'for(var i=0;i<all.length;i++){if(all[i].shadowRoot)c++;}',
  "return {blind:c+document.querySelectorAll('iframe').length};})()",
].join('');

/** True when a `DOMDebugger.getEventListeners` reply carries a submit listener.
 *
 *  Pure, and tolerant of a reply shape it does not recognise: an unreadable answer is NOT a
 *  "no listener" answer, and the caller keeps those two apart. */
export function hasSubmitListener(reply) {
  if (!reply || !Array.isArray(reply.listeners)) return false;
  return reply.listeners.some((l) => l && l.type === 'submit');
}

/** #1434: fold the raw listener readings into the three states this file keeps.
 *
 *  `decided` is the whole point. Before this existed the "would lose data" rule could only say
 *  "undecidable" on any page carrying a script, which is nearly every page — measurable in
 *  coverage and not in verdict (DoD row 15). Now a form is convicted only when the BROWSER says
 *  no submit listener is attached to it or to any delegation target, and vindicated when one is.
 *
 *  Pure: takes readings, returns a decision. The CDP round trips live in `run`. */
export function assessSubmitListeners(readings, expectedCount = null) {
  // #1434 REVIEW FIX: `decided` must mean "every doubtful form was actually asked about". The
  // listener census and the attribute census are two SEPARATE Runtime.evaluate round trips, so a
  // DOM that mutates between them (a hydrating page) can return fewer handles than wouldLoseData
  // counted -- and the first version reported decided:true, unhandled:0, findings:[] for the forms
  // it never asked about. A confident clean pass over an incomplete population is the
  // "measured:true beside files_scanned:0" shape this project keeps retiring.
  if (readings && Array.isArray(readings.forms) && readings.readable === true
      && Number.isFinite(expectedCount) && readings.forms.length < expectedCount) {
    return { measured: true, decided: false, checked: readings.forms.length,
             handled: 0, unhandled: 0, blindSpots: readings.blindSpots || 0,
             reason: 'census-shortfall', shortfall: expectedCount - readings.forms.length };
  }
  if (!readings || !Array.isArray(readings.forms) || readings.readable !== true) {
    // Could not ask, or the browser would not answer. NOT "no listeners" — the same three-state
    // discipline assessPhoneWidth and assessContentWidth keep.
    return { measured: false, decided: false, checked: 0, handled: 0, unhandled: 0,
             blindSpots: 0, reason: 'unreadable' };
  }
  const blindSpots = readings.blindSpots || 0;
  // Zero forms examined is not a verdict: the probe could not look (forms in shadow roots or
  // iframes are invisible to it) or there was nothing to adjudicate. Either way, not "clean".
  if (readings.forms.length === 0) {
    return { measured: true, decided: false, checked: 0, handled: 0, unhandled: 0,
             blindSpots, reason: 'no-forms-examined' };
  }
  let handled = 0, unhandled = 0;
  for (const own of readings.forms) {
    if (own === true) handled += 1;
    else unhandled += 1;
  }
  return { measured: true, decided: true, checked: readings.forms.length, handled, unhandled, blindSpots };
}


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
  const out = { measured: false, pagesChecked: 0, pagesWithForms: 0, formCount: 0, findings: [],
    // #1434 round 2: a page whose only forms sit in shadow roots / iframes reads formCount 0 and
    // findings [] -- "looked, no forms" -- unless the unread places are carried up here too.
    // `blindSpots` = total unread places; `pagesWithBlindSpots` = pages that had any;
    // `pagesWithUnreadForms` = pages that read formCount 0 while having some (nothing was decided).
    blindSpots: 0, pagesWithBlindSpots: 0, pagesWithUnreadForms: 0 };
  for (const p of pages || []) {
    const f = p && p.forms;
    // `measured !== true` covers every way a page can lack an answer: never visited, skipped for
    // budget, navigated but the probe threw. All three must read as "not checked", never as zero.
    if (!f || f.measured !== true || typeof f.formCount !== 'number') continue;
    out.measured = true;
    out.pagesChecked += 1;
    out.formCount += f.formCount;
    if (f.formCount > 0) out.pagesWithForms += 1;
    const blind = f.submitListeners && typeof f.submitListeners.blindSpots === 'number'
      ? f.submitListeners.blindSpots : 0;
    if (blind > 0) {
      out.blindSpots += blind;
      out.pagesWithBlindSpots += 1;
      if (f.formCount === 0) out.pagesWithUnreadForms += 1;
    }
    const where = p.entry ? '' : ` [page: ${p.url}]`;
    for (const finding of f.findings || []) out.findings.push(cleanText(`Forms${where}: ${finding}`, 500));
  }
  return out;
}

/** The width this check measures at, and it is NOT the 1280 the screenshot uses (#1435).
 *
 *  1280 cannot answer the question. The commonest page container on the web is
 *  `max-width: 1200px; margin: 0 auto`, which at a 1265px layout viewport leaves a 32px gutter —
 *  numerically indistinguishable from a page with no container at all and a single `1rem` of
 *  padding. Measured on the banked deliveries: a CORRECT container read 33px and a MISSING one
 *  read 32px. A rule cannot separate those, and one tuned until it did would be measuring noise.
 *
 *  At 1600 the same container reads ~200px and the same bare padding still reads 16px, so the
 *  two stop overlapping. It is also closer to the screen the operator actually reviewed on: his
 *  complaint was that text ran the full width of his monitor, and monitors are not 1280 wide.
 *
 *  Overridden and restored around each measurement, never left applied — the screenshot, the
 *  design critic and the phone pass must all still see the 1280x900 page. */
const CONTENT_WIDTH_VIEWPORT_PX = 1600;

/** The content-width probe (#1435). ONE definition, two call sites, same reasons as FORMS_PROBE.
 *
 *  READS THE LAYOUT AND CHANGES NOTHING. No click, no submit, no dispatched event, no style
 *  write. A Range is created to measure text, which is a detached object: it does not touch the
 *  document and does not disturb the user's selection.
 *
 *  IT MEASURES WHERE THE GLYPHS ARE, NOT WHERE THE BOX IS, and that is the single most important
 *  decision in this file. A centred `<h2>` inside a full-bleed band has a box spanning the whole
 *  window and text sitting comfortably in the middle; a left-aligned `<h1>` with no wrapper has
 *  a box spanning the whole window and text starting at pixel zero. Those are opposite facts and
 *  the element box reports them identically. `Range.getClientRects()` returns the actual line
 *  boxes, so centred, right-aligned and short headings are all measured honestly.
 *
 *  Measured on the banked deliveries, this is exactly what separates the two pages of ONE
 *  delivery that the operator judged differently: `home.html`'s edge-spanning headings are
 *  `.section-header { text-align: center }` and their glyphs are nowhere near the edge, while
 *  `pieces.html`'s page title sits in `.page-header` — a class the stylesheet never defines — and
 *  its glyphs start at zero.
 *
 *  THE REST OF THE FILTERING, and every clause is a precision decision:
 *    - `p,h1..h6,li,blockquote` — BODY TEXT AND HEADINGS. A `<section>`, a `<div>` and an `<img>`
 *      are all legitimately full-width; a paragraph is what a person reads along.
 *    - anything inside `header,nav,footer,[role=banner],[role=navigation],[role=contentinfo]` is
 *      SKIPPED. Page chrome is edge-to-edge by design across most of the web.
 *    - `el.querySelector(sel)` is SKIPPED, so only text LEAVES are measured and an `<li>`
 *      wrapping a `<p>` cannot be counted twice.
 *    - under 8 characters is SKIPPED: "Home", "$25.99". An `<h1>Contact Us</h1>` is ten, and is
 *      exactly the block the operator saw starting at pixel zero, so the floor stays low.
 *
 *  IT ALSO ANSWERS WHY. A wrapper class that the HTML applies and no stylesheet defines is the
 *  sharpest form of this defect: every file looks right on its own and the page has no container
 *  at all. That is decidable here and nowhere else — walk the ancestors of a block that reached
 *  the edge, and report class names that appear in no rule of any readable stylesheet.
 *  `stylesheetsRead` gates the claim: a cross-origin sheet cannot be enumerated, and "I could not
 *  read the CSS" must never be published as "the class is undefined".
 *
 *  Per-block geometry only; NO verdict. The thresholds live in `assessContentWidth`, so the
 *  judgement is a pure function of numbers a unit test can drive without a browser. */
export const CONTENT_WIDTH_PROBE = [
  '(function(){',
  'var vw=(document.documentElement&&document.documentElement.clientWidth)||window.innerWidth||0;',
  "var sel='p,h1,h2,h3,h4,h5,h6,li,blockquote';",
  "var chrome='header,nav,footer,[role=banner],[role=navigation],[role=contentinfo]';",
  // Every class name any readable stylesheet defines a rule for. Grouping rules (@media,
  // @supports) are walked, or a class defined only inside a breakpoint would read as undefined.
  'var defined=null, sheetsRead=0;',
  'try{var d={};var ss=document.styleSheets;',
  'var walk=function(rules){for(var r=0;r<rules.length;r++){var rule=rules[r];',
  'if(rule.selectorText){var mm=rule.selectorText.match(/\\.[A-Za-z_-][A-Za-z0-9_-]*/g);',
  'if(mm)for(var q=0;q<mm.length;q++)d[mm[q].slice(1)]=1;}',
  'if(rule.cssRules)walk(rule.cssRules);}};',
  'for(var si=0;si<ss.length;si++){var cr=null;',
  // A cross-origin sheet throws here. Skipped, and it lowers sheetsRead rather than being
  // silently treated as a sheet that defined nothing.
  'try{cr=ss[si].cssRules;}catch(e){cr=null;}',
  'if(!cr)continue;sheetsRead++;walk(cr);}',
  'if(sheetsRead>0)defined=d;}catch(e){defined=null;}',
  'var offColumn=function(e){for(var a=e;a&&a.nodeType===1;a=a.parentElement){',
  'var c=getComputedStyle(a);',
  "if(c.position==='fixed'||c.position==='sticky')return true;",
  'if(parseFloat(c.opacity)===0)return true;',
  "if(c.clip&&c.clip!=='auto'&&c.position==='absolute')return true;",
  "if(c.overflow!=='visible'&&(a.clientWidth<=1||a.clientHeight<=1))return true;}",
  'return false;};',
  'var els=document.querySelectorAll(sel), blocks=[], capped=false;',
  'var rng=document.createRange();',
  'for(var i=0;i<els.length;i++){',
  'if(blocks.length>=400){capped=true;break;}',
  'var el=els[i];',
  'if(el.closest(chrome))continue;',
  'if(el.querySelector(sel))continue;',
  "var t=(el.textContent||'').replace(/\\s+/g,' ').trim();",
  'if(t.length<8)continue;',
  'var s=getComputedStyle(el);',
  "if(s.display==='none'||s.visibility==='hidden')continue;",
  // Not part of the page's reading column: a fixed or sticky ancestor (cookie banner, floating
  // widget), an ancestor at opacity 0, or a visually-hidden clipped box (skip-link, sr-only).
  // visibility:hidden is inherited so the check above covers it; these three are not.
  'if(offColumn(el))continue;',
  // THE GLYPH MEASUREMENT. Line boxes, not the element box.
  'var lo=Infinity, hi=-Infinity;',
  'try{rng.selectNodeContents(el);var rs=rng.getClientRects();',
  'for(var k=0;k<rs.length;k++){var qr=rs[k];',
  'if(qr.width<=0||qr.height<=0)continue;',
  'if(qr.left<lo)lo=qr.left;if(qr.right>hi)hi=qr.right;}}catch(e){}',
  'if(!isFinite(lo)||!isFinite(hi))continue;',
  // Wholly outside the window (a skip-link parked at left:-9999px) is not on the page a visitor sees.
  'if(hi<=0||lo>=vw)continue;',
  // The NEAREST edge. Text flush against either side is the defect; a short left-aligned title
  // at x=0 has an enormous right-hand gutter and is still flush against the window.
  'var g=Math.round(Math.min(lo, vw-hi));',
  "var cn=(el.className&&typeof el.className==='string')?el.className.trim():'';",
  "var name=el.tagName.toLowerCase()+(cn?'.'+cn.split(/\\s+/)[0]:'');",
  'var undef=[];',
  'if(defined){var a=el;',
  'while(a&&a!==document.body&&undef.length<4){',
  "var ac=(a.className&&typeof a.className==='string')?a.className.trim():'';",
  'if(ac){var ps=ac.split(/\\s+/);',
  'for(var p2=0;p2<ps.length;p2++){',
  'if(ps[p2]&&!defined[ps[p2]]&&undef.indexOf(ps[p2])<0)undef.push(ps[p2]);}}',
  'a=a.parentElement;}}',
  'blocks.push({tag:name, chars:t.length, gutterPx:g, text:t.slice(0,40), undefinedClasses:undef});',
  '}',
  'return {viewportPx:vw, blocks:blocks, capped:capped, stylesheetsRead:sheetsRead};})()',
].join('');

/** WHAT THIS CHECK CANNOT SEE, and WHAT IT MAY OVER-REPORT (#1435). Published in the sidecar as
 *  `contentWidth.cannotSee` so a reader adjudicating a finding sees the limits next to it. The
 *  check is ADVISORY; none of these is tuned away with a threshold, because the first group is a
 *  design judgement no DOM fact decides. */
export const CONTENT_WIDTH_CANNOT_SEE = Object.freeze([
  'MAY OVER-REPORT: a left-aligned full-bleed hero, a docs-style sidebar/aside or a banner whose text sits inside a deliberate 16-24px padding reads as flush to the edge (within the 24px tolerance) when the main content is in fact contained.',
  'MAY OVER-REPORT: a deliberate full-bleed editorial layout, and a container whose max-width is at or above the measurement width.',
  'MAY UNDER-REPORT: fixed or sticky elements (cookie banners, floating sidebars), opacity:0 and visually-hidden skip-links are skipped, so flush text inside one is not counted.',
  'FALSE NEGATIVE: a page with a single flush paragraph (fewer than 2 edge blocks, or under 40 edge characters) is judgeable but never unconstrained.',
  'FALSE NEGATIVE: only p, h1-h6, li and blockquote leaves are measured; text held in a bare div or span, or in header/nav/footer, is never judged (such a page reads judgeable=false).',
  'FALSE NEGATIVE: the probe stops at 400 blocks in document order (published as `capped`); edge text after that is unseen.',
  'NOT MEASURED: line height, font size, column count, or whether an existing constraint is a good measure.',
]);

/** How close a line of text may come to the window edge before it counts as flush against it.
 *  Not zero: a hairline rounding artefact should not convict. Not large: at the measurement
 *  width above, a real container leaves ~200px, so anything in this range is bare padding at
 *  best. Measured on the banked deliveries, the nearest correct layout reads 32px. */
const CONTENT_WIDTH_GUTTER_PX = 24;
/** THE NEAR-TWIN GUARD. One element at the edge is a pull-quote, a breadcrumb, a full-bleed
 *  caption — and correct. Two or more, carrying real words, is a page with nothing holding its
 *  content in. Deliberately NOT a share-of-the-page rule: the delivered gallery page has a
 *  correctly gridded card list under a page title that starts at pixel zero, so the broken text
 *  is a SMALL share of a page that is nonetheless broken where the operator looked first. */
const CONTENT_WIDTH_MIN_EDGE_BLOCKS = 2;
const CONTENT_WIDTH_MIN_EDGE_CHARS = 40;

/** DoD row 15, the DESKTOP half of "the layout survives a width" (#1435).
 *
 *  THE DEFECT, AND WHY THE PHONE CHECK IS BLIND TO IT. `assessPhoneWidth` above asks one
 *  question — is content WIDER than the viewport? On 2026-08-16 the operator opened a delivered
 *  pottery site and his verdict was "not good"; the pages had no width constraint, so every
 *  heading and paragraph began at pixel zero and ran the full width of his monitor. That run's
 *  own sidecar recorded `phoneWidth: {measured:true, overflows:false, overflowPx:0}`. True, and
 *  useless: unconstrained content at 390px is not wider than 390px, so an unwrapped page and a
 *  correctly wrapped one produce an IDENTICAL verdict. A check that cannot distinguish the
 *  defect from its absence is not a passing check (#1241).
 *
 *  So this asks the opposite question at a desktop width: does the page's own text run flush
 *  against the edge of the window, with nothing holding it in?
 *
 *  THE VERDICT IS PER PAGE, and that is a requirement rather than an implementation detail. A
 *  delivery is not uniformly wrapped or unwrapped: measured on `20260817-070902`, the contact
 *  page renders as a neat centred card while the gallery page in the SAME build runs flush to
 *  the left edge, because `.contact-container` is defined and `.page-container` is applied and
 *  defined nowhere. A whole-site verdict would have hidden one behind the other, so every page
 *  carries its own answer and `aggregateContentWidth` publishes counts rather than a site-wide
 *  pass or fail.
 *
 *  IT MUST NOT BE IMPLEMENTED BY LOOKING AT CLASS NAMES. That delivery uses `container`,
 *  `page-container`, `max-width-container`, `contact-container`, `header-container` and
 *  `hero-content`, and only some are defined; a name-matching rule would have read
 *  `page-container` as a success. The verdict comes from measured geometry alone. The class
 *  names appear in the FINDING, never in the decision.
 *
 *  PRECISION FIRST, because the honest near-twin is common and correct. Full-bleed heroes, nav
 *  bars, footers and centred section headings are edge-to-edge on purpose, and a rule that
 *  convicts them nags a coder into breaking working design and ends up switched off. Three
 *  independent guards keep them out: the probe skips page chrome; it measures where the glyphs
 *  actually are, so centred text in a full-bleed band is correctly nowhere near the edge; and a
 *  verdict needs at least two blocks carrying real words, so one stray element cannot convict.
 *
 *  WHAT IT CANNOT SEE, named rather than left to be discovered. A container whose `max-width` is
 *  at or above the measurement width has no gutter to find and will be reported — true at that
 *  width, harmless to fix, but not the defect this is about. It says nothing about line height,
 *  font size, column count, or whether a constraint that exists is a GOOD measure: text held to
 *  1500px is "constrained" here and still punishing to read. It cannot tell a deliberately
 *  full-bleed editorial layout from a forgotten container, because no DOM fact separates them.
 *
 *  Pure: takes measured numbers, returns a decision. The measuring lives in `run`. */
export function assessContentWidth(m, gutterTolerancePx = CONTENT_WIDTH_GUTTER_PX) {
  // "Could not measure" is NOT "the layout is fine" — the discipline the whole file keeps.
  if (!m || !Array.isArray(m.blocks)
      || typeof m.viewportPx !== 'number' || !Number.isFinite(m.viewportPx) || m.viewportPx <= 0) {
    return { measured: false, judgeable: false, unconstrained: false, findings: [] };
  }
  const sheetsRead = Number.isFinite(m.stylesheetsRead) ? m.stylesheetsRead : 0;
  let blocksMeasured = 0, textChars = 0, edgeBlocks = 0, edgeChars = 0;
  let minGutterPx = 0, example = '', exampleChars = -1;
  const undefinedClasses = [];
  for (const b of m.blocks) {
    if (!b || typeof b.gutterPx !== 'number' || !Number.isFinite(b.gutterPx)) continue;
    const chars = Number.isFinite(b.chars) ? b.chars : 0;
    blocksMeasured += 1;
    textChars += chars;
    if (b.gutterPx > gutterTolerancePx) continue;
    minGutterPx = edgeBlocks === 0 ? b.gutterPx : Math.min(minGutterPx, b.gutterPx);
    edgeBlocks += 1;
    edgeChars += chars;
    // The widest-read example, not the first: a reader adjudicating this against the screenshot
    // should be pointed at the block carrying the most text, which is the one they will see.
    if (chars > exampleChars) {
      exampleChars = chars;
      const words = cleanText(b.text || '', 40);
      example = cleanText(b.tag || '', 40) + (words ? ` "${words}…"` : '');
    }
    // Only claimed when a stylesheet was actually enumerated. A sheet this probe could not read
    // is a reason to say nothing, never a reason to accuse a class of not existing.
    if (sheetsRead > 0) {
      for (const c of Array.isArray(b.undefinedClasses) ? b.undefinedClasses : []) {
        if (typeof c === 'string' && c && undefinedClasses.length < 3
            && !undefinedClasses.includes(c)) {
          undefinedClasses.push(cleanText(c, 40));
        }
      }
    }
  }
  // A page with no body text at all was LOOKED AT and cannot be judged. Third state, published.
  const judgeable = blocksMeasured > 0;
  const unconstrained = judgeable
    && edgeBlocks >= CONTENT_WIDTH_MIN_EDGE_BLOCKS
    && edgeChars >= CONTENT_WIDTH_MIN_EDGE_CHARS;
  const findings = [];
  if (unconstrained) {
    const many = undefinedClasses.length > 1;
    const why = undefinedClasses.length
      ? `The wrapper ${many ? 'classes' : 'class'} `
        + `${undefinedClasses.map((c) => `"${c}"`).join(', ')} ${many ? 'are' : 'is'} applied in `
        + `the HTML but defined in no stylesheet, so ${many ? 'they constrain' : 'it constrains'} `
        + 'nothing. '
      : '';
    findings.push(cleanText(
      `Body text runs flush to the edge at ${Math.round(m.viewportPx)}px wide: ${edgeBlocks} of `
      + `${blocksMeasured} text blocks start within ${Math.round(minGutterPx)}px of the window `
      + `edge (e.g. ${example || 'a paragraph'}). ${why}`
      + 'Wrap the page content in a width-limited element (a max-width plus margin: 0 auto). '
      + 'Headers, navs, footers and fixed banners were excluded. Advisory: a padded left-aligned '
      + 'hero or sidebar may false-positive (see contentWidth.cannotSee).',
      600));
  }
  return {
    measured: true,
    judgeable,
    unconstrained,
    viewportPx: Math.round(m.viewportPx),
    blocksMeasured,
    edgeBlocks,
    textChars,
    edgeChars,
    // NULL, not 0, when nothing came near the edge. A zero here would read as "text touches the
    // window edge" on precisely the pages where nothing does — the same three-state confusion
    // this check exists to end, one field down.
    minGutterPx: edgeBlocks > 0 ? Math.round(minGutterPx) : null,
    example,
    // Published even when empty, and distinct from "no stylesheet was readable" below.
    undefinedClasses,
    stylesheetsRead: sheetsRead,
    // The probe stops at 400 blocks. A truncated scan is still a sample of the page, but a reader
    // comparing two runs deserves to know the number came from a bounded walk.
    capped: m.capped === true,
    findings,
  };
}

/** DoD row 15's desktop-width clause, aggregated across the pages actually looked at (#1435).
 *
 *  COUNTS, NEVER A SITE-WIDE VERDICT. The delivery that caused this ticket has a contact page
 *  that is fine and a gallery page that is not, and either a site-level pass or a site-level
 *  fail would have been a lie about half of it. So the aggregate reports how many pages were
 *  checked, how many could be judged, and how many run flush to the edge, and every finding
 *  names its page.
 *
 *  Same denominator discipline as `aggregateForms`: a page skipped for budget, one that failed
 *  to navigate, or one whose probe threw carries no `contentWidth` at all, so it lowers coverage
 *  instead of faking it. `pagesJudged` is separate from `pagesChecked` because a page with no
 *  body text was looked at and still cannot be spoken for. */
export function aggregateContentWidth(pages) {
  const out = { measured: false, pagesChecked: 0, pagesJudged: 0, pagesUnconstrained: 0, findings: [], cannotSee: CONTENT_WIDTH_CANNOT_SEE.slice() };
  for (const p of pages || []) {
    const c = p && p.contentWidth;
    if (!c || c.measured !== true) continue;
    out.measured = true;
    out.pagesChecked += 1;
    if (c.judgeable === true) out.pagesJudged += 1;
    if (c.unconstrained === true) out.pagesUnconstrained += 1;
    const where = p.entry ? '' : ` [page: ${p.url}]`;
    // Marker FIRST so the cap truncates the message rather than the attribution.
    for (const finding of c.findings || []) out.findings.push(cleanText(`Layout${where}: ${finding}`, 700));
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

/** Run the content-width probe at a WIDE desktop viewport, then put 1280x900 back (#1435).
 *
 *  The override is the whole reason this is a helper rather than an inline evaluate. At 1280 a
 *  correct 1200px container and a missing container are 33px and 32px apart — see
 *  `CONTENT_WIDTH_VIEWPORT_PX` — so the measurement has to happen somewhere the two separate.
 *
 *  RESTORED IN A `finally`, not after the call. If the probe throws, the override must still come
 *  off: a wide viewport left applied would silently change the screenshot, the design critic's
 *  input, the phone pass and every page swept after it. That is the failure mode the existing
 *  phone-pass restore exists for, and it costs nothing to make this one unconditional. */
async function measureContentWidth(cdp, settleMs) {
  try {
    await cdp.send('Emulation.setDeviceMetricsOverride',
                   { width: CONTENT_WIDTH_VIEWPORT_PX, height: 900, deviceScaleFactor: 1, mobile: false });
    await sleep(Math.min(settleMs, 400));   // let a responsive layout reflow before it is measured
    return await evalJson(cdp, CONTENT_WIDTH_PROBE);
  } finally {
    await cdp.send('Emulation.setDeviceMetricsOverride',
                   { width: 1280, height: 900, deviceScaleFactor: 1, mobile: false }).catch(() => {});
    await sleep(120);
  }
}

/** Shadow hosts + iframes on the page, as context for the sidecar (never a verdict). Best effort. */
async function countBlindSpots(cdp) {
  try {
    const b = await cdp.send('Runtime.evaluate',
      { expression: SUBMIT_BLIND_PROBE, returnByValue: true });
    const n = b && b.result && b.result.value && b.result.value.blind;
    return Number.isFinite(n) ? n : 0;
  } catch { return 0; }
}

/** #1434: ask the browser which of the doubtful forms actually have a submit listener.
 *
 *  The CDP dance the attribute reads cannot do: `Runtime.evaluate` returning HANDLES rather than
 *  values, `Runtime.getProperties` to walk the returned array into per-element `objectId`s, then
 *  `DOMDebugger.getEventListeners` on each. Each form's ancestor chain and the window are asked, because a
 *  listener on any of them handles the form.
 *
 *  FAIL-SOFT AND FAIL-HONEST. Every failure path returns `readable:false`, which `assessSubmitListeners`
 *  turns into "undecidable" — never into "no listener". A browser that will not answer must not be
 *  able to manufacture a conviction. Handles are released in a `finally` so a page with many forms
 *  cannot leak them across the sweep. */
export async function measureSubmitListeners(cdp) {
  const release = [];
  try {
    // Chain SHAPE first (by value): how many nodes belong to each doubtful form.
    const shape = await cdp.send('Runtime.evaluate',
      { expression: SUBMIT_CHAIN_SHAPE_PROBE, returnByValue: true });
    const lengths = shape && shape.result && shape.result.value && Array.isArray(shape.result.value.lengths)
      ? shape.result.value.lengths : null;
    if (!lengths) return { readable: false, forms: [] };
    if (lengths.length === 0) {
      return { readable: true, forms: [], blindSpots: await countBlindSpots(cdp) };
    }

    // Then the flat HANDLE list: form0, its ancestors..., form1, its ancestors...
    const arr = await cdp.send('Runtime.evaluate',
      { expression: SUBMIT_CHAIN_HANDLE_PROBE, returnByValue: false });
    const arrId = arr && arr.result && arr.result.objectId;
    if (!arrId) return { readable: false, forms: [] };
    release.push(arrId);
    const props = await cdp.send('Runtime.getProperties', { objectId: arrId, ownProperties: true });
    const ids = (props && Array.isArray(props.result) ? props.result : [])
      .filter((x) => x && /^\d+$/.test(x.name) && x.value && x.value.objectId)
      .map((x) => x.value.objectId);
    for (const id of ids) release.push(id);

    // The flat list must match the shape exactly, or attribution would be guesswork.
    const need = lengths.reduce((a, b) => a + b, 0);
    if (ids.length !== need) return { readable: false, forms: [] };

    // Walk each form's own chain: the form itself, then every ancestor up to document.
    // A listener ANYWHERE on that chain handles the form -- that is what delegation IS.
    const forms = [];
    let cursor = 0;
    for (const len of lengths) {
      let handled = false;
      for (let k = 0; k < len; k += 1) {
        if (!handled) {
          const r = await cdp.send('DOMDebugger.getEventListeners', { objectId: ids[cursor + k] });
          if (hasSubmitListener(r)) handled = true;
        }
      }
      forms.push(handled);
      cursor += len;
    }
    // Above document on the event path sits the window; a listener there handles every form
    // still unhandled. Asked once, and only when it could change the answer.
    if (forms.some((h) => !h)) {
      const w = await cdp.send('Runtime.evaluate',
        { expression: 'window', returnByValue: false });
      const wId = w && w.result && w.result.objectId;
      if (!wId) return { readable: false, forms: [] };
      release.push(wId);
      const wr = await cdp.send('DOMDebugger.getEventListeners', { objectId: wId });
      if (hasSubmitListener(wr)) for (let i = 0; i < forms.length; i += 1) forms[i] = true;
    }
    const blindSpots = await countBlindSpots(cdp);
    return { readable: true, forms, blindSpots };
  } catch {
    // Unsupported domain, closed target, anything at all: undecidable, never a conviction.
    return { readable: false, forms: [] };
  } finally {
    for (const objectId of release) {
      try { await cdp.send('Runtime.releaseObject', { objectId }); } catch { /* best effort */ }
    }
  }
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

    // #1435. DoD row 15's DESKTOP-width slice. Measured HERE for two reasons, both locked:
    //  (1) BEFORE the behavior-smoke click below. The heuristic click takes the first visible
    //      link/button, which is often a nav link, and a click that navigates leaves the browser
    //      on a DIFFERENT page: measured after it, the entry row described the wrong page, in
    //      both polarities (a well-built page convicted with another page's text, a broken one
    //      reported clean while the sidecar named the URL it never measured).
    //  (2) before the phone override, because the whole question is what a desktop visitor sees.
    //      Measuring it at 390px would ask the same blind question the phone check already asks.
    let entryContentWidth = { measured: false, judgeable: false, unconstrained: false, findings: [] };
    try {
      entryContentWidth = assessContentWidth(await measureContentWidth(cdp, settleMs));
    } catch { /* leaves measured=false — an unmeasured layout is never a passing one */ }

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
      {
        const fm = await evalJson(cdp, FORMS_PROBE) || {};
        entryForms = assessForms(Object.assign(fm,
          { submitListeners: assessSubmitListeners(await measureSubmitListeners(cdp), fm.wouldLoseData) }));
      }
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
      // #1435, same shape and the same reason: the top-level `contentWidth` is an aggregate over
      // these, so "which page runs edge-to-edge" is answerable rather than inferred.
      contentWidth: entryContentWidth,
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
          {
            const fm2 = await evalJson(cdp, FORMS_PROBE) || {};
            rec.forms = assessForms(Object.assign(fm2,
              { submitListeners: assessSubmitListeners(await measureSubmitListeners(cdp), fm2.wouldLoseData) }));
          }
        } catch { /* no `forms` key — "did not look", never "looked and found nothing" */ }
        // #1435. Same per-page treatment, its own try/catch for the same reason: a probe that
        // throws costs this page its width answer and nothing else. Left ABSENT on failure, so
        // `aggregateContentWidth` lowers coverage rather than counting a page it never read.
        // PER PAGE is the point — one delivery can have a wrapped contact page and an unwrapped
        // gallery page, and a site-level answer hides one behind the other.
        try {
          rec.contentWidth = assessContentWidth(await measureContentWidth(cdp, settleMs));
        } catch { /* no `contentWidth` key — "did not look", never "looked and it was fine" */ }
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
    // #1435, ADVISORY like every one of its siblings and for the identical reason: the operator
    // was asked directly whether "the page has no margins" should fail a build outright, and his
    // answer on 2026-08-16 was "probably just reported". So it joins `findings`, which a human
    // reads, and stays out of `computeHard`. Promoting it to blocking is a new way for a build to
    // fail, which is his ceremony — one reader change away, against evidence that will exist by
    // then. Locked in verify-capture-cdp.mjs against computeHard growing a width input.
    const contentWidth = aggregateContentWidth(pages);
    for (const f of contentWidth.findings) findings.push(f); // ADVISORY


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
      // #1435: an AGGREGATE over `pages[].contentWidth`. Three readings, deliberately distinct:
      // `measured: false` is a site nothing looked at; `pagesJudged: 0` with `pagesChecked: 5` is
      // a site with too little body text for this rule to speak to; `pagesUnconstrained: n` is
      // the count of pages whose body text runs edge-to-edge at the desktop width.
      contentWidth,
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
