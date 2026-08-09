# review-website-lib.ps1 — discovery, evidence-reading and mark-keeping for the website review
# loop (#1343, #1345).
#
# The operator asked for the outputs of the website batteries to be PRESENTED to him after each
# run so he can evaluate, validate and give feedback. This library answers the three questions
# that has to answer before anything can be shown:
#
#   1. WHICH sites exist?  They live in three different places and two of them are not obvious:
#      a live sandbox under ~/projects, an operator dispatch under ~/projects, and — the one
#      that matters most — an ARCHIVED sandbox buried inside a dated battery night directory.
#      B9's first completed site spent a day in (c) and nobody ever opened it.
#   2. What did the run CLAIM about the site?  A verdict alone is not reviewable. The operator
#      needs the plan's own account beside the product: what merged, what was SKIPPED and on
#      whose authority, and what the acceptance oracle asserted. #1342 is exactly why — a run
#      graded GREEN while silently dropping a page he had asked for, and the skip reason was
#      sitting in the run record the whole time.
#   3. What was he PROMISED, in his own words?  The first review anyone ever ran ended with him
#      saying "I am not really sure what I am supposed to expect, to be honest with you." That is
#      a defect in the instrument, not in him: a reviewer handed no reference standard produces
#      impressions, and impressions cannot grade the automated gates. So his goal is cut into its
#      separate clauses and handed back to him one at a time, and his marks are kept.
#
# Read-only over every source EXCEPT the review record it is asked to build — nothing here mutates
# a sandbox, an archive, a run record or a clause file; the evidence outlives the review.

Set-StrictMode -Version Latest

$script:ProjectsRoot = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'projects'
$script:StateRoot    = 'C:\Users\mrbla\agentic-setup\state'
# Clause files are CURATED, COMMITTED content, so they live under configs/ with the rest of the
# hand-authored configuration — never under state/, which .gitignore excludes wholesale. A clause
# file in state/ would be invisible in a diff, unreviewable, and gone the first time state is wiped.
$script:ClauseRoot   = Join-Path (Split-Path $PSScriptRoot -Parent) 'configs\review-clauses'

# The four marks a clause can carry. NOT-REVIEWED is never offered as a choice — it is what a
# clause he never reached is left as, and keeping it distinct from COULD-NOT-TELL is the whole
# point: a review he stopped half way through must not read afterwards as nine considered answers.
$script:MarkMet          = 'met'
$script:MarkNotMet       = 'not-met'
$script:MarkCouldNotTell = 'could-not-tell'
$script:MarkNotReviewed  = 'not-reviewed'

function Get-WebBuildPageCount {
    <#  Count the site's own pages. `public/` is the skeleton's served root; fall back to a
        tree-wide sweep for a build that chose a different layout, so a non-standard site is
        reported as small rather than as missing. #>
    param([Parameter(Mandatory)][string]$Root)
    $pub = Join-Path $Root 'public'
    $dir = if (Test-Path -LiteralPath $pub) { $pub } else { $Root }
    try {
        @(Get-ChildItem -LiteralPath $dir -Filter '*.html' -Recurse -File -ErrorAction Stop).Count
    } catch { 0 }
}

function Get-WebBuildCommitCount {
    param([Parameter(Mandatory)][string]$Root)
    if (-not (Test-Path -LiteralPath (Join-Path $Root '.git'))) { return 0 }
    try {
        $n = & git -C $Root rev-list --count HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $n) { [int]$n } else { 0 }
    } catch { 0 }
}

function Find-RunRecordForRepo {
    <#  Find the newest fleet-run directory whose scorecard names this repo. The run record is
        the only place the plan's account of itself lives; a sandbox on its own cannot say what
        was skipped. Returns $null when nothing matches — an unmatched build is still worth
        showing, it just gets reviewed without its claims. #>
    param([Parameter(Mandatory)][string]$RepoLeaf)
    $runsRoot = Join-Path $script:StateRoot 'fleet-runs'
    if (-not (Test-Path -LiteralPath $runsRoot)) { return $null }
    $runs = Get-ChildItem -LiteralPath $runsRoot -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending
    foreach ($r in $runs) {
        $sc = Join-Path $r.FullName 'scorecard.json'
        if (-not (Test-Path -LiteralPath $sc)) { continue }
        try { $j = Get-Content -LiteralPath $sc -Raw | ConvertFrom-Json } catch { continue }
        $repo = if ($j.PSObject.Properties.Name -contains 'repo') { [string]$j.repo } else { '' }
        if ($repo -and (Split-Path $repo -Leaf) -eq $RepoLeaf) { return $r.FullName }
    }
    return $null
}

function Read-RunClaims {
    <#  The run's own account, normalised. Every field is optional: a run record can be partial,
        and a partial account is still better than none — but an ABSENT field must read as
        absent, never as a clean zero (the #1342 lesson, applied to this reader). #>
    param([string]$RunDir)
    $claims = [ordered]@{
        RunId = ''; Verdict = ''; Goal = ''; WallClockS = 0
        Merged = @(); Skipped = @(); Parked = @(); Other = @()
        OracleStatus = ''; OracleEvidence = ''; OraclePath = ''
        DesignReview = ''; Notes = ''; Found = $false
    }
    if (-not $RunDir -or -not (Test-Path -LiteralPath $RunDir)) { return $claims }
    $sc = Join-Path $RunDir 'scorecard.json'
    if (-not (Test-Path -LiteralPath $sc)) { return $claims }
    try { $j = Get-Content -LiteralPath $sc -Raw | ConvertFrom-Json } catch { return $claims }
    $claims.Found = $true
    $has = { param($o, $n) $o.PSObject.Properties.Name -contains $n }

    if (& $has $j 'run_id')      { $claims.RunId      = [string]$j.run_id }
    if (& $has $j 'verdict')     { $claims.Verdict    = [string]$j.verdict }
    if (& $has $j 'goal')        { $claims.Goal       = [string]$j.goal }
    if (& $has $j 'notes')       { $claims.Notes      = [string]$j.notes }
    if (& $has $j 'wall_clock_s'){ $claims.WallClockS = [double]$j.wall_clock_s }

    if (& $has $j 'tasks') {
        foreach ($t in @($j.tasks)) {
            $status = if (& $has $t 'status') { [string]$t.status } else { 'unknown' }
            $row = [pscustomobject]@{
                Id     = $(if (& $has $t 'id') { [string]$t.id } else { '(unnamed)' })
                Status = $status
                Detail = $(if (& $has $t 'detail') { [string]$t.detail } else { '' })
            }
            switch ($status) {
                'merged'  { $claims.Merged  += $row }
                'skipped' { $claims.Skipped += $row }
                'parked'  { $claims.Parked  += $row }
                default   { $claims.Other   += $row }
            }
        }
    }
    if (& $has $j 'job_acceptance') {
        $ja = $j.job_acceptance
        if (& $has $ja 'status')      { $claims.OracleStatus   = [string]$ja.status }
        if (& $has $ja 'evidence')    { $claims.OracleEvidence = [string]$ja.evidence }
        if (& $has $ja 'oracle_path') { $claims.OraclePath     = [string]$ja.oracle_path }
    }
    if ((& $has $j 'evidence') -and (& $has $j.evidence 'design_review')) {
        $claims.DesignReview = [string]$j.evidence.design_review
    }
    return $claims
}

function Get-ReviewClauses {
    <#  Load the checklist for a build: the operator's goal, cut into the separate things he asked
        for, in his own words.

        Keyed by battery card (configs/review-clauses/B9.json) and matched to a build by the card's
        `repo` name, falling back to the card id. The clauses are NOT read from the battery card
        itself: evals/battery/B9.json is a frozen measurement card whose bytes feed the coder's
        prompt, and adding review-side fields to it would break run-to-run comparability.

        FAIL LOUD, NEVER EMPTY. Every path that cannot produce a real checklist returns Found=$false
        with a Reason in plain language. A file that will not parse, a file with no clauses, a
        missing folder — each is REPORTED. What must never happen is a silent empty list, because an
        empty checklist renders as "nothing was asked for", which is precisely the lie #1342 told
        with skipped tasks. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BuildName)

    $result = [ordered]@{
        Found = $false; CardId = ''; Repo = ''; Path = ''; GoalVerbatim = ''
        Clauses = @(); Reason = ''
    }

    if (-not (Test-Path -LiteralPath $script:ClauseRoot)) {
        $result.Reason = "There is no clause folder at $script:ClauseRoot yet."
        return [pscustomobject]$result
    }
    $files = @(Get-ChildItem -LiteralPath $script:ClauseRoot -Filter '*.json' -File -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) {
        $result.Reason = "No clause file has been written yet (the folder $script:ClauseRoot is empty)."
        return [pscustomobject]$result
    }

    $has = { param($o, $n) $o.PSObject.Properties.Name -contains $n }
    $unreadable = @()

    foreach ($f in $files) {
        $j = $null
        try { $j = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json }
        catch { $unreadable += "$($f.Name) ($($_.Exception.Message))"; continue }

        $repo = if (& $has $j 'repo')    { [string]$j.repo }    else { '' }
        $card = if (& $has $j 'card_id') { [string]$j.card_id } else { '' }
        if (-not (($repo -and $repo -eq $BuildName) -or ($card -and $card -eq $BuildName))) { continue }

        $result.CardId       = $card
        $result.Repo         = $repo
        $result.Path         = $f.FullName
        $result.GoalVerbatim = if (& $has $j 'goal_verbatim') { [string]$j.goal_verbatim } else { '' }

        $rows = @()
        if (& $has $j 'clauses') {
            foreach ($c in @($j.clauses)) {
                $id   = if (& $has $c 'id')   { [string]$c.id }   else { '' }
                $text = if (& $has $c 'text') { [string]$c.text } else { '' }
                # A clause with no id or no words is not a clause. Dropping it silently would
                # shrink the checklist without saying so, so it is refused loudly instead.
                if (-not $id -or -not $text) {
                    $unreadable += "$($f.Name) (a clause has no id or no text)"
                    $rows = @(); break
                }
                $rows += [pscustomobject]@{
                    Id    = $id
                    Text  = $text
                    Parts = @(if (& $has $c 'parts') { @($c.parts | ForEach-Object { [string]$_ }) })
                }
            }
        }

        if ($rows.Count -eq 0) {
            $result.Reason = ("The clause file $($f.Name) was found but contains no usable clauses" +
                              $(if ($unreadable.Count) { ' — ' + ($unreadable -join '; ') } else { '' }) +
                              '. No checklist is being shown; that is not the same as nothing having been asked for.')
            return [pscustomobject]$result
        }

        $result.Clauses = $rows
        $result.Found   = $true
        return [pscustomobject]$result
    }

    $result.Reason = "No clause file in $script:ClauseRoot names this site ('$BuildName')."
    if ($unreadable.Count -gt 0) {
        $result.Reason += ' One or more clause files could not be read at all: ' + ($unreadable -join '; ') + '.'
    }
    return [pscustomobject]$result
}

function Get-ClauseGoalDrift {
    <#  Do the clauses still match the instructions the run was ACTUALLY given?

        The checklist is a copy of a frozen card. The run record carries the goal the coder was
        really handed. If a clause no longer appears verbatim in that goal, the operator is being
        asked to grade the site against something nobody ever asked the coder to build — a review
        that would produce a confident wrong answer.

        Returns Checked=$false when there is no goal to compare against, so that "cannot check"
        never renders as "checked, and clean". #>
    param([AllowNull()]$Clauses, [AllowNull()][string]$Goal)

    $out = [ordered]@{ Checked = $false; Drifted = @() }
    if (-not $Clauses -or -not $Clauses.Found) { return [pscustomobject]$out }
    if ([string]::IsNullOrWhiteSpace($Goal))   { return [pscustomobject]$out }
    $out.Checked = $true
    $out.Drifted = @(@($Clauses.Clauses) | Where-Object { -not $Goal.Contains($_.Text) } |
                     ForEach-Object { $_.Id })
    return [pscustomobject]$out
}

function ConvertTo-MarkWords {
    <#  The stored mark in the words he used to answer. The record on disk keeps the machine token;
        anything he reads gets the plain phrase. #>
    param([string]$Mark)
    switch ($Mark) {
        $script:MarkMet          { 'yes'            }
        $script:MarkNotMet       { 'no'             }
        $script:MarkCouldNotTell { 'could not tell' }
        default                  { 'not looked at'  }
    }
}

function New-OperatorReviewRecord {
    <#  Build the durable record of a review: the JSON a later run reads, and the markdown a human
        reads. Separated from the prompting so the RECORD can be tested without a keyboard.

        The load-bearing rule lives here: a clause he never got to is marked NOT-REVIEWED, never
        COULD-NOT-TELL. Those are different facts. Collapsing them would let a review abandoned
        after two clauses read afterwards as nine considered answers — a partial result presented
        as a whole, which is the failure class this whole loop exists to stop.

        $Marks is whatever was collected, in any order: objects with Id, Mark and Words. Clause
        order comes from the clause file, not from the answers. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Build,
        [Parameter(Mandatory)][AllowNull()]$Claims,
        [Parameter(Mandatory)][AllowNull()]$Clauses,
        [AllowNull()]$Marks = @(),
        [string[]]$Feedback = @(),
        [string]$RunDir = '',
        [string[]]$Pages = @(),
        [string]$Stamp = ''
    )

    $runId = if ($Claims -and $Claims.RunId) { $Claims.RunId }
             else { "unmatched-$(if ($Stamp) { $Stamp } else { Get-Date -Format 'yyyyMMdd-HHmmss' })" }

    $byId = @{}
    foreach ($m in @($Marks)) {
        if ($null -eq $m) { continue }
        $byId[[string]$m.Id] = $m
    }

    $checklist = [ordered]@{}
    $mdChecklist = @()

    if ($Clauses -and $Clauses.Found) {
        $rows   = @()
        $counts = [ordered]@{
            $script:MarkMet = 0; $script:MarkNotMet = 0
            $script:MarkCouldNotTell = 0; $script:MarkNotReviewed = 0
        }
        foreach ($c in @($Clauses.Clauses)) {
            $mark  = $script:MarkNotReviewed
            $words = ''
            if ($byId.ContainsKey($c.Id)) {
                $m = $byId[$c.Id]
                if ($m.PSObject.Properties.Name -contains 'Mark'  -and $m.Mark)  { $mark  = [string]$m.Mark }
                if ($m.PSObject.Properties.Name -contains 'Words' -and $m.Words) { $words = [string]$m.Words }
            }
            if (-not $counts.Contains($mark)) { $counts[$mark] = 0 }
            $counts[$mark] = $counts[$mark] + 1
            $rows += [ordered]@{ id = $c.Id; text = $c.Text; mark = $mark; words = $words }
        }

        $drift = Get-ClauseGoalDrift -Clauses $Clauses -Goal $(if ($Claims) { $Claims.Goal } else { '' })
        $checklist = [ordered]@{
            available     = $true
            card_id       = $Clauses.CardId
            source        = $Clauses.Path
            goal_drift_checked = $drift.Checked
            goal_drift    = @($drift.Drifted)
            counts        = $counts
            clauses       = $rows
        }

        $mdChecklist = @(
            '## What he asked for, clause by clause',
            '',
            '| # | In his own words | His answer | What he said about it |',
            '|---|---|---|---|'
        )
        $n = 0
        foreach ($r in $rows) {
            $n++
            $mdChecklist += ('| {0} | {1} | **{2}** | {3} |' -f $n,
                             ($r.text -replace '\|', '\|'),
                             (ConvertTo-MarkWords $r.mark),
                             ($r.words -replace '\|', '\|'))
        }
        $mdChecklist += ''
        $mdChecklist += ('Answered: {0} yes, {1} no, {2} could not tell, {3} not looked at.' -f
                         $counts[$script:MarkMet], $counts[$script:MarkNotMet],
                         $counts[$script:MarkCouldNotTell], $counts[$script:MarkNotReviewed])
        if ($drift.Checked -and @($drift.Drifted).Count -gt 0) {
            $mdChecklist += ''
            $mdChecklist += ('**Clause drift:** ' + (@($drift.Drifted) -join ', ') +
                             ' do not appear in the goal this run was actually given.')
        }
        $mdChecklist += ''
    } else {
        $why = if ($Clauses -and $Clauses.Reason) { $Clauses.Reason } else { 'No checklist was loaded.' }
        $checklist = [ordered]@{
            available = $false
            reason    = $why
        }
        $mdChecklist = @(
            '## What he asked for, clause by clause',
            '',
            "**Not available.** $why",
            '',
            'He was NOT shown a checklist for this review, so the absence of marks below says',
            'nothing about whether the site met what he asked for.',
            ''
        )
    }

    $record = [ordered]@{
        # v2 = v1 + `checklist`. Bumped rather than silently widened so a reader can tell a review
        # taken BEFORE the checklist existed (v1, no marks recorded) from one where the checklist
        # was offered and came back empty. Those are different facts about the review.
        schema       = 'operator-website-review/v2'
        schema_note  = 'v2 adds `checklist`. A v1 record predates the checklist and carries no marks; absence of marks in a v1 record is not evidence about the site.'
        recorded_at  = (Get-Date).ToString('o')
        build_name   = $Build.Name
        build_path   = $Build.Path
        build_source = $Build.Source
        run_id       = $runId
        run_dir      = $RunDir
        verdict_at_review = $(if ($Claims) { $Claims.Verdict } else { '' })
        pages        = @($Pages)
        skipped_tasks = @(if ($Claims) { @($Claims.Skipped) | ForEach-Object { $_.Id } })
        checklist    = $checklist
        operator_feedback = @($Feedback)
    }

    $md = @(
        "# Operator review — $($Build.Name)",
        '',
        "- **When:** $(Get-Date -Format 'yyyy-MM-dd HH:mm') local",
        "- **Run:** $runId",
        "- **Verdict the system gave:** $(if ($Claims -and $Claims.Verdict) { $Claims.Verdict } else { 'unrecorded' })",
        "- **Build:** $($Build.Path)",
        ''
    ) + $mdChecklist + @(
        '## What he said',
        ''
    ) + $(if (@($Feedback).Count -gt 0) { @($Feedback) | ForEach-Object { "> $_" } }
          else { '_He did not add anything beyond the checklist._' })

    [pscustomobject]@{ Json = $record; Markdown = @($md) }
}

function Get-WebsiteBuilds {
    <#  Every website build on the box, newest first.

        Three sources, and the third is the one this whole exercise exists for: a battery night
        ARCHIVES the sandbox it built, so by morning the finished site is inside
        state/battery/night-*/repos-archived/ where nothing will ever open it. A discovery pass
        that only looked at ~/projects would show the operator an empty list on the very morning
        after his site was built. #>
    [CmdletBinding()]
    param()
    $builds = @()

    # (a) + (b) live sandboxes and operator dispatches under ~/projects
    if (Test-Path -LiteralPath $script:ProjectsRoot) {
        foreach ($d in Get-ChildItem -LiteralPath $script:ProjectsRoot -Directory -ErrorAction SilentlyContinue) {
            $pages = Get-WebBuildPageCount -Root $d.FullName
            if ($pages -lt 1) { continue }   # not a website build
            $builds += [pscustomobject]@{
                Name     = $d.Name
                Path     = $d.FullName
                Source   = if ($d.Name -like 'battery-*') { 'battery sandbox (live)' } else { 'your dispatch' }
                Archived = $false
                When     = $d.LastWriteTime
                Pages    = $pages
                Commits  = Get-WebBuildCommitCount -Root $d.FullName
            }
        }
    }

    # (c) archived sandboxes inside dated battery nights — the ones that would otherwise vanish
    $battRoot = Join-Path $script:StateRoot 'battery'
    if (Test-Path -LiteralPath $battRoot) {
        foreach ($night in Get-ChildItem -LiteralPath $battRoot -Directory -Filter 'night-*' -ErrorAction SilentlyContinue) {
            $archived = Join-Path $night.FullName 'repos-archived'
            if (-not (Test-Path -LiteralPath $archived)) { continue }
            foreach ($d in Get-ChildItem -LiteralPath $archived -Directory -ErrorAction SilentlyContinue) {
                $pages = Get-WebBuildPageCount -Root $d.FullName
                if ($pages -lt 1) { continue }
                $builds += [pscustomobject]@{
                    Name     = $d.Name
                    Path     = $d.FullName
                    Source   = "archived $($night.Name -replace '^night-','')"
                    Archived = $true
                    When     = $d.LastWriteTime
                    Pages    = $pages
                    Commits  = Get-WebBuildCommitCount -Root $d.FullName
                }
            }
        }
    }

    $builds | Sort-Object When -Descending
}

function Assert-ServingThisBuild {
    <#  Refuse to present a build unless the port is proven to be serving THIS workspace.

        A review that silently shows the WRONG build is worse than one that refuses to open: the
        operator's verdict is the only ground truth in the pipeline, and a verdict recorded against
        the wrong site poisons it. Measured 2026-08-08 while verifying this script — a port-probe
        bug handed back an occupied port, the review server died with EADDRINUSE, and a previous
        review's process answered every request. The report looked entirely successful.

        Three distinct failures, each fatal and each named separately: the server died on startup;
        something else is answering; nothing answers at all. Never returns false — it either
        returns $true or throws with the reason. #>
    param(
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][AllowNull()]$Proc,
        [string]$LogPath,
        [int]$Attempts = 25
    )
    if ($Proc -and $Proc.HasExited) {
        $why = @()
        if ($LogPath -and (Test-Path -LiteralPath $LogPath)) {
            $why = @((Get-Content -LiteralPath $LogPath -ErrorAction SilentlyContinue) |
                     Where-Object { $_ -match '\S' } | Select-Object -First 3)
        }
        throw ("The review server exited immediately (port $Port). It is NOT safe to present " +
               "this build. " + ($why -join ' | '))
    }
    # A "still starting up" failure must retry; a MISMATCH must abort at once. Typed catches are
    # not usable here — PowerShell 7 surfaces connection-refused as several different exception
    # types depending on stack and platform, and an unlisted one escapes the loop and reports the
    # wrong failure (measured: the not-answering case reported as an unhandled error rather than
    # as the refusal). So: catch broadly, and mark the deliberate abort so it is re-thrown.
    for ($i = 0; $i -lt $Attempts; $i++) {
        try {
            # .Content is Byte[] for a served .txt and String for other types — normalise, or the
            # identity check fails on its own plumbing rather than on a real mismatch (which is
            # what happened the first time this ran: fail-closed, but for the wrong reason).
            $raw = (Invoke-WebRequest "http://127.0.0.1:$Port/__review_id.txt" `
                        -UseBasicParsing -TimeoutSec 2).Content
            $got = if ($raw -is [byte[]]) { [System.Text.Encoding]::ASCII.GetString($raw) }
                   else { [string]$raw }
            if ($got.Trim() -eq $Token) { return $true }
            throw ("MISMATCH::Port $Port is answering, but with a DIFFERENT build (expected " +
                   "token $Token, got '$($got.Trim())'). Refusing to present it.")
        } catch {
            if ($_.Exception.Message -like 'MISMATCH::*') {
                throw ($_.Exception.Message -replace '^MISMATCH::', '')
            }
            Start-Sleep -Milliseconds 200
        }
    }
    throw "The review server never answered on port $Port. Refusing to present this build."
}

function Get-FreeTcpPort {
    <#  A review server must never collide with the live system. 5001 (the assistant) and 3456
        (Vikunja) are the two that would actually hurt; the loop starts above both and probes.

        The probe binds IPv6Any with dual-mode, NOT 127.0.0.1, and that detail is the whole
        function. Node's `server.listen(port)` binds `::` — every interface, both stacks — while
        a bind to `127.0.0.1` succeeds happily alongside it. Probing IPv4-only therefore reported
        an occupied port as free: the review server then died with EADDRINUSE, and the page the
        operator was handed was served by the PREVIOUS review's process, showing him a different
        build under the current one's name. Measured 2026-08-08 while verifying this very script.

        Belt and braces: the listener probe answers "could I bind it", and the connect probe
        answers "is something already answering there". A port has to pass both. #>
    param([int]$Start = 8420, [int]$Tries = 60)
    for ($p = $Start; $p -lt ($Start + $Tries); $p++) {
        if ($p -in 5001, 3456) { continue }
        $free = $true
        try {
            $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::IPv6Any, $p)
            $l.Server.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::IPv6,
                                      [System.Net.Sockets.SocketOptionName]::IPv6Only, $false)
            $l.Start(); $l.Stop()
        } catch { $free = $false }
        if ($free) {
            # Something may be listening on a stack this process cannot bind-test. Ask directly.
            try {
                $c = [System.Net.Sockets.TcpClient]::new()
                if ($c.ConnectAsync('127.0.0.1', $p).Wait(250)) { $free = $false }
                $c.Close()
            } catch { }
        }
        if ($free) { return $p }
    }
    throw "No free loopback port found in $Start..$($Start + $Tries)."
}

# ---------------------------------------------------------------------------
# The link check (#1345) — every href/src in the built site, resolved
# ---------------------------------------------------------------------------

$script:BlarAiRepo = 'C:\Users\mrbla\BlarAI'

function Invoke-LinkLint {
    <#  Follow every link in a built site and report the ones that lead nowhere.

        This is the check that would have caught, on both nights, the defect he found by
        hand in under a minute: a "View Details" button pointing at a page that was never
        built. It runs BlarAI's shared/fleet/link_lint.py — deterministic, no model, no
        browser, about a tenth of a second — over the build being presented.

        FAIL-SOFT IS NOT FAIL-SILENT (the Invoke-LayoutLint contract, #1198). Every path
        that cannot produce a real answer returns Measured=$false with a Reason in plain
        language. What must never happen is an unavailable check rendering as "no broken
        links", because that is a clean-looking result from a check that never ran — the
        #1342 shape, aimed at the one reader whose verdict this whole loop exists to
        collect. CALLERS GATE ON .Measured, NEVER ON .Broken -eq 0.

        Returns: @{ Measured=[bool]; Reason; Broken=[int]; Undecidable=[int]; Resolved=[int];
                    Findings=[object[]] }  #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SitePath)

    $out = [ordered]@{
        Measured = $false; Reason = ''; Broken = 0; Undecidable = 0; Resolved = 0; Findings = @()
    }

    $pythonExe = Join-Path $script:BlarAiRepo '.venv\Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $pythonExe)) {
        $out.Reason = "The link checker could not run: no interpreter at $pythonExe."
        return [pscustomobject]$out
    }
    if (-not (Test-Path -LiteralPath $SitePath)) {
        $out.Reason = "The link checker could not run: there is nothing at $SitePath."
        return [pscustomobject]$out
    }

    $lines = @()
    try {
        $prevLoc = (Get-Location).Path
        try {
            Set-Location $script:BlarAiRepo
            $lines = @(& $pythonExe -m shared.fleet.link_lint --site-dir $SitePath 2>&1)
        } finally { Set-Location $prevLoc }
    } catch {
        $out.Reason = "The link checker could not be started: $($_.Exception.Message)"
        return [pscustomobject]$out
    }

    $jsonLine = ($lines | Where-Object { $_ -match '^\s*\{' } | Select-Object -Last 1)
    if (-not $jsonLine) {
        $tail = ((@($lines | Where-Object { "$_".Trim() }) | Select-Object -Last 3) -join ' | ')
        if ($tail.Length -gt 300) { $tail = $tail.Substring(0, 300) + '...' }
        $out.Reason = "The link checker produced no result. Last words: $tail"
        return [pscustomobject]$out
    }

    $obj = $null
    try { $obj = $jsonLine | ConvertFrom-Json } catch {
        $out.Reason = 'The link checker produced output that could not be read.'
        return [pscustomobject]$out
    }

    # The module reports checked=$false when it examined no page or script files at all.
    # That is an ABSENT result, not a clean one, and it is carried through as such rather
    # than being flattened into zero broken links.
    if (-not $obj.checked) {
        $out.Reason = if ($obj.reason) { [string]$obj.reason } else { 'The link check did not run.' }
        return [pscustomobject]$out
    }

    $out.Measured    = $true
    $out.Broken      = [int]$obj.counts.broken
    $out.Undecidable = [int]$obj.counts.undecidable
    $out.Resolved    = [int]$obj.counts.resolved
    $out.Findings    = @($obj.findings | Where-Object { $_.severity -eq 'high' })
    return [pscustomobject]$out
}

# ---------------------------------------------------------------------------
# Was the EXAM that graded this site ever itself checked? (#1342)
# ---------------------------------------------------------------------------

function Get-ExamQuality {
    <#  Read the run's `oracle-qa.json` and answer one question in plain language: was the
        exam that graded this website ever shown capable of FAILING?

        This is the context that turns his verdict into a measurement rather than an
        opinion. On 2026-08-08 a pottery site graded GREEN while missing a page he had
        asked for, because the acceptance exam contained two empty test bodies and passed
        on any tree where its imports resolved. Nothing told him that. Seeing "this site
        was graded by an exam nobody checked" beside the site is the difference between
        "I am not sure what I am supposed to expect" and a judgement.

        Reads the #1342-item-2 fields (`findings_conclusive`, `not_measured`) when present,
        and falls back to the raw execution stamps for records written before those existed
        — an OLD record must not be mistaken for a validated one just because it predates
        the field. A record that cannot be read at all is UNKNOWN, never "fine".

        Returns: @{ Found=[bool]; Conclusive=[bool]; Verdict; Reasons=[string[]]; Reason } #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$RunDir)

    $out = [ordered]@{ Found=$false; Conclusive=$false; Verdict=''; Reasons=@(); Reason='' }

    if (-not $RunDir -or -not (Test-Path -LiteralPath $RunDir)) {
        $out.Reason = 'No run folder was found for this build, so nothing is known about the exam that graded it.'
        return [pscustomobject]$out
    }
    $qa = Join-Path $RunDir 'oracle-qa.json'
    if (-not (Test-Path -LiteralPath $qa)) {
        $out.Reason = 'This run left no record of checking its own exam, so whether that exam could ever have failed is unknown.'
        return [pscustomobject]$out
    }
    $j = $null
    try { $j = Get-Content -LiteralPath $qa -Raw | ConvertFrom-Json } catch {
        $out.Reason = 'The record of the exam check could not be read.'
        return [pscustomobject]$out
    }
    $has = { param($o, $n) $o.PSObject.Properties.Name -contains $n }
    $out.Found = $true
    if (& $has $j 'verdict') { $out.Verdict = [string]$j.verdict }

    if (& $has $j 'findings_conclusive') {
        $out.Conclusive = [bool]$j.findings_conclusive
        if (& $has $j 'not_measured') { $out.Reasons = @($j.not_measured | ForEach-Object { [string]$_ }) }
    } else {
        # Pre-#1342 record. Derive from the raw stamps rather than assuming the best:
        # the absence of the field is the absence of the check, not evidence of a pass.
        $notMeasured = @('', 'not-run', 'skipped', 'unknown')
        $f2p  = if (& $has $j 'f2p_baseline')   { ([string]$j.f2p_baseline).Trim().ToLower() }   else { '' }
        $coll = if (& $has $j 'collectability') { ([string]$j.collectability).Trim().ToLower() } else { '' }
        $out.Conclusive = ($notMeasured -notcontains $f2p) -and ($notMeasured -notcontains $coll)
        if ($notMeasured -contains $f2p) {
            $out.Reasons += 'the exam was never run against a version of the site where the page did not exist, so it has NOT been shown capable of failing'
        }
        if ($notMeasured -contains $coll) {
            $out.Reasons += 'the exam was never loaded, so whether its questions can even be collected is unknown'
        }
    }
    return [pscustomobject]$out
}

function Invoke-MediaLint {
    <#  Grade where a site's pictures LAND, not just that they exist (#1345, capability 18).

        The operator's two remaining complaints from his 2026-08-08 review were "the same
        images were used over and over" and "descriptions of the products don't match the
        image". Neither is a broken link, so Invoke-LinkLint cannot see them. This runs
        BlarAI's shared/fleet/image_placement.py over the build being presented.

        Same contract as Invoke-LinkLint: FAIL-SOFT IS NOT FAIL-SILENT. A site with no
        pictures at all reports Measured=$false with a reason, NEVER zero findings — those
        are different facts, and collapsing them is the defect this whole loop exists to
        catch. CALLERS GATE ON .Measured, NEVER ON .Findings.Count -eq 0.

        Returns: @{ Measured=[bool]; Reason; Hard=[bool]; Findings=[object[]]; Notes=[string[]] } #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SitePath)

    $out = [ordered]@{ Measured=$false; Reason=''; Hard=$false; Findings=@(); Notes=@() }

    $pythonExe = Join-Path $script:BlarAiRepo '.venv\Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $pythonExe)) {
        $out.Reason = "The picture check could not run: no interpreter at $pythonExe."
        return [pscustomobject]$out
    }
    if (-not (Test-Path -LiteralPath $SitePath)) {
        $out.Reason = "The picture check could not run: there is nothing at $SitePath."
        return [pscustomobject]$out
    }

    $lines = @()
    try {
        $prevLoc = (Get-Location).Path
        try {
            Set-Location $script:BlarAiRepo
            $lines = @(& $pythonExe -m shared.fleet.image_placement --site-dir $SitePath 2>&1)
        } finally { Set-Location $prevLoc }
    } catch {
        $out.Reason = "The picture check could not be started: $($_.Exception.Message)"
        return [pscustomobject]$out
    }

    $jsonLine = ($lines | Where-Object { $_ -match '^\s*\{' } | Select-Object -Last 1)
    if (-not $jsonLine) {
        $tail = ((@($lines | Where-Object { "$_".Trim() }) | Select-Object -Last 3) -join ' | ')
        if ($tail.Length -gt 300) { $tail = $tail.Substring(0, 300) + '...' }
        $out.Reason = "The picture check produced no result. Last words: $tail"
        return [pscustomobject]$out
    }
    $obj = $null
    try { $obj = $jsonLine | ConvertFrom-Json } catch {
        $out.Reason = 'The picture check produced output that could not be read.'
        return [pscustomobject]$out
    }
    if (-not $obj.checked) {
        $out.Reason = if ($obj.reason) { [string]$obj.reason } else { 'The picture check did not run.' }
        return [pscustomobject]$out
    }

    $out.Measured = $true
    $out.Hard     = [bool]$obj.hard
    $out.Findings = @($obj.findings)
    if ($obj.PSObject.Properties.Name -contains 'not_measured') {
        $out.Notes = @($obj.not_measured | ForEach-Object { [string]$_ })
    }
    return [pscustomobject]$out
}
