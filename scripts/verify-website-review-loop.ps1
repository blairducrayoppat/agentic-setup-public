# verify-website-review-loop.ps1 — the regression lock for #1343 and #1345.
#
#   .\verify-website-review-loop.ps1
#
# The review loop's whole job is to stop a finished website from being invisible to the operator.
# Four of its properties are load-bearing and every one of them fails SILENTLY if it breaks, which
# is why they get locks rather than comments:
#
#   * ARCHIVED builds must be discoverable. A battery night moves the sandbox into a dated
#     repos-archived/ directory. A discovery pass that only walked ~/projects would show him an
#     empty list on the very morning after his site was built, and would look like it was working.
#   * The report must lead with what the run did NOT build, and must say "unknown" — never
#     "nothing" — when there is no run record. #1342 is the case: a run graded GREEN having
#     dropped a page the operator asked for, and the skip reason sat in the run record unread. A
#     report that renders only successes is how that got past everybody.
#   * The checklist must be HIS WORDS, verbatim. It is the reference standard he grades against;
#     a paraphrase edited in later would quietly change what "met" means, and every mark taken
#     afterwards would be measuring something else.
#   * A MISSING checklist must say so. An empty checklist reads as "nothing was asked for", which
#     is the same lie #1342 told with skipped tasks, told again one layer up. And a clause he
#     never reached must record as "not looked at", never as "could not tell" — a review abandoned
#     half way must never read afterwards as nine considered answers.
#
# Every check is offline. All but one group is hermetic, building its own fixtures in a temp
# directory and never touching a real sandbox, archive or run record. The exception is deliberate:
# the SHIPPED clause files under configs/review-clauses are read (read-only) and checked for the
# verbatim property, because that property has to hold in the file the operator is actually graded
# against, and no fixture can prove anything about it.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\review-website-lib.ps1"
. "$PSScriptRoot\review-website-report.ps1"

$script:Pass = 0; $script:Fail = 0
function Check {
    param([string]$Name, [scriptblock]$Body)
    try {
        $r = & $Body
        if ($r) { $script:Pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
        else    { $script:Fail++; Write-Host "  FAIL  $Name" -ForegroundColor Red }
    } catch {
        $script:Fail++
        Write-Host "  FAIL  $Name -- $($_.Exception.Message)" -ForegroundColor Red
    }
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "review-loop-verify-$(Get-Random)"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

try {
    Write-Host ''
    Write-Host 'Website review loop (#1343)' -ForegroundColor Cyan
    Write-Host ''

    # ---- fixtures -------------------------------------------------------------
    $buildLive = [pscustomobject]@{
        Name='fixture-site'; Path=$tmp; Source='battery sandbox (live)'; Archived=$false
        When=(Get-Date); Pages=3; Commits=7
    }

    $claimsWithSkip = [ordered]@{
        RunId='R-1'; Verdict='GREEN'; Goal='a page for each individual piece'; WallClockS=600
        Merged=@([pscustomobject]@{Id='home';Status='merged';Detail='ok'})
        Skipped=@([pscustomobject]@{Id='create-piece-detail-page';Status='skipped'
                                    Detail='already satisfied before wave 2: the oracle PASSED'})
        Parked=@(); Other=@()
        OracleStatus='passed'; OracleEvidence='exit 0'; OraclePath='tests/acceptance.job.test.mjs'
        DesignReview='cap-reached'; Notes=''; Found=$true
    }

    # ---- the report leads with what was NOT built ------------------------------
    $r1 = Join-Path $tmp 'r1.html'
    New-WebsiteReviewReport -Build $buildLive -Claims $claimsWithSkip -Port 9999 -OutPath $r1 | Out-Null
    $h1 = Get-Content -LiteralPath $r1 -Raw

    Check 'a skipped task is named in the report' { $h1 -match 'create-piece-detail-page' }
    Check 'the skip REASON is rendered, not just the fact' { $h1 -match 'already satisfied' }
    Check 'the not-built section is marked as an alert' { $h1 -match "class=`"alert`"" }
    Check 'the not-built section precedes the shipped section' {
        $h1.IndexOf('did <em>not</em> build') -lt $h1.IndexOf('What shipped') -and
        $h1.IndexOf('did <em>not</em> build') -ge 0
    }
    Check 'the operator goal is played back' { $h1 -match 'a page for each individual piece' }

    # ---- absent evidence reads as UNKNOWN, never as "nothing was skipped" ------
    $r2 = Join-Path $tmp 'r2.html'
    $claimsNone = [ordered]@{
        RunId=''; Verdict=''; Goal=''; WallClockS=0; Merged=@(); Skipped=@(); Parked=@(); Other=@()
        OracleStatus=''; OracleEvidence=''; OraclePath=''; DesignReview=''; Notes=''; Found=$false
    }
    New-WebsiteReviewReport -Build $buildLive -Claims $claimsNone -Port 9999 -OutPath $r2 | Out-Null
    $h2 = Get-Content -LiteralPath $r2 -Raw

    Check 'no run record renders as UNKNOWN' { $h2 -match 'Not recorded' -and $h2 -match 'unknown' }
    Check 'no run record does NOT claim nothing was skipped' {
        -not ($h2 -match 'Nothing was skipped')
    }
    Check 'an unrecorded verdict is labelled, not blank' { $h2 -match 'UNRECORDED' }

    # ---- a clean run says so, distinctly from the unknown case -----------------
    $r3 = Join-Path $tmp 'r3.html'
    $claimsClean = [ordered]@{
        RunId='R-2'; Verdict='GREEN'; Goal='g'; WallClockS=1
        Merged=@([pscustomobject]@{Id='home';Status='merged';Detail='ok'})
        Skipped=@(); Parked=@(); Other=@()
        OracleStatus='passed'; OracleEvidence='exit 0'; OraclePath='p'; DesignReview=''; Notes=''
        Found=$true
    }
    New-WebsiteReviewReport -Build $buildLive -Claims $claimsClean -Port 9999 -OutPath $r3 | Out-Null
    $h3 = Get-Content -LiteralPath $r3 -Raw
    Check 'a genuinely clean run says nothing was skipped' { $h3 -match 'Nothing was skipped' }
    Check 'clean and unknown are DIFFERENT renderings' {
        ($h3 -match "class=`"ok`"") -and ($h2 -match "class=`"unknown`"")
    }

    # ---- escaping: run text is untrusted and lands in HTML ---------------------
    $r4 = Join-Path $tmp 'r4.html'
    $claimsHostile = [ordered]@{
        RunId='R-3'; Verdict='GREEN'; Goal='<script>alert(1)</script>'; WallClockS=1
        Merged=@(); Skipped=@([pscustomobject]@{Id='<img src=x onerror=1>';Status='skipped';Detail='d'})
        Parked=@(); Other=@(); OracleStatus=''; OracleEvidence=''; OraclePath=''
        DesignReview=''; Notes=''; Found=$true
    }
    New-WebsiteReviewReport -Build $buildLive -Claims $claimsHostile -Port 9999 -OutPath $r4 | Out-Null
    $h4 = Get-Content -LiteralPath $r4 -Raw
    Check 'goal text is HTML-escaped' { $h4 -notmatch '<script>alert' }
    Check 'task ids are HTML-escaped' { $h4 -notmatch '<img src=x' }

    # ---- discovery finds ARCHIVED builds, not only live ones -------------------
    # The failure this exists for: a night archives the sandbox, and by morning the only copy of
    # the finished site is three levels inside a state directory.
    $fakeState = Join-Path $tmp 'state'
    $archived  = Join-Path $fakeState 'battery\night-20260101-000000\repos-archived\archived-site\public'
    New-Item -ItemType Directory -Force -Path $archived | Out-Null
    '<html></html>' | Set-Content (Join-Path $archived 'index.html')
    $liveProj = Join-Path $tmp 'projects\live-site\public'
    New-Item -ItemType Directory -Force -Path $liveProj | Out-Null
    '<html></html>' | Set-Content (Join-Path $liveProj 'index.html')

    $savedProjects = $script:ProjectsRoot; $savedState = $script:StateRoot
    try {
        $script:ProjectsRoot = Join-Path $tmp 'projects'
        $script:StateRoot    = $fakeState
        $found = @(Get-WebsiteBuilds)
        Check 'discovery finds the LIVE build'     { @($found | Where-Object Name -eq 'live-site').Count -eq 1 }
        Check 'discovery finds the ARCHIVED build' { @($found | Where-Object Name -eq 'archived-site').Count -eq 1 }
        Check 'the archived build is flagged as archived' {
            (@($found | Where-Object Name -eq 'archived-site')[0]).Archived -eq $true
        }
        Check 'a directory with no HTML is not offered as a website' {
            New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'projects\not-a-site') | Out-Null
            @(Get-WebsiteBuilds | Where-Object Name -eq 'not-a-site').Count -eq 0
        }
    } finally {
        $script:ProjectsRoot = $savedProjects; $script:StateRoot = $savedState
    }

    # =========================================================================================
    #  THE CHECKLIST (#1345) — his own words, handed back to him clause by clause
    # =========================================================================================

    # ---- the SHIPPED clause files: verbatim or nothing -------------------------
    # Not hermetic on purpose. The verbatim property must hold in the file he is actually graded
    # against; a fixture proves only that the checker works.
    $shipped = @(Get-ChildItem -LiteralPath $script:ClauseRoot -Filter '*.json' -File -ErrorAction SilentlyContinue)
    Check 'at least one clause file ships' { $shipped.Count -ge 1 }

    Check 'every shipped clause is VERBATIM in the goal it was cut from' {
        $ok = $true
        foreach ($f in $shipped) {
            $j = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
            foreach ($c in @($j.clauses)) {
                if (-not ([string]$j.goal_verbatim).Contains([string]$c.text)) {
                    Write-Host "        $($f.Name)/$($c.id) is not a substring of the goal" -ForegroundColor DarkRed
                    $ok = $false
                }
            }
        }
        $ok -and $shipped.Count -ge 1
    }

    Check 'every part is VERBATIM inside its own clause' {
        $ok = $true
        foreach ($f in $shipped) {
            $j = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
            foreach ($c in @($j.clauses)) {
                foreach ($p in @($c.parts)) {
                    if (-not ([string]$c.text).Contains([string]$p)) {
                        Write-Host "        $($f.Name)/$($c.id) part is not a substring of the clause" -ForegroundColor DarkRed
                        $ok = $false
                    }
                }
            }
        }
        $ok
    }

    Check 'clause ids are present and unique within a file' {
        $ok = $true
        foreach ($f in $shipped) {
            $j   = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
            $ids = @(@($j.clauses) | ForEach-Object { [string]$_.id })
            if (@($ids | Where-Object { -not $_ }).Count -gt 0) { $ok = $false }
            if (@($ids | Sort-Object -Unique).Count -ne $ids.Count) { $ok = $false }
        }
        $ok
    }

    $b9 = Get-ReviewClauses -BuildName 'battery-b9-pottery-site'
    Check "B9's checklist loads, matched by the card's repo name" {
        $b9.Found -and $b9.CardId -eq 'B9'
    }
    Check "B9's goal is cut into all nine things he asked for" {
        @($b9.Clauses).Count -eq 9
    }
    # The clause #1342 amputated: an explicit operator requirement dropped by a run that then
    # graded GREEN. If it ever falls off the checklist, the one defect this instrument was built
    # to catch becomes invisible again.
    Check 'the page #1342 dropped is on the checklist' {
        @(@($b9.Clauses) | Where-Object { $_.Text -like '*a separate page for each individual piece*' }).Count -eq 1
    }
    # The half that fails quietly: any site showing an error message at all passes "tell someone
    # politely", so the "do not lose what they typed" half has to be prompted in its own right.
    Check 'the quiet half of the form clause is prompted separately' {
        @(@($b9.Clauses) | Where-Object { @($_.Parts) -contains 'instead of just losing what they typed' }).Count -eq 1
    }

    # ---- loader mechanics: an absent or broken checklist is REPORTED ------------
    $clauseFix = Join-Path $tmp 'clause-fixtures'
    New-Item -ItemType Directory -Force -Path $clauseFix | Out-Null
    @{  schema='review-clauses/v1'; card_id='FX'; repo='fixture-site'
        goal_verbatim='I want a thing and another thing'
        clauses=@(@{ id='fx-c1'; text='a thing'; parts=@() })
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $clauseFix 'FX.json') -Encoding UTF8
    @{  schema='review-clauses/v1'; card_id='EMPTY'; repo='empty-site'
        goal_verbatim='g'; clauses=@()
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $clauseFix 'EMPTY.json') -Encoding UTF8
    '{ this is not json' | Set-Content -LiteralPath (Join-Path $clauseFix 'BROKEN.json') -Encoding UTF8

    $savedClauseRoot = $script:ClauseRoot
    try {
        $script:ClauseRoot = $clauseFix

        Check 'a checklist is matched to a build by the card repo name' {
            $c = Get-ReviewClauses -BuildName 'fixture-site'
            $c.Found -and @($c.Clauses).Count -eq 1 -and $c.Clauses[0].Id -eq 'fx-c1'
        }
        Check 'a checklist can also be matched by card id' {
            (Get-ReviewClauses -BuildName 'FX').Found
        }
        Check 'a build with NO clause file is reported, with the build named' {
            $c = Get-ReviewClauses -BuildName 'never-written-site'
            (-not $c.Found) -and $c.Reason -match 'never-written-site'
        }
        Check 'a clause file with an EMPTY clause list is not treated as a checklist' {
            $c = Get-ReviewClauses -BuildName 'empty-site'
            (-not $c.Found) -and $c.Reason -match 'EMPTY.json' -and
            $c.Reason -match 'not the same as nothing'
        }
        Check 'an unreadable clause file is NAMED, not swallowed' {
            $c = Get-ReviewClauses -BuildName 'never-written-site'
            $c.Reason -match 'BROKEN.json'
        }
    } finally { $script:ClauseRoot = $savedClauseRoot }

    # ---- the report renders the checklist -------------------------------------
    $clausesOk = [pscustomobject]@{
        Found=$true; CardId='B9'; Repo='fixture-site'; Path='configs/review-clauses/B9.json'
        GoalVerbatim='I want a home page and a form that tells someone politely if they have left something out instead of just losing what they typed'
        Reason=''
        Clauses=@(
            [pscustomobject]@{ Id='c1'; Text='a home page'; Parts=@() }
            [pscustomobject]@{ Id='c2'
                Text='tells someone politely if they have left something out instead of just losing what they typed'
                Parts=@('tells someone politely if they have left something out',
                        'instead of just losing what they typed') }
        )
    }
    $claimsForClauses = [ordered]@{
        RunId='R-9'; Verdict='GREEN'; WallClockS=1
        Goal=$clausesOk.GoalVerbatim
        Merged=@(); Skipped=@(); Parked=@(); Other=@()
        OracleStatus=''; OracleEvidence=''; OraclePath=''; DesignReview=''; Notes=''; Found=$true
    }

    $r5 = Join-Path $tmp 'r5.html'
    New-WebsiteReviewReport -Build $buildLive -Claims $claimsForClauses -Port 9999 -OutPath $r5 `
                            -Clauses $clausesOk | Out-Null
    $h5 = Get-Content -LiteralPath $r5 -Raw

    Check 'the report marks itself as carrying a checklist' { $h5 -match 'checklist:present' }
    Check 'every clause is rendered in his own words' {
        ($h5 -match 'a home page') -and ($h5 -match 'left something out instead of just losing what they typed')
    }
    Check 'both halves of a two-obligation clause are shown separately' {
        $h5 -match 'Both of these have to be true' -and
        $h5 -match '<li>instead of just losing what they typed</li>'
    }
    # "Could not tell" must be as easy to pick as the other two. Three identically-classed marks
    # per clause is what that looks like in markup: no visual demotion of the honest answer.
    Check 'all three answers are offered with identical weight on every clause' {
        ([regex]::Matches($h5, '<span class="mark">')).Count -eq (3 * @($clausesOk.Clauses).Count)
    }
    Check '"I could not tell" is offered once per clause' {
        ([regex]::Matches($h5, '>I could not tell</span>')).Count -eq @($clausesOk.Clauses).Count
    }
    Check 'the page says plainly that clicking it records nothing' {
        $h5 -match 'Nothing here records anything'
    }
    Check 'the checklist sits before the shipped list' {
        $h5.IndexOf('checklist:present') -ge 0 -and
        $h5.IndexOf('checklist:present') -lt $h5.IndexOf('What shipped')
    }

    # ---- THE ONE THAT MATTERS: a missing checklist must NOT render empty-but-clean -----
    # An empty list reads as "nothing was asked for". That is #1342's lie one layer up, and it
    # would look completely successful. This check fails if the section ever renders as a clean
    # empty table instead of saying, in words, that no checklist exists.
    $r6 = Join-Path $tmp 'r6.html'
    New-WebsiteReviewReport -Build $buildLive -Claims $claimsForClauses -Port 9999 -OutPath $r6 `
                            -Clauses $null | Out-Null
    $h6 = Get-Content -LiteralPath $r6 -Raw

    Check 'a MISSING checklist says so in words, and renders no list at all' {
        ($h6 -match 'checklist:absent') -and
        ($h6 -match 'No checklist has been written') -and
        ($h6 -notmatch 'checklist:present') -and
        ($h6 -notmatch '<table class="clauses"') -and
        ($h6 -notmatch '<span class="mark">')
    }
    Check 'a missing checklist is NOT dressed as a clean pass' {
        $h6 -match 'does <strong>not</strong> mean nothing was asked for' -and
        $h6 -notmatch 'section class="checklist"'
    }
    # The sneak path to empty-but-clean: a clause file that loaded but produced no clauses.
    Check 'a checklist that loaded EMPTY degrades to the missing rendering' {
        $r7 = Join-Path $tmp 'r7.html'
        $hollow = [pscustomobject]@{
            Found=$true; CardId='X'; Repo='r'; Path='p'; GoalVerbatim='g'; Reason=''; Clauses=@()
        }
        New-WebsiteReviewReport -Build $buildLive -Claims $claimsForClauses -Port 9999 -OutPath $r7 `
                                -Clauses $hollow | Out-Null
        $h7 = Get-Content -LiteralPath $r7 -Raw
        ($h7 -match 'checklist:absent') -and ($h7 -notmatch '<table class="clauses"')
    }

    # -----------------------------------------------------------------------
    # The pictures (#1345) — his two remaining complaints, neither of them a broken link
    # -----------------------------------------------------------------------

    $medFind = [pscustomobject]@{ Measured=$true; Reason=''; Hard=$true; Notes=@()
        Findings=@(
            [pscustomobject]@{ severity='high'; message='3 different products all show the same picture.' },
            [pscustomobject]@{ severity='low';  message='Bowls Collection is shown using a banner image.' }) }
    $medClean = [pscustomobject]@{ Measured=$true; Reason=''; Hard=$false; Findings=@(); Notes=@() }
    $medNone  = [pscustomobject]@{ Measured=$false; Reason='this site declares no media'; Hard=$false
                                   Findings=@(); Notes=@() }

    $rm1 = Join-Path $tmp 'rm1.html'
    New-WebsiteReviewReport -Build $buildLive -Claims $claimsForClauses -Port 9999 -OutPath $rm1 `
                            -Clauses $null -Links $null -Exam $null -Media $medFind | Out-Null
    $hm1 = Get-Content -LiteralPath $rm1 -Raw

    Check 'a repeated product photograph is reported in his words' {
        ($hm1 -match 'media:findings') -and ($hm1 -match 'same picture') -and ($hm1 -match 'class="alert"')
    }
    Check 'the guessed findings are separated from the certain ones' {
        ($hm1 -match 'less certain') -and ($hm1 -match 'guessed from file names')
    }

    $rm2 = Join-Path $tmp 'rm2.html'
    New-WebsiteReviewReport -Build $buildLive -Claims $claimsForClauses -Port 9999 -OutPath $rm2 `
                            -Clauses $null -Links $null -Exam $null -Media $medNone | Out-Null
    $hm2 = Get-Content -LiteralPath $rm2 -Raw
    Check 'a site with NO pictures is not reported as pictures-are-fine' {
        ($hm2 -match 'media:unmeasured') -and ($hm2 -notmatch 'media:clean') -and
        ($hm2 -match 'not</em> a clean result')
    }

    $rm3 = Join-Path $tmp 'rm3.html'
    New-WebsiteReviewReport -Build $buildLive -Claims $claimsForClauses -Port 9999 -OutPath $rm3 `
                            -Clauses $null -Links $null -Exam $null -Media $medClean | Out-Null
    $hm3 = Get-Content -LiteralPath $rm3 -Raw
    Check 'a clean picture check still states the limit it did NOT check' {
        ($hm3 -match 'media:clean') -and ($hm3 -match 'never opens an image')
    }
    Check 'no picture check at all is UNKNOWN, never fine' {
        $rm4 = Join-Path $tmp 'rm4.html'
        New-WebsiteReviewReport -Build $buildLive -Claims $claimsForClauses -Port 9999 -OutPath $rm4 `
                                -Clauses $null -Links $null -Exam $null -Media $null | Out-Null
        $h = Get-Content -LiteralPath $rm4 -Raw
        ($h -match 'media:absent') -and ($h -match 'Not checked') -and ($h -notmatch 'media:clean')
    }
    Check 'picture findings are HTML-escaped' {
        $rm5 = Join-Path $tmp 'rm5.html'
        $evil = [pscustomobject]@{ Measured=$true; Reason=''; Hard=$true; Notes=@()
            Findings=@([pscustomobject]@{ severity='high'; message='<script>alert(1)</script>' }) }
        New-WebsiteReviewReport -Build $buildLive -Claims $claimsForClauses -Port 9999 -OutPath $rm5 `
                                -Clauses $null -Links $null -Exam $null -Media $evil | Out-Null
        (Get-Content -LiteralPath $rm5 -Raw) -notmatch '<script>alert'
    }
    # THE SIBLING OF THE LINK-CHECKER FIX, and it was missed by the fix that named the problem.
    # `aa2a949` rebuilt the link check hermetically because it pinned its subject to
    # `Get-WebsiteBuilds | Select -First 1` — the LIVE `~/projects` sandbox, which every dispatch
    # archives and recreates. This check, one function away, had the identical shape and the
    # identical fail-open (`if (-not $rb) { $true }` passes VACUOUSLY when no B9 build happens to
    # be sitting there). `git diff f05b951 aa2a949` touches zero MediaLint lines.
    #
    # That is lesson 342 — sweep for siblings — and it was cited in a commit on this repo the same
    # afternoon (`2238a1d`, "the web-static hint had the identical defect"). Applied there, not
    # applied here, hours apart. A fix that names its own class and does not grep for it is half a
    # fix.
    #
    # The tree is BUILT HERE. Three items sharing one photograph crosses the grader's own
    # REPEAT_THRESHOLD of 3 and must produce a HIGH finding.
    $medTree = Join-Path $tmp 'media-tree'
    New-Item -ItemType Directory -Force -Path (Join-Path $medTree 'public\assets') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $medTree 'data') | Out-Null
    foreach ($img in @('mug.png', 'bowl.png')) {
        [System.IO.File]::WriteAllBytes((Join-Path $medTree "public\assets\$img"), [byte[]](1..64))
    }
    Set-Content -LiteralPath (Join-Path $medTree 'public\index.html') -Encoding utf8 -Value @'
<!doctype html><html><body><img src="assets/mug.png"><img src="assets/bowl.png"></body></html>
'@
    $medRepeated = @(
        @{ id = 1; name = 'Classic Mug';  description = 'a mug';  category = 'mug';  price = 25; image = 'assets/mug.png' }
        @{ id = 2; name = 'Garden Mug';   description = 'a mug';  category = 'mug';  price = 30; image = 'assets/mug.png' }
        @{ id = 3; name = 'Travel Mug';   description = 'a mug';  category = 'mug';  price = 28; image = 'assets/mug.png' }
        @{ id = 4; name = 'Rustic Bowl';  description = 'a bowl'; category = 'bowl'; price = 35; image = 'assets/bowl.png' }
    )
    Set-Content -LiteralPath (Join-Path $medTree 'data\pieces.json') -Encoding utf8 `
                -Value ($medRepeated | ConvertTo-Json -Depth 4)

    Check 'the REAL picture grader finds a real repeated photograph in a real tree' {
        $r = Invoke-MediaLint -SitePath $medTree
        $r.Measured -and (@($r.Findings | Where-Object { $_.severity -eq 'high' }).Count -ge 1)
    }
    # The toggle. Without it, a grader that cried "repeated" at every gallery would pass the
    # check above and read as a working instrument: "found the repetition" and "always says
    # repetition" are the same green. Giving each piece its own picture is the only difference.
    Check 'and the SAME tree reads clean once every piece has its own picture' {
        [System.IO.File]::WriteAllBytes((Join-Path $medTree 'public\assets\vase.png'), [byte[]](1..64))
        [System.IO.File]::WriteAllBytes((Join-Path $medTree 'public\assets\cup.png'), [byte[]](1..64))
        $distinct = @(
            @{ id = 1; name = 'Classic Mug'; description = 'a mug';  category = 'mug';  price = 25; image = 'assets/mug.png' }
            @{ id = 2; name = 'Rustic Bowl'; description = 'a bowl'; category = 'bowl'; price = 35; image = 'assets/bowl.png' }
            @{ id = 3; name = 'Modern Vase'; description = 'a vase'; category = 'vase'; price = 45; image = 'assets/vase.png' }
            @{ id = 4; name = 'Tea Cup';     description = 'a cup';  category = 'cup';  price = 20; image = 'assets/cup.png' }
        )
        Set-Content -LiteralPath (Join-Path $medTree 'data\pieces.json') -Encoding utf8 `
                    -Value ($distinct | ConvertTo-Json -Depth 4)
        $r = Invoke-MediaLint -SitePath $medTree
        $r.Measured -and (@($r.Findings | Where-Object { $_.severity -eq 'high' }).Count -eq 0)
    }
    Check 'the picture grader refuses a path that does not exist' {
        $r = Invoke-MediaLint -SitePath (Join-Path $tmp 'no-such-site')
        (-not $r.Measured) -and ($r.Reason -match 'nothing at')
    }

    # -----------------------------------------------------------------------
    # Was the exam any good? (#1342) — the context that makes his verdict a measurement
    # -----------------------------------------------------------------------
    # The negative renderings carry this section. A site graded by an exam nobody checked
    # must NOT look like a site graded by a real one, and a missing record must not look
    # like a clean one. That distinction is the entire finding of 2026-08-08.

    $examOk   = [pscustomobject]@{ Found=$true;  Conclusive=$true;  Verdict='seed'; Reasons=@();          Reason='' }
    $examBad  = [pscustomobject]@{ Found=$true;  Conclusive=$false; Verdict='seed'
                                   Reasons=@('the exam was never run against a version of the site where the page did not exist'); Reason='' }
    $examNone = [pscustomobject]@{ Found=$false; Conclusive=$false; Verdict='';     Reasons=@()
                                   Reason='This run left no record of checking its own exam.' }

    $re1 = Join-Path $tmp 're1.html'
    New-WebsiteReviewReport -Build $buildLive -Claims $claimsForClauses -Port 9999 -OutPath $re1 `
                            -Clauses $null -Links $null -Exam $examBad | Out-Null
    $he1 = Get-Content -LiteralPath $re1 -Raw

    Check 'an exam that was never shown able to fail is an ALERT, in his words' {
        ($he1 -match 'exam:unvalidated') -and ($he1 -match 'never shown able to fail') -and
        ($he1 -match 'class="alert"') -and ($he1 -match 'Your eyes are the only real check')
    }
    Check 'the unvalidated exam names WHY, not just that' {
        $he1 -match 'never run against a version of the site where the page did not exist'
    }

    $re2 = Join-Path $tmp 're2.html'
    New-WebsiteReviewReport -Build $buildLive -Claims $claimsForClauses -Port 9999 -OutPath $re2 `
                            -Clauses $null -Links $null -Exam $examNone | Out-Null
    $he2 = Get-Content -LiteralPath $re2 -Raw

    Check 'NO record of the exam check is UNKNOWN, never "fine"' {
        ($he2 -match 'exam:unknown') -and ($he2 -match '<strong>Unknown\.</strong>') -and
        ($he2 -notmatch 'exam:validated') -and ($he2 -notmatch 'was itself checked')
    }

    $re3 = Join-Path $tmp 're3.html'
    New-WebsiteReviewReport -Build $buildLive -Claims $claimsForClauses -Port 9999 -OutPath $re3 `
                            -Clauses $null -Links $null -Exam $examOk | Out-Null
    $he3 = Get-Content -LiteralPath $re3 -Raw

    Check 'a validated exam reads as validated' {
        ($he3 -match 'exam:validated') -and ($he3 -match 'was itself checked') -and
        ($he3 -notmatch 'exam:unvalidated')
    }
    Check 'validated, unvalidated and unknown are THREE distinct renderings' {
        ($he3 -match 'exam:validated') -and ($he1 -match 'exam:unvalidated') -and ($he2 -match 'exam:unknown')
    }
    Check 'no Exam at all renders as unknown, not as a pass' {
        $re4 = Join-Path $tmp 're4.html'
        New-WebsiteReviewReport -Build $buildLive -Claims $claimsForClauses -Port 9999 -OutPath $re4 `
                                -Clauses $null -Links $null -Exam $null | Out-Null
        $h = Get-Content -LiteralPath $re4 -Raw
        ($h -match 'exam:unknown') -and ($h -notmatch 'exam:validated')
    }

    # The REAL reader over the REAL run record.
    Check 'the REAL exam reader convicts the REAL unvalidated exam' {
        $rd = Find-RunRecordForRepo -RepoLeaf 'battery-b9-pottery-site'
        if (-not $rd) { $true }   # no B9 run on this box
        else {
            $r = Get-ExamQuality -RunDir $rd
            $r.Found -and (-not $r.Conclusive) -and (@($r.Reasons).Count -ge 1)
        }
    }
    Check 'a missing run folder is UNKNOWN, and says so' {
        $r = Get-ExamQuality -RunDir (Join-Path $tmp 'no-such-run')
        (-not $r.Found) -and (-not $r.Conclusive) -and ($r.Reason -match 'No run folder')
    }
    # A record written BEFORE findings_conclusive existed must not be read as validated
    # just because the field is absent: absence of the field is absence of the check.
    Check 'a pre-#1342 record is derived from its raw stamps, not assumed good' {
        $rd = Join-Path $tmp 'oldrun'; New-Item -ItemType Directory -Path $rd -Force | Out-Null
        '{"validated":true,"findings_total":0,"f2p_baseline":"not-run","collectability":"skipped"}' |
            Set-Content -LiteralPath (Join-Path $rd 'oracle-qa.json') -Encoding utf8
        $r = Get-ExamQuality -RunDir $rd
        $r.Found -and (-not $r.Conclusive) -and (@($r.Reasons).Count -eq 2)
    }
    # The format tonight's runs write (#1342 item 2, 83633ce0). The fallback below covers
    # records written BEFORE that landed; without these two, the reader could be verified
    # entirely against a format the system has stopped producing.
    Check 'the NEW findings_conclusive format is read, unvalidated case' {
        $rd = Join-Path $tmp 'newfmt1'; New-Item -ItemType Directory -Path $rd -Force | Out-Null
        '{"validated":true,"findings_total":0,"findings_conclusive":false,"not_measured":["the oracle was never run against a tree where the product does not exist, so it has NOT been shown capable of failing"],"f2p_baseline":"not-run","collectability":"skipped"}' |
            Set-Content -LiteralPath (Join-Path $rd 'oracle-qa.json') -Encoding utf8
        $r = Get-ExamQuality -RunDir $rd
        $r.Found -and (-not $r.Conclusive) -and (@($r.Reasons).Count -ge 1) -and
        (@($r.Reasons)[0] -match 'shown capable of failing')
    }
    Check 'the NEW format validated case reads as validated, with no reasons' {
        $rd = Join-Path $tmp 'newfmt2'; New-Item -ItemType Directory -Path $rd -Force | Out-Null
        '{"validated":true,"findings_total":0,"findings_conclusive":true,"not_measured":[],"f2p_baseline":"all-fail","collectability":"confirmed"}' |
            Set-Content -LiteralPath (Join-Path $rd 'oracle-qa.json') -Encoding utf8
        $r = Get-ExamQuality -RunDir $rd
        $r.Found -and $r.Conclusive -and (@($r.Reasons).Count -eq 0)
    }
    # The reasons must come from the RECORD, not be re-derived - otherwise a future change to
    # the writer's wording would silently stop reaching him.
    Check 'the NEW format quotes the run record own words, not a local rewrite' {
        $rd = Join-Path $tmp 'newfmt3'; New-Item -ItemType Directory -Path $rd -Force | Out-Null
        '{"findings_conclusive":false,"not_measured":["A DISTINCTIVE SENTINEL PHRASE"],"f2p_baseline":"not-run","collectability":"not-run"}' |
            Set-Content -LiteralPath (Join-Path $rd 'oracle-qa.json') -Encoding utf8
        (@((Get-ExamQuality -RunDir $rd).Reasons) -join ' ') -match 'A DISTINCTIVE SENTINEL PHRASE'
    }

    Check 'a pre-#1342 record with REAL stamps is read as validated' {
        $rd = Join-Path $tmp 'oldrun2'; New-Item -ItemType Directory -Path $rd -Force | Out-Null
        '{"validated":true,"findings_total":0,"f2p_baseline":"all-fail","collectability":"confirmed"}' |
            Set-Content -LiteralPath (Join-Path $rd 'oracle-qa.json') -Encoding utf8
        (Get-ExamQuality -RunDir $rd).Conclusive
    }

    # -----------------------------------------------------------------------
    # The link check (#1345) — the defect he found by hand, checked automatically
    # -----------------------------------------------------------------------
    # The load-bearing checks here are the NEGATIVE ones. A link check that could not run
    # must not render like a site with no broken links: that is a clean-looking result
    # from a check that never happened, which is the exact failure this whole section
    # exists to catch, aimed at the one reader whose verdict the loop collects.

    $lnkBroken = [pscustomobject]@{
        Measured = $true; Reason = ''; Broken = 2; Undecidable = 3; Resolved = 30
        Findings = @([pscustomobject]@{ reference = 'piece-detail.html?id=1'; severity = 'high'
                                        message  = 'points at a page that is not in the delivered site' })
    }
    $lnkClean  = [pscustomobject]@{ Measured=$true; Reason=''; Broken=0; Undecidable=0; Resolved=30; Findings=@() }
    $lnkUnmeas = [pscustomobject]@{ Measured=$false; Reason='no interpreter at C:
ope\python.exe'
                                    Broken=0; Undecidable=0; Resolved=0; Findings=@() }

    $rl1 = Join-Path $tmp 'rl1.html'
    New-WebsiteReviewReport -Build $buildLive -Claims $claimsForClauses -Port 9999 -OutPath $rl1 `
                            -Clauses $null -Links $lnkBroken | Out-Null
    $hl1 = Get-Content -LiteralPath $rl1 -Raw

    Check 'a broken link is named on the page, not just counted' {
        ($hl1 -match 'links:broken') -and ($hl1 -match 'piece-detail\.html') -and
        ($hl1 -match '2 link\(s\) on this site lead nowhere')
    }
    Check 'a broken link is rendered as an alert, not a note' { $hl1 -match 'links:broken[\s\S]{0,200}class="alert"' }
    Check 'undecidable links are reported as UNCHECKED beside the broken ones' {
        ($hl1 -match 'could not be followed') -and ($hl1 -match 'unchecked')
    }

    $rl2 = Join-Path $tmp 'rl2.html'
    New-WebsiteReviewReport -Build $buildLive -Claims $claimsForClauses -Port 9999 -OutPath $rl2 `
                            -Clauses $null -Links $lnkUnmeas | Out-Null
    $hl2 = Get-Content -LiteralPath $rl2 -Raw

    Check 'a link check that COULD NOT RUN never renders as clean' {
        ($hl2 -match 'links:unmeasured') -and ($hl2 -notmatch 'links:clean') -and
        ($hl2 -notmatch 'class="ok"[\s\S]{0,120}lead nowhere') -and
        ($hl2 -match 'not</em> a clean result')
    }
    Check 'an unrunnable link check gives its reason in plain words' { $hl2 -match 'no interpreter at' }

    $rl3 = Join-Path $tmp 'rl3.html'
    New-WebsiteReviewReport -Build $buildLive -Claims $claimsForClauses -Port 9999 -OutPath $rl3 `
                            -Clauses $null -Links $null | Out-Null
    $hl3 = Get-Content -LiteralPath $rl3 -Raw

    Check 'NO link check at all is UNKNOWN, never "fine"' {
        ($hl3 -match 'links:absent') -and ($hl3 -match 'Not checked') -and
        ($hl3 -match 'unknown') -and ($hl3 -notmatch 'links:clean')
    }

    $rl4 = Join-Path $tmp 'rl4.html'
    New-WebsiteReviewReport -Build $buildLive -Claims $claimsForClauses -Port 9999 -OutPath $rl4 `
                            -Clauses $null -Links $lnkClean | Out-Null
    $hl4 = Get-Content -LiteralPath $rl4 -Raw

    Check 'a genuinely clean link check reads as clean' {
        ($hl4 -match 'links:clean') -and ($hl4 -match 'None\.') -and ($hl4 -notmatch 'links:broken')
    }
    Check 'measured-clean and could-not-run are DIFFERENT renderings' {
        ($hl4 -match 'links:clean') -and ($hl2 -match 'links:unmeasured')
    }
    Check 'link findings are HTML-escaped' {
        $rl5 = Join-Path $tmp 'rl5.html'
        $evil = [pscustomobject]@{
            Measured=$true; Reason=''; Broken=1; Undecidable=0; Resolved=0
            Findings=@([pscustomobject]@{ reference='<script>alert(1)</script>'; severity='high'; message='x' })
        }
        New-WebsiteReviewReport -Build $buildLive -Claims $claimsForClauses -Port 9999 -OutPath $rl5 `
                                -Clauses $null -Links $evil | Out-Null
        (Get-Content -LiteralPath $rl5 -Raw) -notmatch '<script>alert'
    }

    # The REAL module, driven end to end — the fixtures above prove the rendering, this
    # proves the thing being rendered is produced by the actual checker over a real tree
    # on disk. The tree is BUILT HERE, deliberately.
    #
    # This pair replaces a check that pinned its subject to `Get-WebsiteBuilds | Select -First 1`
    # — which resolves to the LIVE sandbox, a directory every dispatch archives and recreates.
    # It asserted that the delivered B9 site contains a broken `piece-detail` reference. That is
    # a fact about a past artifact, not a property of this code, and it went red the moment a
    # killed run left a different tree in that path (the 08-11 remnant: four pages, no
    # `piece-detail.html`, nothing broken to find). A regression lock must not be hostage to a
    # mutable working directory — that evidence belongs in the archive and on #1367/#1375, and
    # re-deriving it nightly makes the lock measure the sandbox instead of the checker. Same
    # class as BlarAI's tests/security/test_evidence_is_immutable.py (#1355).
    $lnkTree = Join-Path $tmp 'real-tree'
    New-Item -ItemType Directory -Force -Path (Join-Path $lnkTree 'public') | Out-Null
    Set-Content -LiteralPath (Join-Path $lnkTree 'public\index.html') -Encoding utf8 -Value @'
<!doctype html><html><body>
  <a href="pieces.html">Pieces</a>
  <a href="piece-detail.html">View Details</a>
</body></html>
'@
    Set-Content -LiteralPath (Join-Path $lnkTree 'public\pieces.html') -Encoding utf8 -Value '<!doctype html><html><body>ok</body></html>'

    Check 'the REAL link checker finds a real dead reference in a real tree' {
        $r = Invoke-LinkLint -SitePath $lnkTree
        $r.Measured -and $r.Broken -ge 1 -and
        (@($r.Findings) | Where-Object { $_.reference -match 'piece-detail' }).Count -ge 1
    }
    # The toggle. Without it, a checker that reported "broken" unconditionally would pass the
    # check above and nobody would know: "found the defect" and "always says defect" are the
    # same green. Building the missing page is the only difference between the two trees.
    Check 'and reports the SAME tree clean once the missing page exists' {
        Set-Content -LiteralPath (Join-Path $lnkTree 'public\piece-detail.html') -Encoding utf8 `
                    -Value '<!doctype html><html><body>detail</body></html>'
        $r = Invoke-LinkLint -SitePath $lnkTree
        $r.Measured -and $r.Broken -eq 0
    }
    Check 'the link checker refuses a path that does not exist, and says why' {
        $r = Invoke-LinkLint -SitePath (Join-Path $tmp 'no-such-site')
        (-not $r.Measured) -and ($r.Reason -match 'nothing at')
    }

    Check 'clause text is HTML-escaped' {
        $r8 = $null
        $r8 = Join-Path $tmp 'r8.html'
        $hostile = [pscustomobject]@{
            Found=$true; CardId='X'; Repo='r'; Path='p'; GoalVerbatim=''; Reason=''
            Clauses=@([pscustomobject]@{ Id='h1'; Text='<script>alert(2)</script>'
                                         Parts=@('<img src=x onerror=2>') })
        }
        New-WebsiteReviewReport -Build $buildLive -Claims $claimsForClauses -Port 9999 -OutPath $r8 `
                                -Clauses $hostile | Out-Null
        $h8 = Get-Content -LiteralPath $r8 -Raw
        ($h8 -notmatch '<script>alert\(2\)') -and ($h8 -notmatch '<img src=x')
    }

    # ---- drift: is he grading against what the run was actually asked for? -----
    Check 'a clause missing from the run goal is flagged as drift' {
        $r9 = Join-Path $tmp 'r9.html'
        $drifted = [ordered]@{
            RunId='R-9'; Verdict='GREEN'; WallClockS=1
            Goal='a completely different goal about something else'
            Merged=@(); Skipped=@(); Parked=@(); Other=@()
            OracleStatus=''; OracleEvidence=''; OraclePath=''; DesignReview=''; Notes=''; Found=$true
        }
        New-WebsiteReviewReport -Build $buildLive -Claims $drifted -Port 9999 -OutPath $r9 `
                                -Clauses $clausesOk | Out-Null
        (Get-Content -LiteralPath $r9 -Raw) -match 'class="drift"'
    }
    Check 'a checklist that MATCHES the run goal raises no drift warning' {
        $h5 -notmatch 'class="drift"'
    }
    Check 'drift reports NOT-CHECKED when there is no goal to compare against' {
        $d = Get-ClauseGoalDrift -Clauses $clausesOk -Goal ''
        (-not $d.Checked) -and @($d.Drifted).Count -eq 0
    }

    # ---- the record: what actually survives the review -------------------------
    $partial = @(
        [pscustomobject]@{ Id='c1'; Mark='met';            Words='' }
        [pscustomobject]@{ Id='c2'; Mark='could-not-tell'; Words='I could not find the form' }
    )
    $recFull = New-OperatorReviewRecord -Build $buildLive -Claims $claimsForClauses `
                                        -Clauses $clausesOk -Marks $partial `
                                        -Feedback @('the photos are too big') -Pages @('index.html')

    Check 'the checklist is recorded against the run' {
        $recFull.Json.checklist.available -eq $true -and
        @($recFull.Json.checklist.clauses).Count -eq 2
    }
    Check '"could not tell" is recorded as its own answer, with his words' {
        $c = @($recFull.Json.checklist.clauses)[1]
        $c.mark -eq 'could-not-tell' -and $c.words -eq 'I could not find the form'
    }
    Check 'his free-text verdict still lands unchanged' {
        @($recFull.Json.operator_feedback)[0] -eq 'the photos are too big'
    }
    Check 'the v1 fields a reader already depends on are still there' {
        $j = $recFull.Json
        $j.Contains('build_name') -and $j.Contains('run_id') -and $j.Contains('pages') -and
        $j.Contains('skipped_tasks') -and $j.Contains('verdict_at_review') -and
        $j.Contains('operator_feedback')
    }
    # SPLIT 2026-08-14 (lesson 350). This was one check asserting the literal
    # `operator-website-review/v2`, so a LEGITIMATE schema bump reddened the check whose NAME says
    # "the schema is bumped" — the assertion defended the version it was written against. The
    # property and the version now travel separately: a real bump reds only the second one, whose
    # message says so, while the property keeps guarding.
    Check 'the schema is bumped, so a pre-checklist review is not read as an unanswered one' {
        $s = [string]$recFull.Json.schema
        ($s -match '^operator-website-review/v(\d+)$') -and ([int]$Matches[1] -ge 2)
    }
    Check 'the CURRENT schema version is the one this suite was written against' {
        # Bumping the schema is allowed and expected; bumping it without updating this line is
        # what must be caught. If you are here after a deliberate bump, move the version and say
        # in the commit what the new field is.
        $recFull.Json.schema -eq 'operator-website-review/v3'
    }

    # ---- escaped defects (DoD capability 12) ----
    # A defect the GATES PASSED and he then found. Derived from marks already taken: a clause he
    # marked `not-met` on a build the pipeline banded is, by definition, one they missed.
    $escapedMarks = @(
        [pscustomobject]@{ Id='c1'; Mark='not-met'; Words='the View Details button goes to a JSON error' }
        [pscustomobject]@{ Id='c2'; Mark='met';     Words='' }
    )
    $recEsc = New-OperatorReviewRecord -Build $buildLive -Claims $claimsForClauses `
                                       -Clauses $clausesOk -Marks $escapedMarks -Feedback @()

    Check 'a clause he marked NOT-MET on a banded build is counted as an escaped defect' {
        $e = $recEsc.Json.escaped_defects
        $e -and ($e.measured -eq $true) -and ($e.count -eq 1)
    }
    Check 'the escaped-defect count carries its denominator, so it can become a RATE' {
        $e = $recEsc.Json.escaped_defects
        ($e.denominator -ge $e.count) -and ($e.denominator -eq 2)
    }
    Check 'the escaped clauses are NAMED and carry his words, not just counted' {
        $c = @($recEsc.Json.escaped_defects.clauses)
        ($c.Count -eq 1) -and [string]$c[0].text -and ($c[0].words -match 'JSON error')
    }
    Check 'the band the gates gave is recorded beside the count' {
        [string]$recEsc.Json.escaped_defects.verdict_at_review
    }
    Check 'the count states that it is a FLOOR, not a total' {
        [string]$recEsc.Json.escaped_defects.scope_note -match 'FLOOR'
    }
    Check 'the markdown NAMES what the gates missed, in his words' {
        ($recEsc.Markdown -match 'What the gates missed') -and
        ($recEsc.Markdown -match 'JSON error') -and ($recEsc.Markdown -match 'floor, not a total')
    }
    # --- the three ways this must refuse to report a zero -------------------------------------
    Check 'a genuinely clean review reads as NONE FOUND, measured' {
        $e = $recFull.Json.escaped_defects       # marks: met + could-not-tell, no not-met
        ($e.measured -eq $true) -and ($e.count -eq 0)
    }
    Check 'could-not-tell is NOT counted as an escaped defect' {
        # $recFull carries a could-not-tell and counts zero — silence is not a defect.
        @($recFull.Json.escaped_defects.clauses).Count -eq 0
    }
    Check 'NO checklist means NOT MEASURED, never a count of zero' {
        $r = New-OperatorReviewRecord -Build $buildLive -Claims $claimsForClauses -Clauses $null `
                                      -Marks @() -Feedback @('x')
        $e = $r.Json.escaped_defects
        ($e.measured -eq $false) -and ($null -eq $e.count) -and ($e.reason -match 'not a count of zero')
    }
    Check 'NO verdict means NOT MEASURED either — escaped is relative to a gate that passed it' {
        $noVerdict = [pscustomobject]@{
            Found=$true; CardId='B9'; Repo='r'; Path='p'; GoalVerbatim='g'; Reason=''
            RunId='run-x'; Goal='g'; Verdict=''; Skipped=@()
        }
        $r = New-OperatorReviewRecord -Build $buildLive -Claims $noVerdict -Clauses $clausesOk `
                                      -Marks $escapedMarks -Feedback @()
        $e = $r.Json.escaped_defects
        ($e.measured -eq $false) -and ($null -eq $e.count)
    }
    # THE THIRD REFUSAL — found by adversarial review of the first version, 2026-08-14.
    Check 'a checklist he answered NONE of is NOT MEASURED, never a count of zero' {
        # review-website.ps1:233 breaks on `q` BEFORE the first mark is recorded, and the
        # free-text prompt afterwards still writes a record. Checklist loaded, verdict present,
        # zero marks. The old code reported measured=true/count=0 and rendered "None found."
        $r = New-OperatorReviewRecord -Build $buildLive -Claims $claimsForClauses `
                                      -Clauses $clausesOk -Marks @() -Feedback @('the photos are too big')
        $e = $r.Json.escaped_defects
        ($e.measured -eq $false) -and ($null -eq $e.count) -and ($e.reason -match 'answered none of it')
    }
    Check 'and its markdown does NOT say none found' {
        $r = New-OperatorReviewRecord -Build $buildLive -Claims $claimsForClauses `
                                      -Clauses $clausesOk -Marks @() -Feedback @('x')
        ($r.Markdown -match 'Not measured') -and ($r.Markdown -notmatch 'None found')
    }
    Check 'the DENOMINATOR is clauses he DECIDED, not the checklist length' {
        # An un-reviewed clause carries no ground truth. Counting it as a non-escape puts an
        # unmeasured item on the "everything is fine" side of the ratio.
        $partial = @(
            [pscustomobject]@{ Id='c1'; Mark='not-met'; Words='the button is dead' }
            [pscustomobject]@{ Id='c2'; Mark='could-not-tell'; Words='could not find it' }
        )
        $r = New-OperatorReviewRecord -Build $buildLive -Claims $claimsForClauses `
                                      -Clauses $clausesOk -Marks $partial -Feedback @()
        $e = $r.Json.escaped_defects
        ($e.count -eq 1) -and ($e.denominator -eq 1) -and ($e.reviewed -eq 2) -and ($e.clauses_total -eq 2)
    }
    Check 'abandoning a review cannot flatter the rate — coverage is stated beside it' {
        $one = @([pscustomobject]@{ Id='c1'; Mark='met'; Words='' })
        $r = New-OperatorReviewRecord -Build $buildLive -Claims $claimsForClauses `
                                      -Clauses $clausesOk -Marks $one -Feedback @()
        ($r.Json.escaped_defects.denominator -eq 1) -and
        ($r.Markdown -match 'definitive answer on 1 of 2')
    }

    Check 'the markdown says NOT MEASURED rather than none, when there is no checklist' {
        $r = New-OperatorReviewRecord -Build $buildLive -Claims $claimsForClauses -Clauses $null `
                                      -Marks @() -Feedback @('x')
        ($r.Markdown -match 'What the gates missed') -and ($r.Markdown -match 'Not measured')
    }
    Check 'drift is banked in the record, not only drawn on the page' {
        $recFull.Json.checklist.Contains('goal_drift_checked') -and
        $recFull.Json.checklist.goal_drift_checked -eq $true
    }

    # A review stopped half way must not read afterwards as considered answers. This is the
    # instrument-honesty failure the whole loop exists to prevent, aimed at itself.
    Check 'a clause he never reached is NOT-REVIEWED, never COULD-NOT-TELL' {
        $recStopped = New-OperatorReviewRecord -Build $buildLive -Claims $claimsForClauses `
                          -Clauses $clausesOk `
                          -Marks @([pscustomobject]@{ Id='c1'; Mark='met'; Words='' })
        $rows = @($recStopped.Json.checklist.clauses)
        $rows[1].mark -eq 'not-reviewed' -and
        $recStopped.Json.checklist.counts['not-reviewed'] -eq 1 -and
        $recStopped.Json.checklist.counts['could-not-tell'] -eq 0
    }
    Check 'the markdown he can read spells the marks in plain words' {
        $md = $recFull.Markdown -join "`n"
        $md -match 'clause by clause' -and $md -match '\*\*yes\*\*' -and $md -match '\*\*could not tell\*\*'
    }
    Check 'a review with NO checklist records why, and says the blank means nothing' {
        $none = [pscustomobject]@{
            Found=$false; CardId=''; Repo=''; Path=''; GoalVerbatim=''; Clauses=@()
            Reason='No clause file names this site.'
        }
        $rec = New-OperatorReviewRecord -Build $buildLive -Claims $claimsForClauses -Clauses $none `
                                        -Feedback @('looks fine')
        $md = $rec.Markdown -join "`n"
        $rec.Json.checklist.available -eq $false -and
        $rec.Json.checklist.reason -match 'No clause file' -and
        $md -match 'says' -and $md -match 'nothing about whether the site met'
    }

    # ---- the port chooser must never hand back a live service's port -----------
    Check 'the review port avoids the assistant (5001) and Vikunja (3456)' {
        $p = Get-FreeTcpPort
        $p -ne 5001 -and $p -ne 3456 -and $p -gt 1024
    }

    # The bug this locks, measured 2026-08-08 while verifying this very script: the probe bound
    # 127.0.0.1 while node binds `::`, so a port already serving read as free. The review server
    # then died with EADDRINUSE and the PREVIOUS review's process answered every request — the
    # operator would have been shown a different build under the current one's name, with the
    # report claiming success throughout. An IPv6-listening socket is the exact shape that fooled
    # the old probe, so that is what this test stands up.
    Check 'a port held by an IPv6-ANY listener is NOT offered as free' {
        $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::IPv6Any, 8477)
        $l.Server.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::IPv6,
                                  [System.Net.Sockets.SocketOptionName]::IPv6Only, $false)
        $l.Start()
        try {
            # Sanity: the OLD probe would have called this free. If this assertion ever fails the
            # platform has changed and the test below is no longer proving anything.
            $ipv4Probe = $true
            try {
                $l4 = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 8477)
                $l4.Start(); $l4.Stop()
            } catch { $ipv4Probe = $false }
            (Get-FreeTcpPort -Start 8477 -Tries 5) -ne 8477 -and $ipv4Probe
        } finally { $l.Stop() }
    }

    # ---- the identity guard: a foreign server must be REFUSED, not presented -----
    # security_by_design principle 12 — this control ships with proof it fires. Without the
    # refusal case, a guard that had been edited into always-returning-true would look identical.
    Check 'a FOREIGN server on the port is refused, not presented' {
        $squat = Start-Process node -ArgumentList '-e', `
            "require('http').createServer((q,s)=>s.end('someone-elses-build')).listen(8478)" `
            -NoNewWindow -PassThru
        try {
            Start-Sleep -Milliseconds 1200
            $threw = $false
            try {
                Assert-ServingThisBuild -Port 8478 -Token 'my-token' -Proc $null -Attempts 3 | Out-Null
            } catch { $threw = $_.Exception.Message -match 'DIFFERENT build' }
            $threw
        } finally { Stop-Process -Id $squat.Id -Force -ErrorAction SilentlyContinue }
    }

    Check 'a port with NOTHING on it is refused, not presented' {
        $threw = $false
        try { Assert-ServingThisBuild -Port 8479 -Token 't' -Proc $null -Attempts 2 | Out-Null }
        catch { $threw = $_.Exception.Message -match 'never answered' }
        $threw
    }

    Check 'a server that died on startup is refused, and the reason is carried' {
        $log = Join-Path $tmp 'died.log'
        'Error: listen EADDRINUSE: address already in use :::8420' | Set-Content $log
        $dead = Start-Process node -ArgumentList '-e', 'process.exit(1)' -NoNewWindow -PassThru
        $dead.WaitForExit()
        $threw = $false
        try { Assert-ServingThisBuild -Port 8480 -Token 't' -Proc $dead -LogPath $log | Out-Null }
        catch { $threw = $_.Exception.Message -match 'EADDRINUSE' }
        $threw
    }

    # -----------------------------------------------------------------------
    # DoD row 16 — the RATCHET for the class that actually bit, rather than the
    # one that is easy to scan for.
    #
    # A check here pinned its subject to `Get-WebsiteBuilds | Select -First 1`.
    # That helper returns live `~/projects` sandboxes AND archived builds
    # interleaved, newest first — so the first item is the LIVE tree, which
    # every dispatch rewrites. It went red when a reboot-killed run left a
    # different tree there, on a file byte-identical to HEAD.
    #
    # WHY NOT PORT BlarAI's test_evidence_is_immutable INSTEAD, which row 16
    # names as the missing equivalent (#1385): I measured it. That gate matches
    # path LITERALS, and this repo's verifiers hold five such literals — all of
    # them DATA handed to pure functions (a journal string compared by
    # Get-BlockingRunOwner, a path only Split-Path'd for its name), none of them
    # subjects read from disk. Porting it would convict five times and catch
    # zero real instances, and a gate that cries wolf stops being read. The
    # offending line contained no literal at all; it reached the mutable root at
    # RUNTIME. A literal scanner is blind to that in any language.
    #
    # So this checks the shape that actually failed, and nothing wider.
    Check 'no verifier takes the FIRST build off the enumerator unfiltered (row 16 ratchet)' {
        $offenders = @()
        foreach ($f in Get-ChildItem -Path $PSScriptRoot -Filter '*.ps1' -File) {
            $n = 0
            foreach ($line in (Get-Content -LiteralPath $f.FullName)) {
                $n++
                # COMMENTS ARE SKIPPED, and that is not tidiness: the two lines in this very
                # file that DOCUMENT the fixed defect quote the forbidden expression verbatim.
                # A gate matching its own explanation is the vacuity shape this repo keeps
                # catching — it would have "found" two offenders and been wrong about both.
                if ($line -match '^\s*#') { continue }
                if ($line -match 'Get-WebsiteBuilds' -and
                    $line -notmatch 'Where-Object' -and
                    ($line -match '\|\s*Select(-Object)?\s+-First' -or $line -match '\)\s*\[0\]')) {
                    $offenders += "$($f.Name):$n"
                }
            }
        }
        if ($offenders.Count) { Write-Host "      offenders: $($offenders -join ', ')" -ForegroundColor Yellow }
        $offenders.Count -eq 0
    }

    Write-Host ''
    Write-Host "  $script:Pass passed, $script:Fail failed" -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
    Write-Host ''
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Fail -gt 0) { exit 1 }
