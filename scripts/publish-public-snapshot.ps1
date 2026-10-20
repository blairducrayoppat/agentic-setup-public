# publish-public-snapshot.ps1 — publish a HISTORY-FREE snapshot of each repo's main
# to its clean-name GitHub repo (the "public" remote).
#
# How it protects history:
#   - The snapshot commit is built from main's current TREE only (git commit-tree).
#     Its ancestry contains ONLY previous snapshot commits — never any working history.
#   - Local repos are NEVER modified: no branch moves, no checkouts, no resets. The
#     only local writes are new objects + one additive bookkeeping ref per repo
#     (refs/public-snapshots/main), which no normal git command ever touches.
#   - Publishing again chains the new snapshot onto the previous one, so every push
#     is a plain fast-forward. No force-push, ever.
#
# Leak-gate: before pushing, the snapshot tree is scanned for known-sensitive
# patterns. Any hit ABORTS that repo's publish.
#
# The clean-name repos stay PRIVATE until the go-public ceremony; flipping them to
# public is a manual GitHub settings step (or: gh repo edit <name> --visibility public).
#
# .publicignore (#1777): if <repo>/.publicignore exists in main's tree - read FROM THE TREE, never from a
# working copy - the published tree is main's tree MINUS every tracked path the list matches. The leak gate,
# the unchanged-tree comparison and the snapshot commit all use that filtered tree. The matching rules are
# written in the list's own header; the reference implementation is scripts/publicignore.py in the BlarAI
# repository, and the shared conformance table scripts/publicignore_cases.json (run here before a list is
# trusted, when the repository carries one) holds the two implementations together. FAIL-CLOSED: an empty
# list, a list that does not exclude itself, a line outside the rules, a failed conformance case, or a filtered
# tree that still holds a matched path (or lost an unmatched one) fails that repo's publish.
#
# Leak-gate views (#1777). The gate reads the tree it is about to publish under two views: (1) one `git grep -E`
# per pattern line of the private file (a single line, per-letter case classes, literal spaces); (2) a
# normalized view of every blob - lower-cased, whitespace collapsed (line breaks LF and CRLF, tabs, runs of
# spaces), read as UTF-8 and, when a NUL is near the start, as UTF-16 little and big endian, gzip unpacked up
# to three deep, and also with a backslash before punctuation dropped and with percent escapes decoded -
# searched for the '#phrase:' lines of the private file (comments to the grep view). It does not undo HTML
# entities or JSON escapes. NOT SEEN by either side: a soft hyphen, a zero-width character, an en dash or
# non-breaking hyphen, full-width letters, text in a deflated office document, Markdown emphasis or a quote
# marker inside a phrase, punctuation between the target name and its numbering, a word, "no." or a leading
# zero before the number, the target name spaced or with its organisation suffix, UTF-16 at an odd offset or
# after the first 4 KB, a plus sign for a space, double percent encoding, a backslash before a space, a Markdown
# backslash line break, a doubled backslash before punctuation, and a backslash form and a percent form combined
# in one phrase (each view is applied alone, never chained).
#
# Anchors and phrases (#1777, #1785). A source tree that carries a .publicignore must also carry scripts/publicignore_anchors.txt
# and scripts/publicignore_phrases.json; either one missing fails that repo's publish by name. With the anchor file, a .publicignore that
# excludes any path it names (a trailing '/' names everything beneath), or an anchor that names no tracked path,
# fails that repo's publish. With the phrase file, the repo fails unless every phrase
# assembled from it is among the private file's '#phrase:' needles. The BlarAI lock tests/security/test_public_snapshot_excludes_private_material.py
# reads the entity and JSON-escape forms in the index, so for those the lock is the control. A private file
# with no '#phrase:' line, a blob larger than the scan cap, or a view that cannot be read fails the gate.
#
# -DryRun: print the source head, the excluded paths, the filtered tree id and the leak-gate result, then stop
#   before update-ref and push. New tree objects go to a throwaway object directory, so a dry run writes nothing
#   into the repository. Exit 0 when every gate is clean, 1 otherwise. A dry run lists every hit file; a real
#   run lists the first three per pattern.
# -SourceRef <ref> (dry run only; refused otherwise): read that ref in place of main, to look at a branch
#   before it is merged. A real publish always reads main.
# -RepoPathOverride <path> (dry run only, needs -Only; refused otherwise): use that path for the one repo -Only names,
#   so the dry run can be pointed at a scratch repository.
# -PrivatePatternsPath <file> / -ViewScanBlobCapOverride <bytes> (dry run only; refused otherwise): read the private pattern
#   file from that path, and set the normalized view's blob-size cap, so the scratch test can reach the refusal for a file with
#   no '#phrase:' line and the cap's fail-closed report. A real publish reads the fixed file and the fixed cap.
# -SelfTest -CasesFile <path>: run the matcher against a conformance table and exit (0 pass, 1 fail). No repo
#   is touched and the private pattern file is not needed.
#
# Usage:  pwsh -File scripts\publish-public-snapshot.ps1 [-Only <repo-name>] [-DryRun [-SourceRef <ref>]]
#         pwsh -File scripts\publish-public-snapshot.ps1 -SelfTest -CasesFile <path-to-publicignore_cases.json>

param([string]$Only, [switch]$DryRun, [string]$SourceRef = 'main', [string]$RepoPathOverride, [switch]$SelfTest, [string]$CasesFile, [string]$PrivatePatternsPath, [int64]$ViewScanBlobCapOverride = 0)

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

if (($SourceRef -ne 'main' -or $RepoPathOverride -or $PrivatePatternsPath -or $ViewScanBlobCapOverride -ne 0) -and -not $DryRun) {
    Write-Host "FATAL: -SourceRef, -RepoPathOverride, -PrivatePatternsPath and -ViewScanBlobCapOverride are for -DryRun only; a real publish reads main of the listed repo (fail-closed)." -ForegroundColor Red
    exit 2
}
if ($RepoPathOverride -and -not $Only) {
    Write-Host "FATAL: -RepoPathOverride needs -Only <repo-name> to say which repo it replaces." -ForegroundColor Red
    exit 2
}

# --- .publicignore matcher (reference: scripts/publicignore.py in the BlarAI repository) ---
# One pattern per line; '#' lines and blanks ignored (space, tab, CR trimmed). Matched against the whole
# repo-relative forward-slash path, ASCII-case-insensitive. '*' = run of non-'/' chars; '**' = any run
# including '/' ('**/' also matches nothing); '?' = one non-'/' char; everything else literal. A pattern
# that matches a directory matches everything beneath it. Errors, never guesses: leading '!' or '/', a
# backslash, a '.' or '..' segment, any non-ASCII or control character.
function ConvertTo-PublicIgnoreFold([string]$Text) {
    return [regex]::Replace($Text, '[A-Z]', [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $m.Value.ToLowerInvariant() })
}

function ConvertTo-PublicIgnoreRegex([string]$Pattern) {
    $sb = [System.Text.StringBuilder]::new()
    $i = 0
    $n = $Pattern.Length
    while ($i -lt $n) {
        $c = $Pattern[$i]
        if ($c -eq '*') {
            if (($i + 2 -lt $n) -and $Pattern[$i + 1] -eq '*' -and $Pattern[$i + 2] -eq '/') { [void]$sb.Append('(?:.*/)?'); $i += 3 }
            elseif (($i + 1 -lt $n) -and $Pattern[$i + 1] -eq '*') { [void]$sb.Append('.*'); $i += 2 }
            else { [void]$sb.Append('[^/]*'); $i += 1 }
        } elseif ($c -eq '?') {
            [void]$sb.Append('[^/]'); $i += 1
        } else {
            [void]$sb.Append([regex]::Escape([string]$c)); $i += 1
        }
    }
    return '^' + $sb.ToString() + '(?:/.*)?\z'
}

function Read-PublicIgnore([string]$Text, [string]$Source) {
    $opts = [System.Text.RegularExpressions.RegexOptions]::Singleline -bor [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
    $trim = [char[]]@(' ', "`t", "`r")
    $rules = [System.Collections.Generic.List[object]]::new()
    $lineNo = 0
    foreach ($raw in $Text.Split("`n")) {
        $lineNo++
        $line = $raw.Trim($trim)
        if ($line.Length -eq 0 -or $line[0] -eq '#') { continue }
        $where = "${Source}:${lineNo}"
        if ($line[0] -eq '!' -or $line[0] -eq '/') { throw "${where}: a pattern may not start with '$($line[0])'" }
        if ($line.Contains('\')) { throw "${where}: a backslash is not allowed" }
        foreach ($ch in $line.ToCharArray()) {
            if ([int]$ch -lt 32 -or [int]$ch -gt 126) { throw "${where}: only printable ASCII is allowed" }
        }
        foreach ($seg in $line.Split('/')) {
            if ($seg -eq '.' -or $seg -eq '..') { throw "${where}: a '.' or '..' segment is not allowed" }
        }
        $body = if ($line.EndsWith('/')) { $line.Substring(0, $line.Length - 1) } else { $line }
        if ($body.Length -eq 0) { throw "${where}: empty pattern" }
        $rx = [regex]::new((ConvertTo-PublicIgnoreRegex (ConvertTo-PublicIgnoreFold $body)), $opts)
        $rules.Add([pscustomobject]@{ Line = $lineNo; Text = $line; Regex = $rx })
    }
    return , $rules.ToArray()
}

function Test-PublicIgnoreMatch([object[]]$Rules, [string]$Path) {
    if ($Path.Length -eq 0 -or $Path.StartsWith('/') -or $Path.Contains('\')) { throw "not a repo-relative forward-slash path: '$Path'" }
    foreach ($seg in $Path.Split('/')) {
        if ($seg -eq '.' -or $seg -eq '..') { throw "not a repo-relative forward-slash path: '$Path'" }
    }
    $folded = ConvertTo-PublicIgnoreFold $Path
    foreach ($rule in $Rules) { if ($rule.Regex.IsMatch($folded)) { return $true } }
    return $false
}

# Runs the shared conformance table through THIS matcher; returns one string per disagreement (empty = agree).
function Invoke-PublicIgnoreConformance([string]$CasesJson) {
    $cases = @((ConvertFrom-Json $CasesJson).cases)
    if ($cases.Count -lt 40) { return @("conformance table has $($cases.Count) cases; expected the full table") }
    $bad = [System.Collections.Generic.List[string]]::new()
    foreach ($case in $cases) {
        $text = (@($case.lines) -join "`n")
        $hasPath = $case.PSObject.Properties.Name -contains 'path'
        $got = $null
        try {
            $rules = Read-PublicIgnore $text 'case'
            $got = if ($hasPath) { Test-PublicIgnoreMatch $rules ([string]$case.path) } else { 'parsed' }
        } catch { $got = 'error' }
        $ok = if ($case.expect -is [bool]) { ($got -is [bool]) -and ($got -eq $case.expect) } else { $got -eq 'error' }
        if (-not $ok) { $bad.Add("lines=[$(@($case.lines) -join ' | ')] path=[$($case.path)] expected=[$($case.expect)] got=[$got]") }
    }
    return $bad.ToArray()
}

if ($SelfTest) {
    if (-not $CasesFile -or -not (Test-Path -LiteralPath $CasesFile)) { Write-Host "FATAL: -SelfTest needs -CasesFile <existing path>" -ForegroundColor Red; exit 2 }
    $bad = @(Invoke-PublicIgnoreConformance (Get-Content -LiteralPath $CasesFile -Raw -Encoding UTF8))
    if ($bad.Count -gt 0) { $bad | ForEach-Object { Write-Host "    DISAGREE: $_" -ForegroundColor Red }; Write-Host "SELF-TEST FAILED: $($bad.Count) case(s)" -ForegroundColor Red; exit 1 }
    Write-Host "SELF-TEST PASSED: the matcher agrees with every case in $CasesFile" -ForegroundColor Green
    exit 0
}

function Get-TreePaths([string]$Rev) {
    $raw = git -c core.quotepath=false ls-tree -r --name-only -z $Rev
    if ($LASTEXITCODE -ne 0) { throw "git ls-tree failed for $Rev" }
    if ($raw -is [array]) { throw "a tracked path in $Rev contains a line break" }
    return , @("$raw".Split([char]0, [System.StringSplitOptions]::RemoveEmptyEntries))
}

# main's tree minus $Excluded, built in a temporary index (the repo's own index is never touched).
function New-FilteredTree([string]$Rev, [string[]]$Excluded) {
    $tmpIndex = Join-Path ([System.IO.Path]::GetTempPath()) ('publicignore-index-' + [guid]::NewGuid().ToString('N'))
    $savedIndex = $env:GIT_INDEX_FILE
    try {
        $env:GIT_INDEX_FILE = $tmpIndex
        git read-tree $Rev | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "git read-tree $Rev failed" }
        for ($i = 0; $i -lt $Excluded.Count; $i += 40) {
            $batch = $Excluded[$i..([Math]::Min($i + 39, $Excluded.Count - 1))]
            git update-index --force-remove -- @batch | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "git update-index --force-remove failed" }
        }
        $written = git write-tree
        if ($LASTEXITCODE -ne 0) { throw "git write-tree failed" }
        return "$written".Trim()
    } finally {
        if ($null -eq $savedIndex) { Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue } else { $env:GIT_INDEX_FILE = $savedIndex }
        Remove-Item -LiteralPath $tmpIndex -Force -ErrorAction SilentlyContinue
    }
}

# --- normalized-view phrase scan (#1777); the views and their limits are in the header ---
$script:ViewScanBlobCap = if ($ViewScanBlobCapOverride -gt 0) { $ViewScanBlobCapOverride } else { 268435456 }

function Get-PhraseViewHits([byte[]]$Bytes, [string[]]$Needles, [int]$Depth) {
    $found = [System.Collections.Generic.HashSet[string]]::new()
    $problems = [System.Collections.Generic.List[string]]::new()
    $texts = [System.Collections.Generic.List[string]]::new()
    $texts.Add([System.Text.Encoding]::UTF8.GetString($Bytes))
    if ([Array]::IndexOf($Bytes, [byte]0, 0, [Math]::Min(4096, $Bytes.Length)) -ge 0) {
        $texts.Add([System.Text.Encoding]::Unicode.GetString($Bytes))
        $texts.Add([System.Text.Encoding]::BigEndianUnicode.GetString($Bytes))
    }
    foreach ($text in $texts) {
        # a needle found in the raw text is found again after collapsing: needles start and end on a non-space character
        # decode first, lower-case after: an encoded capital letter must fold like any other
        $variants = [System.Collections.Generic.List[string]]::new()
        $variants.Add($text)
        if ($text.Contains('\')) { $variants.Add([regex]::Replace($text, '\\([\x21-\x2f\x3a-\x40\x5b-\x60\x7b-\x7e])', '$1')) }
        if ($text.Contains('%')) { $variants.Add([System.Uri]::UnescapeDataString($text)) }
        foreach ($variant in $variants) {
            $collapsed = [regex]::Replace($variant.ToLowerInvariant(), '\s+', ' ')
            foreach ($needle in $Needles) { if ($collapsed.Contains($needle)) { [void]$found.Add($needle) } }
        }
    }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0x1f -and $Bytes[1] -eq 0x8b) {
        if ($Depth -ge 3) {
            $problems.Add('gzip nested deeper than three levels')
        } else {
            try {
                $gz = [System.IO.Compression.GZipStream]::new([System.IO.MemoryStream]::new($Bytes), [System.IO.Compression.CompressionMode]::Decompress)
                $sink = [System.IO.MemoryStream]::new()
                $gz.CopyTo($sink)
                # GZipStream ends silently on truncated input: the trailer's length field must match what came out
                if ($Bytes.Length -lt 18) { throw 'shorter than a gzip header and trailer' }
                if ([BitConverter]::ToUInt32($Bytes, $Bytes.Length - 4) -ne [uint32]($sink.Length -band 0xFFFFFFFF)) {
                    throw 'the trailer length does not match the content (truncated, or more than one member)'
                }
                $inner = Get-PhraseViewHits $sink.ToArray() $Needles ($Depth + 1)
                foreach ($n in $inner.Found) { [void]$found.Add($n) }
                foreach ($q in $inner.Problems) { $problems.Add($q) }
            } catch { $problems.Add("gzip cannot be decompressed ($($_.Exception.Message))") }
        }
    }
    return @{ Found = $found; Problems = $problems }
}

# {path -> [needle or problem, ...]} for the blobs of $Tree that carry a needle or cannot be read; one `git cat-file --batch`.
function Find-NormalizedPhrases([string]$Tree, [string[]]$Needles) {
    $result = [ordered]@{}
    $listing = git -c core.quotepath=false ls-tree -r -z $Tree
    if ($LASTEXITCODE -ne 0) { throw "git ls-tree failed for $Tree" }
    if ($listing -is [array]) { throw "a tracked path in $Tree contains a line break" }
    $records = "$listing".Split([char]0, [System.StringSplitOptions]::RemoveEmptyEntries)
    $psi = [System.Diagnostics.ProcessStartInfo]::new('git')
    foreach ($a in @('cat-file', '--batch')) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.UseShellExecute = $false
    $psi.WorkingDirectory = (Get-Location).ProviderPath
    $proc = [System.Diagnostics.Process]::Start($psi)
    $reader = [System.IO.BufferedStream]::new($proc.StandardOutput.BaseStream, 1048576)
    $writer = $proc.StandardInput.BaseStream
    try {
        foreach ($rec in $records) {
            $tab = $rec.IndexOf("`t")
            $meta = $rec.Substring(0, $tab).Split(' ')
            $path = $rec.Substring($tab + 1)
            if ($meta[0] -eq '160000') { continue }
            $request = [System.Text.Encoding]::ASCII.GetBytes($meta[2] + "`n")
            $writer.Write($request, 0, $request.Length)
            $writer.Flush()
            $header = [System.Text.StringBuilder]::new()
            while ($true) {
                $b = $reader.ReadByte()
                if ($b -lt 0) { throw "git cat-file ended early at $path" }
                if ($b -eq 10) { break }
                [void]$header.Append([char]$b)
            }
            $parts = $header.ToString().Split(' ')
            if ($parts.Count -ne 3 -or $parts[1] -ne 'blob') { throw "git cat-file gave '$header' for $path" }
            $size = [int64]$parts[2]
            if ($size -gt $script:ViewScanBlobCap) {
                $left = $size
                $junk = [byte[]]::new(1048576)
                while ($left -gt 0) {
                    $n = $reader.Read($junk, 0, [int][Math]::Min($left, $junk.Length))
                    if ($n -le 0) { throw "git cat-file ended early at $path" }
                    $left -= $n
                }
                [void]$reader.ReadByte()
                $result[$path] = @("blob of $size bytes is larger than the scan cap and was not read")
                continue
            }
            $buffer = [byte[]]::new([int]$size)
            $got = 0
            while ($got -lt $size) {
                $n = $reader.Read($buffer, $got, [int]($size - $got))
                if ($n -le 0) { throw "git cat-file ended early at $path" }
                $got += $n
            }
            [void]$reader.ReadByte()
            $view = Get-PhraseViewHits $buffer $Needles 0
            if ($view.Found.Count -gt 0 -or $view.Problems.Count -gt 0) { $result[$path] = @($view.Found) + @($view.Problems) }
        }
    } finally {
        try { $writer.Close() } catch { }
        [void]$proc.WaitForExit(30000)
        $proc.Dispose()
    }
    return $result
}

$repos = @(
    @{ Path = 'C:/Users/mrbla/blarai';                       Name = 'blarai' },
    @{ Path = 'C:/Users/mrbla/agentic-setup';                Name = 'agentic-setup' },
    @{ Path = 'C:/Users/mrbla/devplatform';                  Name = 'devplatform' },
    @{ Path = 'C:/Users/mrbla/jobhunt';                      Name = 'jobhunt' },
    @{ Path = 'C:/Users/mrbla/projects/jobhunt-eligibility'; Name = 'jobhunt-eligibility' }
)

# --- leak-gate patterns ---
# Generic token shapes live inline (harmless to publish). Topic-sensitive
# patterns live in a PRIVATE file outside every repo — the published tree must
# never contain the terms it is scanned for. Fail-closed if the file is absent.
$fixedSecrets = @()
$vp = [Environment]::GetEnvironmentVariable('VIKUNJA_PASS', 'User')
if ($vp -and $vp -ne '${VIKUNJA_PASS}') { $fixedSecrets += $vp }
$builtinRegexes = @(
    'sk-ant-[A-Za-z0-9_\-]{10,}',
    'ghp_[A-Za-z0-9]{20,}', 'github_pat_[A-Za-z0-9_]{20,}', 'hf_[A-Za-z0-9]{20,}'
)
$privatePatterns = if ($PrivatePatternsPath) { $PrivatePatternsPath } else { 'C:/Users/mrbla/.blarai-fleet/leakgate-patterns.txt' }
if (-not (Test-Path $privatePatterns)) {
    Write-Host "FATAL: private leak-gate pattern file missing: $privatePatterns" -ForegroundColor Red
    Write-Host "Refusing to publish anything without the full gate (fail-closed)." -ForegroundColor Red
    exit 2
}
$topicRegexes = @(Get-Content $privatePatterns | Where-Object { $_ -and $_ -notmatch '^\s*#' })
# '#phrase: <text>' lines are comments to the grep view and the needles of the normalized view (see the header)
$phraseNeedles = @(Get-Content $privatePatterns | ForEach-Object {
    if ($_ -match '^\s*#phrase:\s*(\S.*?)\s*$') { [regex]::Replace($Matches[1].ToLowerInvariant(), '\s+', ' ') }
})
if ($phraseNeedles.Count -eq 0) {
    Write-Host "FATAL: the private pattern file has no '#phrase:' line; the normalized-view scan would search for nothing (fail-closed)." -ForegroundColor Red
    exit 2
}

# --- hash-pinned allowlist (Vikunja #1104) ---
# Clears ONE blob at ONE path in ONE repo from the PRIVATE-TOPIC regexes only -
# never from $fixedSecrets or $builtinRegexes, which stay unconditional (a
# real secret shape is never "reviewed clean", only rotated or removed). Any
# edit to a cleared file changes its blob hash and re-trips the gate; clearance
# never survives a content change. Two provenances:
#   - P5-verdict.md / promptfoo_injection_corpus.json: reviewed 2026-07-24,
#     generic-word matches confirmed not to reference any real private
#     identifier (Vikunja #1104 comment 2541).
#   - nist_ai_rmf_playbook.json: reviewed 2026-08-09, same generic-word class
#     (a standard AI-risk-framework mention of ordinary human-factors terms).
#   - B4-eu-law-liability-privacy-of-the-record.md: reviewed 2026-10-09 (Vikunja
#     #1716), one hit, a two-word health term inside a quotation of the EU
#     product-liability directive's definition of compensable damage; the
#     generic-word class, no private identifier. (The term itself is not
#     repeated here: this file is in the published tree and the gate scans it.)
#   - 2026-10-09 (#1716): the DECISION_REGISTER.md and 2026-07.md blobs were
#     re-pinned. The 2026-08-08 pins had lapsed through ordinary edits to both
#     files; the flagged lines are unchanged in kind (the DEC-12 row; the one
#     journal entry that explains the 07-24 false positives), re-checked by
#     grep on 2026-10-09 and re-cleared by the LA.
#   - 2026-10-15 (#1777, LA Decision A, #1777 comment 4192): DECISION_REGISTER.md
#     re-pinned at snapshot time to BlarAI main 3d484ff6's blob. The pin had
#     lapsed through the DEC-20/21 rows (#1765) and the DEC-20 rewording (#1777);
#     the only flagged line, the DEC-12 row, was compared byte-for-byte
#     against the cleared blob 36af4ee9 and is identical.
#   - 2026-10-15 (#1741, LA Decision A): re-pinned again to BlarAI main 13456085's
#     blob after the DEC-22 licence row; the DEC-12 row compared byte-for-byte
#     against the cleared blob 36af4ee9 and is identical.
#   - docs/DECISION_REGISTER.md / docs/archive/journal/2026-07.md: the LA
#     reviewed the exact flagged references in these two files verbatim and
#     cleared them for publication (see DEC-12 in docs/DECISION_REGISTER.md,
#     Vikunja #1104 comment 2959, 2026-08-08). This clears only what was
#     actually reviewed there - NOT a blanket future clearance, and the
#     underlying guard pattern stays fully live for anything not yet
#     reviewed, including the other private topics this same pattern file
#     guards.
$allowlist = @(
    @{ Repo = 'blarai'; Path = 'docs/research/publication-program/novelty-survey/P5-verdict.md'; Blob = 'b2ca0ff0128b9874e4026246e1ad051ca17c8c8a' }
    @{ Repo = 'blarai'; Path = 'evals/fixtures/injection_corpus/promptfoo_injection_corpus.json'; Blob = 'a2bd5de1ecb44f10c08a699e82d48410fd2da72c' }
    @{ Repo = 'blarai'; Path = 'docs/governance/nist_ai_rmf_playbook.json'; Blob = '3804556942b25c0034c86465b40ebd894f03f017' }
    @{ Repo = 'blarai'; Path = 'docs/DECISION_REGISTER.md'; Blob = '9d82c46436e504fe526609ca4eb50c7015288497' }
    @{ Repo = 'blarai'; Path = 'docs/archive/journal/2026-07.md'; Blob = '8824096b60769d1fa4fa9657bdf89a1f559c4c4a' }
    @{ Repo = 'blarai'; Path = 'docs/research/runtime-action-governance-product-feasibility-2026-09-17-appendices/B4-eu-law-liability-privacy-of-the-record.md'; Blob = '13393c0d53b47444f7955e5bd09e43b5e63a2d2b' }
)

$fail = 0
# paths that must survive the filter whenever the source tree has them: a list that removes one is a broken list
$anchorPaths = @('README.md', 'LICENSE.md')
$listMax = if ($DryRun) { 100000 } else { 3 }
foreach ($r in $repos) {
    if ($Only -and $r.Name -ne $Only) { continue }
    Push-Location $(if ($RepoPathOverride) { $RepoPathOverride } else { $r.Path })
    $savedObjDir = $env:GIT_OBJECT_DIRECTORY
    $savedAltDirs = $env:GIT_ALTERNATE_OBJECT_DIRECTORIES
    $dryObjDir = $null
    try {
        $tree = "$(git rev-parse "${SourceRef}^{tree}")".Trim()
        $headFull = "$(git rev-parse $SourceRef)".Trim()
        if ($tree -notmatch '^[0-9a-f]{40}$' -or $headFull -notmatch '^[0-9a-f]{40}$') {
            Write-Host "[$($r.Name)] cannot resolve '$SourceRef' to a commit and a tree - NOT published" -ForegroundColor Red
            $fail++
            continue
        }
        $srcHead = $headFull.Substring(0, 8)
        $mainTree = $tree

        if ($DryRun) {
            # new objects (the filtered tree) go to a throwaway directory; the repository's own store is only read
            $realObjs = (Resolve-Path (git rev-parse --git-path objects)).ProviderPath
            $dryObjDir = Join-Path ([System.IO.Path]::GetTempPath()) ('publicignore-objects-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $dryObjDir | Out-Null
            $env:GIT_OBJECT_DIRECTORY = $dryObjDir
            $env:GIT_ALTERNATE_OBJECT_DIRECTORIES = $realObjs
        }

        # --- .publicignore: published tree = source tree minus the matched paths (read from the tree) ---
        $hasList = $false
        $ruleCount = 0
        $excluded = @()
        # absence (empty listing) is the only thing that means "no list"; a git error is a failure, never "no list"
        $listEntry = "$(git ls-tree $SourceRef -- .publicignore)"
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[$($r.Name)] cannot look up .publicignore in $SourceRef - NOT published" -ForegroundColor Red
            $fail++
            continue
        }
        if ($listEntry.Trim().Length -gt 0) {
            $hasList = $true
            try {
                if ($listEntry -notmatch '^100(644|755) blob ') { throw ".publicignore is not a regular file in $SourceRef ($($listEntry.Trim()))" }
                $listText = (git show "${SourceRef}:.publicignore") -join "`n"
                if ($LASTEXITCODE -ne 0) { throw "git show ${SourceRef}:.publicignore failed" }
                $rules = Read-PublicIgnore $listText "$($r.Name):.publicignore"
                $ruleCount = $rules.Count
                if ($ruleCount -eq 0) { throw ".publicignore has no pattern lines (an empty list is refused)" }
                if (-not (Test-PublicIgnoreMatch $rules '.publicignore')) { throw ".publicignore does not exclude itself (the list must hold back its own file)" }

                $casesEntry = "$(git ls-tree $SourceRef -- scripts/publicignore_cases.json)"
                if ($LASTEXITCODE -ne 0) { throw "cannot look up scripts/publicignore_cases.json in $SourceRef" }
                if ($casesEntry.Trim().Length -gt 0) {
                    if ($casesEntry -notmatch '^100(644|755) blob ') { throw "scripts/publicignore_cases.json is not a regular file in $SourceRef" }
                    $disagree = @(Invoke-PublicIgnoreConformance ((git show "${SourceRef}:scripts/publicignore_cases.json") -join "`n"))
                    if ($disagree.Count -gt 0) { throw "this publisher's matcher disagrees with the repository's conformance table on $($disagree.Count) case(s): $($disagree[0])" }
                } else {
                    Write-Host "[$($r.Name)] note: no scripts/publicignore_cases.json in this tree; the matcher was not cross-checked" -ForegroundColor Yellow
                }

                $phraseEntry = "$(git ls-tree $SourceRef -- scripts/publicignore_phrases.json)"
                if ($LASTEXITCODE -ne 0) { throw "cannot look up scripts/publicignore_phrases.json in $SourceRef" }
                if ($phraseEntry.Trim().Length -gt 0) {
                    if ($phraseEntry -notmatch '^100(644|755) blob ') { throw "scripts/publicignore_phrases.json is not a regular file in $SourceRef" }
                    $pd = ((git show "${SourceRef}:scripts/publicignore_phrases.json") -join "`n") | ConvertFrom-Json
                    if ($LASTEXITCODE -ne 0) { throw "git show ${SourceRef}:scripts/publicignore_phrases.json failed" }
                    $assembled = [System.Collections.Generic.List[string]]::new()
                    foreach ($parts in $pd.phrases) { $assembled.Add(-join $parts) }
                    $tgt = -join $pd.target
                    $stem = -join $pd.numbering.stem
                    foreach ($b in $pd.numbering.before) { foreach ($a in $pd.numbering.after) { $assembled.Add("$tgt$b$stem$a$($pd.numbering.number)") } }
                    $absent = @($assembled | ForEach-Object { [regex]::Replace($_.ToLowerInvariant(), '\s+', ' ').Trim() } | Where-Object { $phraseNeedles -cnotcontains $_ })
                    if ($assembled.Count -eq 0) { throw "scripts/publicignore_phrases.json assembles no phrase" }
                    if ($absent.Count -gt 0) { throw "the private pattern file lacks $($absent.Count) of $($assembled.Count) phrases of scripts/publicignore_phrases.json (compare its '#phrase:' lines)" }
                } else {
                    throw "this tree carries a .publicignore but no scripts/publicignore_phrases.json; a repository with a list must carry the phrase file, and the phrase check is never skipped"
                }

                $before = Get-TreePaths $SourceRef
                $excluded = @($before | Where-Object { Test-PublicIgnoreMatch $rules $_ })
                $anchorEntry = "$(git ls-tree $SourceRef -- scripts/publicignore_anchors.txt)"
                if ($LASTEXITCODE -ne 0) { throw "cannot look up scripts/publicignore_anchors.txt in $SourceRef" }
                if ($anchorEntry.Trim().Length -gt 0) {
                    if ($anchorEntry -notmatch '^100(644|755) blob ') { throw "scripts/publicignore_anchors.txt is not a regular file in $SourceRef" }
                    $anchorLines = @((git show "${SourceRef}:scripts/publicignore_anchors.txt") | ForEach-Object { "$_".Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
                    if ($anchorLines.Count -eq 0) { throw "scripts/publicignore_anchors.txt names no anchor" }
                    foreach ($anchor in $anchorLines) {
                        $anchored = @($before | Where-Object { if ($anchor.EndsWith('/')) { $_.StartsWith($anchor, [System.StringComparison]::Ordinal) } else { $_ -ceq $anchor } })
                        if ($anchored.Count -eq 0) { throw "anchor '$anchor' names no tracked path" }
                        $removed = @($anchored | Where-Object { $excluded -ccontains $_ })
                        if ($removed.Count -gt 0) { throw ".publicignore excludes $($removed.Count) anchored path(s), first: $($removed[0]) (anchor '$anchor')" }
                    }
                } else {
                    throw "this tree carries a .publicignore but no scripts/publicignore_anchors.txt; a repository with a list must carry the anchor file, and the anchor check is never skipped"
                }
                if ($ruleCount -gt 0 -and $excluded.Count -eq 0) { throw ".publicignore has $ruleCount pattern(s) and matches no tracked path (a list that matches nothing is a broken list)" }
                if ($excluded.Count -gt 0) {
                    $tree = New-FilteredTree $SourceRef $excluded
                    $after = Get-TreePaths $tree
                    $stillMatched = @($after | Where-Object { Test-PublicIgnoreMatch $rules $_ })
                    if ($stillMatched.Count -gt 0) { throw "the filtered tree still holds $($stillMatched.Count) matched path(s), first: $($stillMatched[0])" }
                    if ($after.Count -ne ($before.Count - $excluded.Count)) { throw "the filtered tree holds $($after.Count) paths; expected $($before.Count - $excluded.Count)" }
                    if ($after.Count -eq 0) { throw "the filtered tree is empty (the list matches every tracked path)" }
                    $lostAnchors = @($anchorPaths | Where-Object { ($before -ccontains $_) -and -not ($after -ccontains $_) })
                    if ($lostAnchors.Count -gt 0) { throw "the filtered tree lost anchor path(s) that must always publish: $($lostAnchors -join ', ')" }
                }
            } catch {
                Write-Host "[$($r.Name)] .publicignore FAILED - NOT published: $($_.Exception.Message)" -ForegroundColor Red
                $fail++
                continue
            }
        }

        # --- leak-gate: scan the exact tree being published ---
        $hits = @()
        foreach ($s in $fixedSecrets)  { $h = git grep -l -F $s $tree 2>$null; if ($h) { $hits += "secret-value -> $($h -join ',')" } }
        foreach ($rx in $builtinRegexes) { $h = git grep -l -E $rx $tree 2>$null; if ($h) { $hits += "$rx -> $(($h | Select-Object -First $listMax) -join ',')" } }
        foreach ($rx in $topicRegexes) {
            $matches = git grep -l -E $rx $tree 2>$null
            if (-not $matches) { continue }
            $realHits = @()
            foreach ($m in $matches) {
                $path = $m.Substring($m.IndexOf(':') + 1)
                $blob = (git rev-parse "${tree}:${path}").Trim()
                $cleared = $allowlist | Where-Object { $_.Repo -eq $r.Name -and $_.Path -eq $path -and $_.Blob -eq $blob }
                if (-not $cleared) { $realHits += $path }
            }
            if ($realHits) { $hits += "$rx -> $(($realHits | Select-Object -First $listMax) -join ',')" }
        }
        # normalized view: the '#phrase:' needles over every blob of the tree being published (fail-closed on any error)
        try {
            $viewHits = Find-NormalizedPhrases $tree $phraseNeedles
            $byItem = [ordered]@{}
            foreach ($viewPath in $viewHits.Keys) {
                foreach ($item in $viewHits[$viewPath]) {
                    if (-not $byItem.Contains($item)) { $byItem[$item] = [System.Collections.Generic.List[string]]::new() }
                    $byItem[$item].Add($viewPath)
                }
            }
            foreach ($item in $byItem.Keys) { $hits += "phrase view [$item] -> $((@($byItem[$item]) | Select-Object -First $listMax) -join ',')" }
        } catch { $hits += "phrase view scan FAILED (fail-closed): $($_.Exception.Message)" }
        if ($DryRun) {
            $prevForInfo = (git rev-parse --verify -q refs/public-snapshots/main 2>$null)
            Write-Host "[$($r.Name)] DRY RUN - source $SourceRef @ $srcHead"
            if ($hasList) {
                Write-Host "    .publicignore: $ruleCount pattern(s); excluded $($excluded.Count) tracked path(s):"
                $excluded | ForEach-Object { Write-Host "        $_" }
            } else {
                Write-Host "    no .publicignore in this tree: nothing excluded"
            }
            Write-Host "    source tree:   $mainTree"
            Write-Host "    filtered tree: $tree"
            if ($prevForInfo) {
                $prevTreeInfo = (git rev-parse "$($prevForInfo.Trim())^{tree}").Trim()
                Write-Host "    previous snapshot tree: $prevTreeInfo ($(if ($prevTreeInfo -eq $tree) { 'same as the filtered tree: a real run would skip' } else { 'differs: a real run would publish' }))"
            }
            if ($hits) {
                Write-Host "    leak gate: FAILED" -ForegroundColor Red
                $hits | ForEach-Object { Write-Host "        $_" -ForegroundColor Red }
                $fail++
            } else {
                Write-Host "    leak gate: clean" -ForegroundColor Green
            }
            Write-Host "    DRY RUN: nothing written, nothing pushed"
            continue
        }
        if ($hits) {
            Write-Host "[$($r.Name)] LEAK-GATE FAILED — NOT published:" -ForegroundColor Red
            $hits | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
            $fail++
            continue
        }

        # --- build snapshot commit (chained onto previous snapshot if any) ---
        $prev = (git rev-parse --verify -q refs/public-snapshots/main 2>$null)
        $msg = "Public snapshot $(Get-Date -Format yyyy-MM-dd) (from $srcHead)"
        if ($prev) {
            $prevTree = (git rev-parse "$($prev.Trim())^{tree}").Trim()
            if ($prevTree -eq $tree) { Write-Host "[$($r.Name)] tree unchanged since last snapshot — skipping"; continue }
            $commit = (git commit-tree $tree -p $prev.Trim() -m $msg).Trim()
        } else {
            $commit = (git commit-tree $tree -m $msg).Trim()
        }
        if ($commit -notmatch '^[0-9a-f]{40}$') { Write-Host "[$($r.Name)] snapshot commit failed" -ForegroundColor Red; $fail++; continue }

        git update-ref refs/public-snapshots/main $commit
        git push public "${commit}:refs/heads/main" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Host "[$($r.Name)] push failed ($LASTEXITCODE)" -ForegroundColor Red; $fail++; continue }
        $heldBack = if ($excluded.Count -gt 0) { "; $($excluded.Count) path(s) held back by .publicignore" } else { '' }
        Write-Host "[$($r.Name)] published snapshot $($commit.Substring(0,8)) (tree of main @ $srcHead$heldBack)" -ForegroundColor Green
    } finally {
        if ($null -eq $savedObjDir) { Remove-Item Env:GIT_OBJECT_DIRECTORY -ErrorAction SilentlyContinue } else { $env:GIT_OBJECT_DIRECTORY = $savedObjDir }
        if ($null -eq $savedAltDirs) { Remove-Item Env:GIT_ALTERNATE_OBJECT_DIRECTORIES -ErrorAction SilentlyContinue } else { $env:GIT_ALTERNATE_OBJECT_DIRECTORIES = $savedAltDirs }
        if ($dryObjDir) { Remove-Item -LiteralPath $dryObjDir -Recurse -Force -ErrorAction SilentlyContinue }
        Pop-Location
    }
}
if ($fail -gt 0) { exit 1 }
