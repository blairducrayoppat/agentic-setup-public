# review-website.ps1 — show the operator a website the coder built, and capture his verdict (#1343).
#
#   .\review-website.ps1            # pick from every site on the box, newest first
#   .\review-website.ps1 -Latest    # skip the menu, open the newest
#
# Double-click `Review Website.cmd` instead of typing any of that.
#
# WHY THIS EXISTS. The operator asked for the outputs of the website batteries to be presented to
# him after each run so he can evaluate and validate, and give feedback — to close the loop. Until
# this script, the loop had no closing half: B9 built a complete multi-page site on two consecutive
# nights and nobody opened either one. The second was still sitting inside a dated battery-night
# archive directory, three levels below a state folder, reachable only by someone who knows git.
#
# HIS VERDICT IS THE INSTRUMENT. Every other grader in the pipeline measures whether an instrument
# ran honestly. None measures whether it was RIGHT — and #1342 showed the gap is not theoretical:
# a run graded GREEN while dropping a page he had asked for in his own words, and four gates passed
# it. His eyes on the actual site are the only ground truth that exists for that.
#
# AND AN INSTRUMENT NEEDS A SCALE (#1345). The first review anyone ever ran found three real
# defects and ended with "I am not really sure what I am supposed to expect, to be honest with
# you." That is a defect in the review instrument, not in the reviewer: handed no reference
# standard, he can only produce impressions, and impressions cannot grade the automated gates. So
# his goal is cut into its separate clauses — his own sentences, never rewritten — and handed back
# to him one at a time, with his marks kept against the run. "I could not tell" is a first-class
# answer throughout, because an instrument that forces a verdict manufactures one.
#
# SAFETY. Read-only over every source. The build is COPIED to a review workspace before it is
# served, so nothing here can mutate a sandbox the fleet may still be writing, or an archive that
# is evidence. The server binds loopback only, on a port chosen to avoid the assistant (5001) and
# Vikunja (3456).

[CmdletBinding()]
param(
    [switch]$Latest,
    # Pick a build by name without the menu. Matches the newest build with this name unless
    # -Archived is also given. This is how the battery night presents the site it just built.
    [string]$Name,
    # With -Name: prefer the ARCHIVED copy. After a night tears down, the archived copy is the
    # only one left, and it is the one worth reviewing.
    [switch]$Archived,
    [switch]$NoBrowser,
    [switch]$NoFeedback
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\review-website-lib.ps1"
. "$PSScriptRoot\review-website-report.ps1"

$ReviewRoot   = Join-Path $script:StateRoot 'operator-review'
$FeedbackRoot = Join-Path $script:StateRoot 'operator-reviews'

function Write-Head { param([string]$T) Write-Host ''; Write-Host $T -ForegroundColor Cyan }

# ---------------------------------------------------------------- discover
Write-Head 'Looking for websites the coder has built...'
$builds = @(Get-WebsiteBuilds)
if ($builds.Count -eq 0) {
    Write-Host ''
    Write-Host 'No website builds found yet.' -ForegroundColor Yellow
    Write-Host 'A battery night or a dispatch has to build one first; then run this again.'
    return
}

# ---------------------------------------------------------------- choose
if ($Name) {
    $matching = @($builds | Where-Object { $_.Name -eq $Name })
    if ($Archived) { $matching = @($matching | Where-Object { $_.Archived }) }
    if ($matching.Count -eq 0) {
        Write-Host ''
        Write-Host "No$(if ($Archived) { ' archived' }) build named '$Name' was found." -ForegroundColor Yellow
        Write-Host 'Run without -Name to see what is there.'
        return
    }
    $pick = $matching[0]
} elseif ($Latest -or $builds.Count -eq 1) {
    $pick = $builds[0]
} else {
    Write-Host ''
    Write-Host ('  {0,-3} {1,-34} {2,-26} {3,6} {4,8}' -f '#', 'SITE', 'WHERE', 'PAGES', 'COMMITS') -ForegroundColor DarkGray
    for ($i = 0; $i -lt $builds.Count; $i++) {
        $b = $builds[$i]
        $colour = if ($b.Archived) { 'DarkGray' } else { 'White' }
        Write-Host ('  {0,-3} {1,-34} {2,-26} {3,6} {4,8}' -f
            ($i + 1), $b.Name, $b.Source, $b.Pages, $b.Commits) -ForegroundColor $colour
    }
    Write-Host ''
    $answer = Read-Host 'Which one? (number, or Enter for the newest)'
    if ([string]::IsNullOrWhiteSpace($answer)) {
        $pick = $builds[0]
    } else {
        $n = 0
        if (-not [int]::TryParse($answer.Trim(), [ref]$n) -or $n -lt 1 -or $n -gt $builds.Count) {
            Write-Host "That is not one of the numbers above." -ForegroundColor Yellow
            return
        }
        $pick = $builds[$n - 1]
    }
}

Write-Head "Preparing $($pick.Name)..."

# ---------------------------------------------------------------- copy (never serve the original)
$stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
$workspace = Join-Path $ReviewRoot "$stamp-$($pick.Name)"
New-Item -ItemType Directory -Force -Path $workspace | Out-Null
# -Exclude on the .git directory: the review copy is for looking at, and copying a repo the fleet
# may still be writing risks a half-copied object store for no benefit.
Copy-Item -Path (Join-Path $pick.Path '*') -Destination $workspace -Recurse -Force -Exclude '.git'
Write-Host "  copied to $workspace" -ForegroundColor DarkGray

# ---------------------------------------------------------------- the run's own claims
$runDir = Find-RunRecordForRepo -RepoLeaf $pick.Name
$claims = Read-RunClaims -RunDir $runDir
if ($claims.Found) {
    Write-Host "  run record: $runDir" -ForegroundColor DarkGray
    if (@($claims.Skipped).Count -gt 0) {
        Write-Host ("  NOTE: {0} planned task(s) were SKIPPED - the report explains why." -f @($claims.Skipped).Count) -ForegroundColor Yellow
    }
} else {
    Write-Host '  no run record found - the report will say so rather than imply nothing was skipped.' -ForegroundColor DarkGray
}

# ---------------------------------------------------------------- what he was promised
# His goal, cut into the separate things he asked for. Without this he is reviewing against
# nothing: the first review anyone ever ran ended "I am not really sure what I am supposed to
# expect, to be honest with you", which is a defect in the instrument, not in the reviewer.
$clauses = Get-ReviewClauses -BuildName $pick.Name
$links   = Invoke-LinkLint -SitePath $pick.Path
$exam    = Get-ExamQuality -RunDir $runDir
$media   = Invoke-MediaLint -SitePath $pick.Path
if ($clauses.Found) {
    Write-Host ("  checklist: {0} things you asked for, from {1}" -f
                @($clauses.Clauses).Count, (Split-Path $clauses.Path -Leaf)) -ForegroundColor DarkGray
} else {
    Write-Host "  no checklist for this site - $($clauses.Reason)" -ForegroundColor Yellow
    Write-Host '  the report will say so rather than show an empty list.' -ForegroundColor DarkGray
}

# ---------------------------------------------------------------- serve
$pubDir = Join-Path $workspace 'public'
$pages = @()
if (Test-Path -LiteralPath $pubDir) {
    $pages = @(Get-ChildItem -LiteralPath $pubDir -Filter '*.html' -File |
               Sort-Object { $_.Name -ne 'index.html' }, Name |
               ForEach-Object { $_.Name })
}

$port = Get-FreeTcpPort

# An identity token planted in the served tree. After the server starts we fetch it back, and a
# mismatch means the thing answering on this port is NOT this build. That is not paranoia: while
# verifying this script a port-probe bug handed back an occupied port, the review server died with
# EADDRINUSE, and a PREVIOUS review's process answered every request — so the page presented as
# "tonight's site" was last night's. Without this check the report looked entirely successful.
$reviewToken = [guid]::NewGuid().ToString('N')
$tokenDir = if (Test-Path -LiteralPath (Join-Path $workspace 'public')) {
    Join-Path $workspace 'public'
} else { $workspace }
Set-Content -LiteralPath (Join-Path $tokenDir '__review_id.txt') -Value $reviewToken -Encoding ASCII

$serverLog = Join-Path $workspace '__review_server.log'
$serverJs = Join-Path $workspace 'src\server.js'
$server = $null
if (Test-Path -LiteralPath $serverJs) {
    $env:PORT = "$port"
    $server = Start-Process node -ArgumentList $serverJs -WorkingDirectory $workspace `
                                -NoNewWindow -PassThru `
                                -RedirectStandardError $serverLog
    Start-Sleep -Milliseconds 900
    Assert-ServingThisBuild -Port $port -Token $reviewToken -Proc $server -LogPath $serverLog | Out-Null
    Write-Host "  serving on http://127.0.0.1:$port (node, pid $($server.Id)) - identity verified" -ForegroundColor DarkGray
} else {
    # No node server in the build: serve the tree statically so the pages still open. A site whose
    # server did not get built is exactly the kind of thing he should SEE rather than be told about.
    $server = Start-Process python -ArgumentList '-m', 'http.server', "$port", '--bind', '127.0.0.1', `
                                   '--directory', $(if (Test-Path -LiteralPath $pubDir) { $pubDir } else { $workspace }) `
                                   -NoNewWindow -PassThru `
                                   -RedirectStandardError $serverLog
    Start-Sleep -Milliseconds 600
    Assert-ServingThisBuild -Port $port -Token $reviewToken -Proc $server -LogPath $serverLog | Out-Null
    Write-Host "  no node server in this build - serving the files statically on http://127.0.0.1:$port" -ForegroundColor Yellow
}

# ---------------------------------------------------------------- report
$reportPath = Join-Path $workspace 'REVIEW.html'
New-WebsiteReviewReport -Build $pick -Claims $claims -Port $port -OutPath $reportPath `
                        -Pages $pages -Clauses $clauses -Links $links -Exam $exam -Media $media | Out-Null

if (-not $NoBrowser) {
    Start-Process $reportPath
    Write-Host ''
    Write-Host '  Your browser is opening the review page.' -ForegroundColor Green
    Write-Host '  It has the site, and what the run claimed about it, side by side.'
}

# ---------------------------------------------------------------- his marks, clause by clause
# Structured first, free words second. The checklist gives him a reference standard to judge
# against; the free text catches everything the checklist never thought to ask.
$marks = @()
$stoppedEarly = $false
if (-not $NoFeedback -and $clauses.Found) {
    $total = @($clauses.Clauses).Count
    Write-Host ''
    Write-Host '--------------------------------------------------------------------' -ForegroundColor DarkGray
    Write-Host " The checklist: $total things you asked for, in your own words." -ForegroundColor Cyan
    Write-Host ' Open the site, look, and answer each one.'
    Write-Host ''
    Write-Host '    y  = yes, it does this'
    Write-Host '    n  = no, it does not'
    Write-Host '    ?  = I could not tell' -NoNewline
    Write-Host '   <- a real answer. Use it freely.' -ForegroundColor Green
    Write-Host ''
    Write-Host ' Press Enter on its own and I will record "I could not tell".'
    Write-Host ' Type  q  to stop. The rest are left "not looked at" - never guessed.'
    Write-Host '--------------------------------------------------------------------' -ForegroundColor DarkGray

    $i = 0
    foreach ($c in @($clauses.Clauses)) {
        $i++
        Write-Host ''
        Write-Host "  $i of $total" -ForegroundColor DarkGray
        Write-Host "    `"$($c.Text)`"" -ForegroundColor White
        if (@($c.Parts).Count -gt 0) {
            # One sentence, two obligations. The second is the one that fails quietly, so he is
            # asked about both halves before he answers - in his own words, never a rewrite.
            Write-Host '    Both of these have to be true:' -ForegroundColor DarkGray
            foreach ($p in @($c.Parts)) { Write-Host "      - $p" -ForegroundColor DarkGray }
        }

        $answer = ([string](Read-Host '  y / n / ?')).Trim().ToLowerInvariant()
        if ($answer -eq 'q') { $stoppedEarly = $true; break }

        # Anything that is not a clear yes or no is "could not tell". A blank Enter included:
        # not answering is the absence of evidence, which is exactly what that mark means. It is
        # never silently upgraded to a yes or a no.
        $mark = switch ($answer) {
            { $_ -in 'y', 'yes' } { $script:MarkMet }
            { $_ -in 'n', 'no'  } { $script:MarkNotMet }
            default               { $script:MarkCouldNotTell }
        }

        $words = ''
        if ($mark -eq $script:MarkNotMet) {
            $words = ([string](Read-Host '    what is wrong with it? (Enter to skip)')).Trim()
        } elseif ($mark -eq $script:MarkCouldNotTell) {
            $words = ([string](Read-Host '    what stopped you telling? (Enter to skip)')).Trim()
        }

        Write-Host "    recorded: $(ConvertTo-MarkWords $mark)" -ForegroundColor DarkGray
        $marks += [pscustomobject]@{ Id = $c.Id; Mark = $mark; Words = $words }
    }

    if ($stoppedEarly) {
        $left = $total - $marks.Count
        Write-Host ''
        Write-Host "  Stopped. $left left as 'not looked at' - they are recorded as unanswered," -ForegroundColor Yellow
        Write-Host "  not as passes. Run this again when you want to finish them." -ForegroundColor Yellow
    }
} elseif (-not $NoFeedback) {
    Write-Host ''
    Write-Host ' There is no checklist for this site, so I cannot walk you through what you' -ForegroundColor Yellow
    Write-Host ' asked for line by line. Judge it against the goal on the report page instead.' -ForegroundColor Yellow
}

# ---------------------------------------------------------------- capture his verdict
$saved = $null
if (-not $NoFeedback) {
    Write-Host ''
    Write-Host '--------------------------------------------------------------------' -ForegroundColor DarkGray
    Write-Host ' Now anything else - tell me what is wrong with it.' -ForegroundColor Cyan
    Write-Host ' Plain words are exactly right - "the nav should be on the left, the'
    Write-Host ' photos are too big" is more useful than anything technical.'
    Write-Host ' Type as many lines as you like. Press Enter on an empty line to finish.'
    Write-Host ' (Or just press Enter now if you would rather look first and come back.)'
    Write-Host '--------------------------------------------------------------------' -ForegroundColor DarkGray
    Write-Host ''

    $lines = @()
    while ($true) {
        $line = Read-Host ' >'
        if ([string]::IsNullOrWhiteSpace($line)) { break }
        $lines += $line
    }

    if ($lines.Count -gt 0 -or $marks.Count -gt 0) {
        New-Item -ItemType Directory -Force -Path $FeedbackRoot | Out-Null
        $base = Join-Path $FeedbackRoot "$stamp-$($pick.Name)"

        # Same folder, same names, one schema version wider. Building the record in the library
        # rather than here is what lets the regression lock exercise it without a keyboard.
        $built = New-OperatorReviewRecord -Build $pick -Claims $claims -Clauses $clauses `
                                          -Marks $marks -Feedback $lines -RunDir ([string]$runDir) `
                                          -Pages $pages -Stamp $stamp
        $built.Json | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath "$base.json" -Encoding UTF8
        $built.Markdown -join "`r`n" | Set-Content -LiteralPath "$base.md" -Encoding UTF8

        $saved = "$base.md"
        Write-Host ''
        Write-Host "  Saved. $saved" -ForegroundColor Green
        Write-Host '  This is now on disk against the run id, so the next iteration can read it.'
    } else {
        Write-Host ''
        Write-Host '  Nothing recorded - the site stays open. Run this again when you have looked.' -ForegroundColor DarkGray
    }
}

Write-Host ''
Write-Host "  The site is still running at http://127.0.0.1:$port" -ForegroundColor Cyan
Write-Host "  Close it with:  Stop-Process -Id $($server.Id)"
Write-Host ''

[pscustomobject]@{
    Build     = $pick.Name
    Port      = $port
    Report    = $reportPath
    Workspace = $workspace
    ServerPid = $server.Id
    Feedback  = $saved
}
