# review-website-report.ps1 — the review page: the product and the run's CLAIMS, side by side (#1343).
#
# A verdict is not reviewable. "GREEN" tells the operator nothing he can check. What makes his
# judgement a MEASUREMENT rather than an impression is seeing the plan's own account next to the
# thing it describes: these pages were built, THIS ONE WAS SKIPPED and here is the reason the
# system gave, the acceptance oracle asserted these five things, the design reviewer stopped
# because it hit its iteration cap.
#
# #1342 is the case that fixes the design: a run graded GREEN having silently dropped a page the
# operator asked for in his own words. The skip and its reason were in the run record all along.
# Nothing surfaced them, so the omission was invisible and the GREEN was believed.
#
# Therefore this page's rule: anything the run DID NOT do is rendered at least as prominently as
# what it did. A report that only lists successes is how the last one got past everybody.

Set-StrictMode -Version Latest

function ConvertTo-ReviewHtmlText {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}

function New-WebsiteReviewReport {
    <#  Render the review page. $Claims comes from Read-RunClaims; $Build from Get-WebsiteBuilds;
        $Clauses from Get-ReviewClauses. Absent claims render as an explicit "not recorded" — never
        as a clean empty section, which would read as "nothing was skipped" when the truth is "we do
        not know". The same rule governs the checklist: a missing clause file says so in words, and
        never renders an empty list that reads as "nothing was asked for". #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Build,
        [Parameter(Mandatory)][AllowNull()]$Claims,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$OutPath,
        [string[]]$Pages = @(),
        [AllowNull()]$Clauses = $null,
        [AllowNull()]$Links = $null,
        [AllowNull()]$Exam = $null,
        [AllowNull()]$Media = $null
    )

    # The drift check belongs to the library this page is always loaded beside. If it is missing the
    # page would silently render "no drift" — a checked-and-clean claim from an unrun check — so it
    # refuses instead.
    if (-not (Get-Command Get-ClauseGoalDrift -ErrorAction SilentlyContinue)) {
        throw 'review-website-report.ps1 requires review-website-lib.ps1 to be dot-sourced first.'
    }

    $e = { param($s) ConvertTo-ReviewHtmlText $s }
    $site = "http://127.0.0.1:$Port"

    # --- what the run did not do, first ---
    $notDone = ''
    if ($Claims -and $Claims.Found) {
        $rows = @()
        foreach ($t in @($Claims.Skipped)) {
            $rows += "<tr><td class=`"id`">$(& $e $t.Id)</td><td class=`"st skip`">SKIPPED</td><td class=`"why`">$(& $e $t.Detail)</td></tr>"
        }
        foreach ($t in @($Claims.Parked)) {
            $rows += "<tr><td class=`"id`">$(& $e $t.Id)</td><td class=`"st park`">PARKED</td><td class=`"why`">$(& $e $t.Detail)</td></tr>"
        }
        foreach ($t in @($Claims.Other)) {
            $rows += "<tr><td class=`"id`">$(& $e $t.Id)</td><td class=`"st other`">$(& $e $t.Status.ToUpper())</td><td class=`"why`">$(& $e $t.Detail)</td></tr>"
        }
        if ($rows.Count -gt 0) {
            $notDone = @"
<section class="alert">
  <h2>What the run did <em>not</em> build</h2>
  <p class="lede">These were in the plan and did not ship. The reason is the system's own words &mdash;
     read it sceptically: a task skipped because &ldquo;the oracle already passed&rdquo; is only as
     trustworthy as that oracle.</p>
  <table><thead><tr><th>Task</th><th>State</th><th>Reason given</th></tr></thead>
  <tbody>$($rows -join "`n")</tbody></table>
</section>
"@
        } else {
            $notDone = '<section class="ok"><h2>What the run did <em>not</em> build</h2><p>Nothing was skipped or parked &mdash; every planned task shipped.</p></section>'
        }
    } else {
        $notDone = '<section class="unknown"><h2>What the run did <em>not</em> build</h2><p><strong>Not recorded.</strong> No run record was found for this build, so whether anything was skipped is <em>unknown</em> &mdash; not &ldquo;nothing&rdquo;.</p></section>'
    }

    # --- the pictures: are they the RIGHT pictures, in the right places? (#1345) ---
    # His two remaining complaints from 2026-08-08 live here, and neither is a broken link.
    # Four states as everywhere else in this page, because "no pictures to grade" and "the
    # pictures are fine" are different facts and only one of them is good news.
    if ($null -eq $Media) {
        $mediaSection = @"
<!-- media:absent -->
<section class="unknown">
  <h2>The pictures</h2>
  <p><strong>Not checked.</strong> Whether this site reuses the same photograph across
     different products is <em>unknown</em> &mdash; not &ldquo;fine&rdquo;.</p>
</section>
"@
    } elseif (-not $Media.Measured) {
        $mediaSection = @"
<!-- media:unmeasured -->
<section class="unknown">
  <h2>The pictures</h2>
  <p><strong>Could not be checked.</strong> $(& $e $Media.Reason)</p>
  <p>This is <em>not</em> a clean result. It means the check did not happen.</p>
</section>
"@
    } elseif (@($Media.Findings).Count -gt 0) {
        $hi = @($Media.Findings | Where-Object { $_.severity -eq 'high' })
        $lo = @($Media.Findings | Where-Object { $_.severity -ne 'high' })
        $hiRows = foreach ($f in $hi) { "<li>$(& $e $f.message)</li>" }
        $loRows = foreach ($f in $lo) { "<li>$(& $e $f.message)</li>" }
        $loBlock = if ($lo.Count -gt 0) {
            "<p>Also worth a look, less certain &mdash; these are guessed from file names, so
             the check has <em>not</em> looked at any picture:</p><ul>$($loRows -join "`n")</ul>"
        } else { '' }
        $cls = if ($Media.Hard) { 'alert' } else { 'unknown' }
        $mediaSection = @"
<!-- media:findings -->
<section class="$cls">
  <h2>The pictures</h2>
  $(if ($hi.Count -gt 0) { "<ul>$($hiRows -join "`n")</ul>" })
  $loBlock
</section>
"@
    } else {
        $mediaSection = @"
<!-- media:clean -->
<section class="ok">
  <h2>The pictures</h2>
  <p>Every product has its own picture, and no photograph is doing the work of several.</p>
  <p><em>This check never opens an image</em> &mdash; it can tell that pictures are not
     repeated, but not whether a picture actually shows what its product says it does.</p>
</section>
"@
    }

    # --- was the exam that graded this site ever itself checked? (#1342) ---
    # This is the sentence that turns his verdict into a measurement. A site can carry a
    # GREEN from an exam with empty test bodies; without this he has no way to know the
    # difference between "it passed a real exam" and "it passed an exam nobody checked".
    if ($null -eq $Exam -or -not $Exam.Found) {
        $why = if ($Exam -and $Exam.Reason) { & $e $Exam.Reason } else { 'No record of the exam check was found.' }
        $examSection = @"
<!-- exam:unknown -->
<section class="unknown">
  <h2>Was the marking any good?</h2>
  <p><strong>Unknown.</strong> $why</p>
  <p>Treat the system's own verdict on this site with that in mind &mdash; it may be
     sound, but nothing here can tell you.</p>
</section>
"@
    } elseif ($Exam.Conclusive) {
        $examSection = @"
<!-- exam:validated -->
<section class="ok">
  <h2>Was the marking any good?</h2>
  <p>The exam that graded this site was itself checked, and was shown able to
     <em>fail</em> &mdash; it was run against a version of the site where the work did not
     exist, and it correctly said no.</p>
</section>
"@
    } else {
        $rows = foreach ($r in @($Exam.Reasons)) { "<li>$(& $e $r)</li>" }
        $examSection = @"
<!-- exam:unvalidated -->
<section class="alert">
  <h2>Was the marking any good?</h2>
  <p><strong>The exam that graded this site was never shown able to fail.</strong>
     An exam that cannot fail will pass a site that is missing things you asked for
     &mdash; that is exactly what happened on 7 August.</p>
  <ul>$($rows -join "`n")</ul>
  <p><strong>Your eyes are the only real check on this delivery.</strong></p>
</section>
"@
    }

    # --- links that lead nowhere: the defect he found by hand, checked automatically ---
    # Three states, never two. An UNMEASURED check must not render like a clean one: that is
    # the failure this section exists to catch, and rendering it wrong here would be that
    # failure aimed at the person whose verdict the whole loop collects.
    if ($null -eq $Links) {
        $linkSection = @"
<!-- links:absent -->
<section class="unknown">
  <h2>Links that lead nowhere</h2>
  <p><strong>Not checked.</strong> No link check was run for this site, so whether its
     buttons and menus lead anywhere is <em>unknown</em> &mdash; not &ldquo;fine&rdquo;.</p>
</section>
"@
    } elseif (-not $Links.Measured) {
        $linkSection = @"
<!-- links:unmeasured -->
<section class="unknown">
  <h2>Links that lead nowhere</h2>
  <p><strong>Could not be checked.</strong> $(& $e $Links.Reason)</p>
  <p>This is <em>not</em> a clean result. It means the check did not happen.</p>
</section>
"@
    } elseif ($Links.Broken -gt 0) {
        $rows = foreach ($f in @($Links.Findings)) {
            "<li><code>$(& $e $f.reference)</code> &mdash; $(& $e $f.message)</li>"
        }
        $unk = if ($Links.Undecidable -gt 0) {
            "<p>A further <strong>$($Links.Undecidable)</strong> link(s) are built while the page is
             running, so they could not be followed. They are <em>unchecked</em>, not confirmed working.</p>"
        } else { '' }
        $linkSection = @"
<!-- links:broken -->
<section class="alert">
  <h2>Links that lead nowhere</h2>
  <p><strong>$($Links.Broken) link(s) on this site lead nowhere.</strong> Anyone who clicks
     them gets an error page instead of what they expected.</p>
  <ul>$($rows -join "`n")</ul>
  $unk
  <p>$($Links.Resolved) other link(s) were followed and work.</p>
</section>
"@
    } else {
        $unk = if ($Links.Undecidable -gt 0) {
            "<p>But <strong>$($Links.Undecidable)</strong> link(s) are built while the page is running
             and could not be followed &mdash; those are <em>unchecked</em>, not confirmed working.</p>"
        } else { '' }
        $linkSection = @"
<!-- links:clean -->
<section class="ok">
  <h2>Links that lead nowhere</h2>
  <p>None. All <strong>$($Links.Resolved)</strong> link(s) that could be followed lead to a real page.</p>
  $unk
</section>
"@
    }

    # --- the checklist: what he asked for, one clause at a time ---
    #
    # This section is the answer to the sentence that ended the first review anyone ever ran:
    # "I am not really sure what I am supposed to expect, to be honest with you." A reviewer with
    # no reference standard produces impressions; his verdict is the only ground truth this project
    # has for whether the automated gates are any good, so it has to be a measurement.
    #
    # It is a READING surface, not a recording one. The marks are taken in the console window that
    # opened this page, because a tick box on a file:// page has nowhere to send its answer — and a
    # control that looks like it records but does not is exactly the dishonesty this loop exists to
    # remove.
    $checklist = ''
    if ($Clauses -and $Clauses.Found -and @($Clauses.Clauses).Count -gt 0) {
        $drift = Get-ClauseGoalDrift -Clauses $Clauses -Goal $(if ($Claims) { $Claims.Goal } else { '' })
        $driftNote = ''
        if ($drift.Checked -and @($drift.Drifted).Count -gt 0) {
            $driftNote = ('<p class="drift"><strong>Careful:</strong> ' +
                          "$(@($drift.Drifted).Count) of these sentences do not appear in the " +
                          'instructions this run was actually given. Either the checklist or the ' +
                          'run has moved on from the other, so those lines may be asking about ' +
                          'something nobody asked the coder to build.</p>')
        }

        $rows = @()
        $n = 0
        foreach ($c in @($Clauses.Clauses)) {
            $n++
            $both = ''
            if (@($c.Parts).Count -gt 0) {
                # Every part is a verbatim cut of the sentence above it. It is here because one
                # sentence can carry two obligations and the second half is the one that fails
                # quietly: a site that shows any error message at all passes "tell someone politely"
                # while still throwing away everything they typed.
                $items = foreach ($p in @($c.Parts)) { "<li>$(& $e $p)</li>" }
                $both = "<div class=`"both`"><span>Both of these have to be true:</span><ul>$($items -join '')</ul></div>"
            }
            $rows += ("<tr><td class=`"n`">$n</td>" +
                      "<td class=`"clause`">&ldquo;$(& $e $c.Text)&rdquo;$both</td>" +
                      '<td class="marks"><span class="mark">yes</span>' +
                      '<span class="mark">no</span>' +
                      '<span class="mark">I could not tell</span></td></tr>')
        }

        $checklist = @"
<!-- checklist:present -->
<section class="checklist">
  <h2>What you asked for, line by line</h2>
  <p class="lede">Your own words, split into the separate things you asked for. Go through the site
     with this beside you and answer each one.</p>
  <p class="lede"><strong>&ldquo;I could not tell&rdquo; is a real answer</strong>, worth exactly as
     much as the other two. Use it whenever you cannot check something &mdash; a guess written down
     as a fact is worse than a blank, because everything downstream believes it.</p>
  <p class="lede">Where a sentence asks for more than one thing, <strong>all of it</strong> has to be
     true for a yes.</p>
  <p class="lede muted">You will be asked these one at a time in the black window that opened this
     page. Nothing here records anything &mdash; this is for reading while you look at the site.</p>
  $driftNote
  <table class="clauses"><thead><tr><th>&nbsp;</th><th>What you asked for</th><th>Your answer</th></tr></thead>
  <tbody>$($rows -join "`n")</tbody></table>
</section>
"@
    } else {
        $why = if ($Clauses -and $Clauses.Reason) { & $e $Clauses.Reason } else { 'No checklist was loaded for this site.' }
        $checklist = @"
<!-- checklist:absent -->
<section class="unknown">
  <h2>What you asked for, line by line</h2>
  <p><strong>No checklist has been written for this site yet.</strong> $why</p>
  <p>So this page cannot hand you what you asked for clause by clause. That is a gap in
     <em>this page</em> &mdash; it does <strong>not</strong> mean nothing was asked for. Judge the
     site against the goal above, in your own words, and say what is missing.</p>
</section>
"@
    }

    # --- pages ---
    $pageLinks = ''
    if ($Pages.Count -gt 0) {
        $items = foreach ($p in $Pages) {
            "<li><a href=`"$site/$p`" target=`"_blank`">$(& $e $p)</a></li>"
        }
        $pageLinks = "<ul class=`"pages`">$($items -join '')</ul>"
    } else {
        $pageLinks = '<p class="muted">No HTML pages found under <code>public/</code>.</p>'
    }

    # --- merged ---
    $mergedList = ''
    if ($Claims -and $Claims.Found -and @($Claims.Merged).Count -gt 0) {
        $items = foreach ($t in @($Claims.Merged)) { "<li>$(& $e $t.Id)</li>" }
        $mergedList = "<ul class=`"merged`">$($items -join '')</ul>"
    } else {
        $mergedList = '<p class="muted">Not recorded.</p>'
    }

    # --- oracle ---
    $oracle = '<p class="muted">Not recorded.</p>'
    if ($Claims -and $Claims.Found -and $Claims.OracleStatus) {
        $oracle = @"
<p><strong>Status:</strong> $(& $e $Claims.OracleStatus) &nbsp;·&nbsp;
   <strong>File:</strong> <code>$(& $e $Claims.OraclePath)</code></p>
<pre class="evidence">$(& $e $Claims.OracleEvidence)</pre>
<p class="caveat">An acceptance test that passes proves the product satisfies <em>that test</em>.
   It does not prove the test was capable of failing. If a claim below matches something you can
   see is wrong on the site, that is a finding worth more than any number on this page.</p>
"@
    }

    $goal = if ($Claims -and $Claims.Goal) { & $e $Claims.Goal } else { '<span class="muted">Not recorded.</span>' }
    $verdict = if ($Claims -and $Claims.Verdict) { $Claims.Verdict } else { 'UNRECORDED' }
    $verdictClass = switch ($verdict) { 'GREEN' { 'v-green' } 'STALLED' { 'v-bad' } default { 'v-other' } }
    $notes = if ($Claims -and $Claims.Notes) { "<section><h2>The run's own notes</h2><pre class=`"evidence`">$(& $e $Claims.Notes)</pre></section>" } else { '' }
    $wall = if ($Claims -and $Claims.WallClockS -gt 0) { "{0:n0} min" -f ($Claims.WallClockS / 60) } else { '&mdash;' }

    $html = @"
<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Review: $(& $e $Build.Name)</title>
<style>
  :root {
    --ink:#1b1a17; --ink-soft:#55504a; --ground:#faf8f5; --card:#fff;
    --line:#e3ddd4; --accent:#8a5a3b; --warn:#a4442b; --good:#3f6b47; --muted:#8b857d;
  }
  @media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) {
    --ink:#eee9e2; --ink-soft:#b6ada2; --ground:#171614; --card:#201e1b;
    --line:#332f2a; --accent:#c9895f; --warn:#e08267; --good:#7fb188; --muted:#8b857d; } }
  :root[data-theme="dark"] {
    --ink:#eee9e2; --ink-soft:#b6ada2; --ground:#171614; --card:#201e1b;
    --line:#332f2a; --accent:#c9895f; --warn:#e08267; --good:#7fb188; --muted:#8b857d; }
  * { box-sizing:border-box; }
  body { margin:0; background:var(--ground); color:var(--ink);
         font:16px/1.6 "Iowan Old Style", Palatino, Georgia, serif; }
  .wrap { max-width:60rem; margin:0 auto; padding:2.5rem 1.5rem 5rem; }
  header.top { border-bottom:2px solid var(--line); padding-bottom:1.25rem; margin-bottom:2rem; }
  h1 { font-size:1.9rem; margin:0 0 .35rem; letter-spacing:-.01em; text-wrap:balance; }
  .sub { color:var(--ink-soft); font-size:.95rem; }
  .badge { display:inline-block; padding:.15rem .6rem; border-radius:2px; font:600 .78rem/1.5
           ui-sans-serif,system-ui,sans-serif; letter-spacing:.06em; }
  .v-green { background:var(--good); color:#fff; } .v-bad { background:var(--warn); color:#fff; }
  .v-other { background:var(--muted); color:#fff; }
  section { background:var(--card); border:1px solid var(--line); border-radius:3px;
            padding:1.4rem 1.5rem; margin:0 0 1.5rem; }
  section.alert { border-left:4px solid var(--warn); }
  section.ok { border-left:4px solid var(--good); }
  section.unknown { border-left:4px solid var(--muted); }
  h2 { font-size:1.15rem; margin:0 0 .7rem; }
  .lede { color:var(--ink-soft); font-size:.95rem; margin:0 0 1rem; }
  table { width:100%; border-collapse:collapse; font-size:.9rem; }
  th { text-align:left; font:600 .72rem/1.6 ui-sans-serif,system-ui,sans-serif;
       letter-spacing:.08em; text-transform:uppercase; color:var(--muted);
       border-bottom:1px solid var(--line); padding:.4rem .5rem .4rem 0; }
  td { padding:.6rem .5rem .6rem 0; border-bottom:1px solid var(--line); vertical-align:top; }
  td.id { font:600 .88rem ui-monospace,Consolas,monospace; white-space:nowrap; padding-right:1rem; }
  td.st { white-space:nowrap; padding-right:1rem; font:600 .72rem ui-sans-serif,system-ui,sans-serif;
          letter-spacing:.06em; }
  .skip { color:var(--warn); } .park { color:var(--accent); } .other { color:var(--muted); }
  td.why { color:var(--ink-soft); font-size:.85rem; }
  ul.pages { list-style:none; padding:0; margin:0; display:flex; flex-wrap:wrap; gap:.6rem; }
  ul.pages a { display:inline-block; padding:.5rem .9rem; border:1px solid var(--line);
               border-radius:2px; text-decoration:none; color:var(--accent);
               font:600 .9rem ui-sans-serif,system-ui,sans-serif; background:var(--ground); }
  ul.pages a:hover { border-color:var(--accent); }
  ul.merged { columns:2; column-gap:2rem; font-size:.92rem; padding-left:1.2rem; }
  pre.evidence { background:var(--ground); border:1px solid var(--line); border-radius:2px;
                 padding:.8rem; overflow-x:auto; font:.8rem/1.6 ui-monospace,Consolas,monospace;
                 white-space:pre-wrap; color:var(--ink-soft); margin:0 0 .8rem; }
  .caveat { font-size:.86rem; color:var(--ink-soft); font-style:italic; margin:0; }
  .muted { color:var(--muted); }
  section.checklist { border-left:4px solid var(--accent); }
  table.clauses td { vertical-align:top; }
  td.n { width:2rem; color:var(--muted); font:600 .85rem ui-sans-serif,system-ui,sans-serif;
         font-variant-numeric:tabular-nums; padding-right:.6rem; }
  td.clause { font-size:.95rem; padding-right:1.5rem; }
  .both { margin:.5rem 0 .1rem; font:.82rem/1.5 ui-sans-serif,system-ui,sans-serif;
          color:var(--ink-soft); }
  .both span { font-weight:600; letter-spacing:.01em; }
  .both ul { margin:.25rem 0 0; padding-left:1.1rem; }
  .both li { margin:.15rem 0; }
  /* The three answers carry identical weight on purpose. "I could not tell" that looks like the
     lesser option gets picked less than it is true, and the instrument starts manufacturing
     verdicts it never measured. */
  td.marks { white-space:nowrap; width:1%; }
  td.marks .mark { display:block; padding:.28rem .7rem; margin:0 0 .3rem; text-align:center;
                   border:1px solid var(--line); border-radius:2px; background:var(--ground);
                   color:var(--ink-soft);
                   font:600 .78rem ui-sans-serif,system-ui,sans-serif; letter-spacing:.02em; }
  .drift { border-left:3px solid var(--warn); padding:.5rem .8rem; margin:0 0 1rem;
           font-size:.88rem; color:var(--ink-soft); background:var(--ground); }
  blockquote { margin:0; padding-left:1rem; border-left:3px solid var(--accent);
               color:var(--ink-soft); font-size:.95rem; }
  .cta { background:var(--accent); color:#fff; border-radius:3px; padding:1.3rem 1.5rem; }
  .cta h2 { color:#fff; } .cta p { margin:.4rem 0 0; font-size:.95rem; }
  .meta { display:flex; flex-wrap:wrap; gap:1.5rem; font-size:.85rem; color:var(--ink-soft);
          margin-top:.6rem; font-family:ui-sans-serif,system-ui,sans-serif; }
  .meta b { color:var(--ink); font-variant-numeric:tabular-nums; }
</style></head>
<body><div class="wrap">

<header class="top">
  <h1>$(& $e $Build.Name)</h1>
  <div class="sub">
    <span class="badge $verdictClass">$(& $e $verdict)</span>
    &nbsp; $(& $e $Build.Source) &nbsp;·&nbsp; built $($Build.When.ToString('dddd d MMMM, HH:mm'))
  </div>
  <div class="meta">
    <span><b>$($Build.Pages)</b> pages</span>
    <span><b>$($Build.Commits)</b> commits</span>
    <span>build time <b>$wall</b></span>
    $(if ($Claims -and $Claims.RunId) { "<span>run <b>$(& $e $Claims.RunId)</b></span>" })
  </div>
</header>

<section class="cta">
  <h2>Open the site</h2>
  <p>It is running at <strong>$site</strong> &mdash; click a page below. Use it as a visitor would:
     follow the menu between pages, submit the contact form with something missing, filter the
     piece list. Then tell me what is wrong in your own words.</p>
</section>

<section>
  <h2>Pages</h2>
  $pageLinks
</section>

$examSection

$mediaSection

$linkSection

<section>
  <h2>What you asked for</h2>
  <blockquote>$goal</blockquote>
</section>

$checklist

$notDone

<section>
  <h2>What shipped</h2>
  $mergedList
</section>

<section>
  <h2>What the acceptance test claimed</h2>
  $oracle
</section>

$notes

</div></body></html>
"@

    $dir = Split-Path -Parent $OutPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    # UTF8 without BOM: the file is served over http and read by a browser.
    [System.IO.File]::WriteAllText($OutPath, $html, [System.Text.UTF8Encoding]::new($false))
    $OutPath
}
