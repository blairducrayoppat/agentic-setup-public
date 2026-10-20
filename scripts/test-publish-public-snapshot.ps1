# test-publish-public-snapshot.ps1 - exercises publish-public-snapshot.ps1 -DryRun and its .publicignore filter
# against SCRATCH repositories (#1777). Nothing real is read or written: every case builds its own repository
# under the temp folder, points the publisher at it with -RepoPathOverride, and reads what the publisher prints.
# The publisher is never run without -DryRun here.
#
# Usage:  pwsh -NoProfile -File scripts\test-publish-public-snapshot.ps1 -CasesFile <publicignore_cases.json> -PhrasesFile <publicignore_phrases.json>
# Both files are the BlarAI repository's shared fixtures and are required: the conformance table for the matcher, and the phrase
# parts for the leak-gate coverage case (every phrase the BlarAI lock carries must be caught by the private pattern file, in its
# plain form by the grep view and in four altered forms by the normalized view). Exit 0 = every case passed, 1 = a case failed.
# Every phrase is assembled from parts at run time, so this file carries none of the private gate's patterns.

param([Parameter(Mandatory)][string]$CasesFile, [Parameter(Mandatory)][string]$PhrasesFile, [string]$Publisher = (Join-Path $PSScriptRoot 'publish-public-snapshot.ps1'))

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
if (-not (Test-Path -LiteralPath $CasesFile)) { Write-Host "FATAL: $CasesFile not found" -ForegroundColor Red; exit 2 }
if (-not (Test-Path -LiteralPath $PhrasesFile)) { Write-Host "FATAL: $PhrasesFile not found" -ForegroundColor Red; exit 2 }
if (-not (Test-Path -LiteralPath $Publisher)) { Write-Host "FATAL: $Publisher not found" -ForegroundColor Red; exit 2 }
$goodCases = Get-Content -LiteralPath $CasesFile -Raw -Encoding UTF8
$phraseData = Get-Content -LiteralPath $PhrasesFile -Raw -Encoding UTF8 | ConvertFrom-Json
$phraseTarget = -join $phraseData.target
$plainPhrases = @($phraseData.phrases | ForEach-Object { -join $_ })
$phraseStem = -join $phraseData.numbering.stem
$numberedPhrases = @()
foreach ($before in $phraseData.numbering.before) {
    foreach ($after in $phraseData.numbering.after) { $numberedPhrases += "$phraseTarget$before$phraseStem$after$($phraseData.numbering.number)" }
}
$allPhrases = @($plainPhrases + $numberedPhrases)
$plant = $plainPhrases[0]
$root = Join-Path ([System.IO.Path]::GetTempPath()) ('publisher-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0

function Check([bool]$Condition, [string]$Name) {
    if ($Condition) { $script:passed++; Write-Host "  ok   $Name" } else { $script:failures.Add($Name); Write-Host "  FAIL $Name" -ForegroundColor Red }
}

function New-Scratch([string]$Name, [hashtable]$Files) {
    $dir = Join-Path $root $Name
    New-Item -ItemType Directory -Path $dir | Out-Null
    git -C $dir init -q -b main
    git -C $dir config core.autocrlf false
    git -C $dir config user.name scratch
    git -C $dir config user.email scratch@example.invalid
    foreach ($rel in $Files.Keys) {
        $path = Join-Path $dir $rel
        New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force | Out-Null
        [System.IO.File]::WriteAllText($path, [string]$Files[$rel], [System.Text.UTF8Encoding]::new($false))
    }
    git -C $dir add .
    git -C $dir commit -q -m scratch
    return $dir
}

function With([hashtable]$Files, [hashtable]$Over) {
    $copy = $Files.Clone()
    foreach ($k in $Over.Keys) { $copy[$k] = $Over[$k] }
    return $copy
}

function Invoke-Publisher([string]$Dir, [string[]]$Extra = @()) {
    $out = & pwsh -NoProfile -File $Publisher -Only blarai -DryRun -RepoPathOverride $Dir @Extra 2>&1 | Out-String
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}

# A copy of the publisher whose repository table lists one scratch repository named blarai: a probe that regressed into a real
# run would act on the scratch repository, never on a real one.
function New-TablePublisher([string]$RepoDir) {
    $text = Get-Content -LiteralPath $Publisher -Raw -Encoding UTF8
    $table = "`$repos = @(`n    @{ Path = '" + $RepoDir.Replace("'", "''") + "'; Name = 'blarai' }`n)"
    $new = [regex]::Replace($text, '(?s)\$repos = @\(.*?\r?\n\)', [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $table }, 1)
    if ($new -eq $text) { throw 'the publisher has no repository table to replace' }
    $path = Join-Path $root ('pub-table-' + [guid]::NewGuid().ToString('N') + '.ps1')
    [System.IO.File]::WriteAllText($path, $new, [System.Text.UTF8Encoding]::new($false))
    return $path
}

function Get-ExpectedTree([string]$Dir, [string[]]$Remove) {
    $idx = Join-Path $root ('expected-' + [guid]::NewGuid().ToString('N'))
    $env:GIT_INDEX_FILE = $idx
    try {
        git -C $Dir read-tree main
        foreach ($p in $Remove) { git -C $Dir rm --cached -q -f -- $p }
        return ([string](git -C $Dir write-tree)).Trim()
    } finally { Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue }
}

function Get-FilteredTreeId([string]$Out) {
    if ($Out -match 'filtered tree:\s+([0-9a-f]{40})') { return $Matches[1] }
    return ''
}

$phrasesText = Get-Content -LiteralPath $PhrasesFile -Raw -Encoding UTF8
# A tree that carries a list must carry the anchor file and the phrase file (#1785); $req is the smallest pair that passes.
$req = @{ 'scripts/publicignore_anchors.txt' = "ANCHOR.md`n"; 'ANCHOR.md' = "anchor`n"; 'scripts/publicignore_phrases.json' = $phrasesText }
$list = "# scratch list`n.publicignore`ndrop/`n**/*Draft*`ndocs/*/*.md`n"
$base = @{
    'keep/a.md' = "plain`n"; 'drop/b.md' = "x`n"; 'notes/My Draft v2.md' = "x`n"; 'docs/Mixed Case/sub note.md' = "x`n"
    'docs/Mixed Case/deeper/stays.md' = "x`n"; ([string]'docs/caf' + [char]0xE9 + '/' + [char]0xE9 + ' note.md') = "x`n"
    'scripts/publicignore_cases.json' = $goodCases; '.publicignore' = $list
}
$base = With $base $req

try {
    Write-Host "case 1: the filter drops exactly the matched paths, and the tree is the independently computed one"
    $d1 = New-Scratch 'one' $base
    $objectsBefore = (git -C $d1 count-objects -v | Out-String)
    $refsBefore = (git -C $d1 for-each-ref | Out-String)
    $r1 = Invoke-Publisher $d1
    $objectsAfter = (git -C $d1 count-objects -v | Out-String)
    $refsAfter = (git -C $d1 for-each-ref | Out-String)
    $expectedDrop = @('.publicignore', 'drop/b.md', 'notes/My Draft v2.md', 'docs/Mixed Case/sub note.md', ('docs/caf' + [char]0xE9 + '/' + [char]0xE9 + ' note.md'))
    Check ($r1.Code -eq 0) "exit 0 when every gate is clean (got $($r1.Code))"
    Check ($r1.Out -match 'excluded 5 tracked path') "five paths excluded"
    foreach ($p in $expectedDrop) { Check ($r1.Out.Contains($p)) "lists excluded path: $p" }
    Check (-not $r1.Out.Contains('keep/a.md') -and -not $r1.Out.Contains('stays.md')) "kept paths are not listed"
    Check ($r1.Out -match 'leak gate: clean') "leak gate reads clean"
    Check ($r1.Out -match 'DRY RUN: nothing written, nothing pushed') "dry-run banner"
    Check ($objectsBefore -eq $objectsAfter) "a dry run adds no object to the repository"
    Check ($refsBefore -eq $refsAfter -and -not ($refsAfter -match 'public-snapshots')) "a dry run adds no ref"
    $t1 = Get-FilteredTreeId $r1.Out
    $e1 = Get-ExpectedTree $d1 $expectedDrop
    Check ($t1 -ne '' -and $t1 -eq $e1) "filtered tree id equals the independently computed tree ($t1)"

    Write-Host "case 2: the list is read from main's tree, never from the working copy"
    $d2 = New-Scratch 'two' $base
    [System.IO.File]::WriteAllText((Join-Path $d2 '.publicignore'), "$list`nkeep/`n", [System.Text.UTF8Encoding]::new($false))
    $r2 = Invoke-Publisher $d2
    Check ($r2.Code -eq 0 -and -not $r2.Out.Contains('keep/a.md') -and $r2.Out -match 'excluded 5 tracked path') "an uncommitted edit to the list changes nothing"

    Write-Host "case 3: a list that does not exclude itself (so one that matches nothing) fails the repo"
    $d3 = New-Scratch 'three' (With $base @{ '.publicignore' = "# matches nothing`nnothing/here/`n" })
    $r3 = Invoke-Publisher $d3
    Check ($r3.Code -eq 1 -and $r3.Out -match 'does not exclude itself') "exit 1 and the reason is printed"
    $d3b = New-Scratch 'three-b' (With $base @{ '.publicignore' = "drop/`n" })
    $r3b = Invoke-Publisher $d3b
    Check ($r3b.Code -eq 1 -and $r3b.Out -match 'does not exclude itself' -and -not ($r3b.Out -match 'leak gate: clean')) "a list that excludes other paths but not itself fails too"

    Write-Host "case 4: a line outside the rules fails the repo"
    $d4 = New-Scratch 'four' (With $base @{ '.publicignore' = "drop/`n!keep/a.md`n" })
    $r4 = Invoke-Publisher $d4
    Check ($r4.Code -eq 1 -and $r4.Out -match 'FAILED - NOT published' -and $r4.Out -match 'may not start with') "exit 1 on a negation line"

    Write-Host "case 5: an empty list fails the repo (only comments, or zero bytes)"
    $d5 = New-Scratch 'five' (With $base @{ '.publicignore' = "# only a comment`n" })
    $r5 = Invoke-Publisher $d5
    Check ($r5.Code -eq 1 -and $r5.Out -match 'no pattern lines') "a list of comments only exits 1"
    $d5b = New-Scratch 'five-b' (With $base @{ '.publicignore' = '' })
    $r5b = Invoke-Publisher $d5b
    Check ($r5b.Code -eq 1 -and $r5b.Out -match 'no pattern lines') "a zero-byte list exits 1"

    Write-Host "case 6: no list at all is the old behaviour"
    $d6 = New-Scratch 'six' @{ 'keep/a.md' = "plain`n" }
    $r6 = Invoke-Publisher $d6
    Check ($r6.Code -eq 0 -and $r6.Out -match 'no \.publicignore in this tree') "exit 0, says no list"

    Write-Host "case 7: the shared conformance table is run, and a disagreement fails the repo"
    $bad = $goodCases -replace '\{"lines": \["a/\*\.md"\], "path": "a/b/c\.md", "expect": false\}', '{"lines": ["a/*.md"], "path": "a/b/c.md", "expect": true}'
    Check ($bad -ne $goodCases) "the mutated table differs from the real one"
    $d7 = New-Scratch 'seven' (With $base @{ 'scripts/publicignore_cases.json' = $bad })
    $r7 = Invoke-Publisher $d7
    Check ($r7.Code -eq 1 -and $r7.Out -match 'disagrees with the repository''s conformance table') "exit 1 on a disagreement"
    $noTable = $base.Clone()
    $noTable.Remove('scripts/publicignore_cases.json')
    $d7c = New-Scratch 'seven-c' $noTable
    $r7c = Invoke-Publisher $d7c
    Check ($r7c.Code -eq 0 -and $r7c.Out -match 'matcher was not cross-checked') "no table: proceeds and says the matcher was not cross-checked"

    Write-Host "case 8: the leak gate scans the FILTERED tree"
    $d8 = New-Scratch 'eight' (With $base @{ 'keep/planted.md' = "a line $plant here`n" })
    $r8 = Invoke-Publisher $d8
    Check ($r8.Code -eq 1 -and $r8.Out -match 'leak gate: FAILED' -and $r8.Out.Contains('keep/planted.md')) "a planted phrase in an unexcluded file fails the gate and names the file"
    $d8b = New-Scratch 'eight-b' (With $base @{ 'drop/planted.md' = "a line $plant here`n" })
    $r8b = Invoke-Publisher $d8b
    Check ($r8b.Code -eq 0 -and $r8b.Out -match 'leak gate: clean') "the same phrase in an excluded file reads clean"

    Write-Host "case 9: -SourceRef reads another ref; main stays untouched"
    $d9 = New-Scratch 'nine' @{ 'keep/a.md' = "plain`n"; 'drop/b.md' = "x`n" }
    git -C $d9 checkout -q -b topic
    [System.IO.File]::WriteAllText((Join-Path $d9 '.publicignore'), "drop/`n.publicignore`n", [System.Text.UTF8Encoding]::new($false))
    foreach ($rel in $req.Keys) {
        $reqPath = Join-Path $d9 $rel
        New-Item -ItemType Directory -Path (Split-Path $reqPath -Parent) -Force | Out-Null
        [System.IO.File]::WriteAllText($reqPath, [string]$req[$rel], [System.Text.UTF8Encoding]::new($false))
    }
    git -C $d9 add .publicignore ANCHOR.md scripts
    git -C $d9 commit -q -m list
    $r9a = Invoke-Publisher $d9 @('-SourceRef', 'topic')
    $r9b = Invoke-Publisher $d9
    Check ($r9a.Code -eq 0 -and $r9a.Out -match 'excluded 2 tracked path') "-SourceRef topic sees the list"
    Check ($r9b.Code -eq 0 -and $r9b.Out -match 'no \.publicignore in this tree') "default source (main) does not"

    Write-Host "case 10: the dry-run-only switches are refused on a real run"
    $tablePub = New-TablePublisher $d9
    $r10a = & pwsh -NoProfile -File $tablePub -Only blarai -SourceRef topic 2>&1 | Out-String
    $c10a = $LASTEXITCODE
    $r10b = & pwsh -NoProfile -File $tablePub -Only blarai -RepoPathOverride $d9 2>&1 | Out-String
    $c10b = $LASTEXITCODE
    $r10c = & pwsh -NoProfile -File $tablePub -DryRun -RepoPathOverride $d9 2>&1 | Out-String
    $c10c = $LASTEXITCODE
    Check ($c10a -eq 2 -and $r10a -match 'DRY' ) "-SourceRef without -DryRun exits 2"
    Check ($c10b -eq 2) "-RepoPathOverride without -DryRun exits 2"
    Check ($c10c -eq 2) "-RepoPathOverride without -Only exits 2"
    Check ((git -C $d9 for-each-ref | Out-String) -notmatch 'public-snapshots') "no snapshot ref was created by any refused run"

    Write-Host "case 11: a list that is not a regular file, and a source ref that does not resolve, fail the repo (never read as 'no list')"
    $d12 = New-Scratch 'twelve' @{ 'keep/a.md' = "plain`n"; '.publicignore/inner.txt' = "drop/`n" }
    $r12 = Invoke-Publisher $d12
    Check ($r12.Code -eq 1 -and $r12.Out -match 'not a regular file') ".publicignore as a directory exits 1"
    $r12b = Invoke-Publisher $d12 @('-SourceRef', 'no-such-ref')
    Check ($r12b.Code -eq 1 -and $r12b.Out -match 'cannot resolve') "an unresolvable -SourceRef exits 1"

    Write-Host "case 12: the private file carries every phrase the lock carries; the grep view reads the plain form, the normalized view the altered forms"
    $plants = With $req @{ 'keep/a.md' = "plain`n"; 'drop/b.md' = "x`n"; '.publicignore' = ".publicignore`ndrop/`n" }
    $expectGrep = @{}
    $expectView = @{}
    $n = 0
    foreach ($ph in $allPhrases) {
        $n++
        $plants["plants/p$n-plain.txt"] = "x $ph y`n"
        $expectGrep["plants/p$n-plain.txt"] = $ph
        $forms = @{}
        if ($ph.Contains(' ')) {
            $forms['double'] = $ph.Replace(' ', '  ')
            $forms['lf'] = $ph.Replace(' ', "`n")
            $forms['crlf'] = $ph.Replace(' ', "`r`n")
            $forms['tab'] = $ph.Replace(' ', "`t")
            $forms['percent'] = $ph.Replace(' ', '%20')
        }
        $forms['percentcap'] = ('%{0:X2}' -f [int][char]$ph.Substring(0, 1).ToUpperInvariant()[0]) + $ph.Substring(1)
        $escaped = [regex]::Replace($ph, '([_.&-])', '\$1')
        if ($escaped -ne $ph) { $forms['backslash'] = $escaped }
        foreach ($f in $forms.Keys) {
            $plants["plants/p$n-$f.txt"] = "x $($forms[$f]) y`n"
            $expectView["plants/p$n-$f.txt"] = $ph
        }
    }
    Check ($allPhrases.Count -ge 27 -and $expectView.Count -ge 40) "the fixture holds $($allPhrases.Count) phrases and $($expectGrep.Count + $expectView.Count) plants"
    $d13 = New-Scratch 'thirteen' $plants
    $r13 = Invoke-Publisher $d13
    $grepPaths = [System.Collections.Generic.HashSet[string]]::new()
    $viewPaths = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($line in ($r13.Out -split "`r?`n")) {
        $arrow = $line.IndexOf(' -> ')
        if ($arrow -lt 0) { continue }
        $bucket = $grepPaths
        if ($line -match 'phrase view \[') { $bucket = $viewPaths }
        foreach ($pth in $line.Substring($arrow + 4).Split(',')) { [void]$bucket.Add($pth.Trim()) }
    }
    Check ($r13.Code -eq 1 -and $r13.Out -match 'leak gate: FAILED') "the gate fails on the planted tree"
    $missingGrep = @($expectGrep.Keys | Where-Object { -not $grepPaths.Contains($_) } | Sort-Object)
    Check ($missingGrep.Count -eq 0) "the grep view catches the plain form of every phrase (missed: $($missingGrep -join ', '))"
    $missingView = @($expectView.Keys | Where-Object { -not $viewPaths.Contains($_) } | Sort-Object)
    Check ($missingView.Count -eq 0) "the normalized view catches double space, line break, CRLF, tab, percent-encoded space and backslash-escaped punctuation (missed: $($missingView -join ', '))"
    Check (-not $grepPaths.Contains('keep/a.md') -and -not $viewPaths.Contains('keep/a.md') -and -not $viewPaths.Contains('drop/b.md')) "an unplanted file is not named by either view"
    $viewOnly = @($expectView.Keys | Where-Object { $grepPaths.Contains($_) })
    Check ($viewOnly.Count -eq 0) "the altered forms are caught by the normalized view alone (grep matched: $($viewOnly -join ', '))"

    Write-Host "case 13: the normalized view reads UTF-16 and gzip, and the gate fails closed on an unreadable gzip"
    $utf16Phrase = $plainPhrases[1]
    $d14 = New-Scratch 'fourteen' (With $req @{ 'keep/a.md' = "plain`n"; '.publicignore' = ".publicignore`n" })
    [System.IO.File]::WriteAllBytes((Join-Path $d14 'plants16.bin'), [System.Text.Encoding]::Unicode.GetBytes("x $utf16Phrase y"))
    $ms = [System.IO.MemoryStream]::new()
    $gzw = [System.IO.Compression.GZipStream]::new($ms, [System.IO.Compression.CompressionMode]::Compress, $true)
    $gzBytes = [System.Text.Encoding]::UTF8.GetBytes("x $utf16Phrase y")
    $gzw.Write($gzBytes, 0, $gzBytes.Length)
    $gzw.Close()
    [System.IO.File]::WriteAllBytes((Join-Path $d14 'plants.gz'), $ms.ToArray())
    [System.IO.File]::WriteAllBytes((Join-Path $d14 'broken.gz'), ([byte[]](0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x01, 0x02)))
    git -C $d14 add .
    git -C $d14 commit -q -m more
    $r14 = Invoke-Publisher $d14
    Check ($r14.Code -eq 1 -and $r14.Out.Contains('plants16.bin') -and $r14.Out -match 'plants\.gz') "a phrase in UTF-16 and a phrase in gzip are named"
    Check ($r14.Out -match 'gzip cannot be decompressed' -and $r14.Out.Contains('broken.gz')) "an unreadable gzip is reported, not skipped"

    Write-Host "case 14: the dry-run-only switches are refused on a real run; a private file with no phrase line and an oversize blob fail closed"
    $realRun1 = & pwsh -NoProfile -File $tablePub -Only blarai -PrivatePatternsPath (Join-Path $root 'x.txt') 2>&1 | Out-String
    Check ($LASTEXITCODE -eq 2 -and $realRun1 -match 'DryRun only') "-PrivatePatternsPath without -DryRun exits 2"
    $realRun2 = & pwsh -NoProfile -File $tablePub -Only blarai -ViewScanBlobCapOverride 10 2>&1 | Out-String
    Check ($LASTEXITCODE -eq 2 -and $realRun2 -match 'DryRun only') "-ViewScanBlobCapOverride without -DryRun exits 2"
    $noPhrase = Join-Path $root 'no-phrase-patterns.txt'
    $realPatterns = Get-Content -LiteralPath 'C:/Users/mrbla/.blarai-fleet/leakgate-patterns.txt' | Where-Object { $_ -notmatch '^\s*#phrase:' }
    [System.IO.File]::WriteAllLines($noPhrase, [string[]]@($realPatterns), [System.Text.UTF8Encoding]::new($false))
    $d15 = New-Scratch 'fifteen' (With $base @{ '.publicignore' = ".publicignore`ndrop/`n"; 'keep/big.txt' = ('x' * 400) })
    $r15 = Invoke-Publisher $d15 @('-PrivatePatternsPath', $noPhrase)
    Check ($r15.Code -eq 2 -and $r15.Out -match "no '#phrase:' line") "a private file with no '#phrase:' line exits 2"
    $r15b = Invoke-Publisher $d15 @('-ViewScanBlobCapOverride', '100')
    Check ($r15b.Code -eq 1 -and $r15b.Out -match 'larger than the scan cap') "a blob over the cap fails the gate and is named"
    $r15c = Invoke-Publisher $d15
    Check ($r15c.Code -eq 0 -and -not ($r15c.Out -match 'larger than the scan cap')) "the same tree passes with the real cap"

    Write-Host "case 15: a list that removes an anchor path, or every path, fails the repo"
    $anchors = With $req @{ 'README.md' = "hello`n"; 'LICENSE.md' = "terms`n"; 'docs/a.md' = "x`n" }
    $d16 = New-Scratch 'sixteen' (With $anchors @{ '.publicignore' = ".publicignore`nREADME.md`n" })
    $r16 = Invoke-Publisher $d16
    Check ($r16.Code -eq 1 -and $r16.Out -match 'lost anchor path' -and $r16.Out.Contains('README.md')) "a list that excludes README.md exits 1 and names it"
    $d16b = New-Scratch 'sixteen-b' (With $anchors @{ '.publicignore' = "*`n" })
    $r16b = Invoke-Publisher $d16b
    Check ($r16b.Code -eq 1 -and $r16b.Out -match 'FAILED - NOT published' -and -not ($r16b.Out -match 'leak gate: clean')) "a list that matches every path exits 1"
    $d16c = New-Scratch 'sixteen-c' (With $anchors @{ '.publicignore' = ".publicignore`ndocs/`n" })
    $r16c = Invoke-Publisher $d16c
    Check ($r16c.Code -eq 0 -and $r16c.Out -match 'excluded 2 tracked path') "a list that keeps both anchors passes"

    Write-Host "case 16: a list that reaches an anchored path fails the repo; so does an anchor that names nothing"
    $anchored = @{ 'scripts/publicignore_phrases.json' = $phrasesText; 'scripts/publicignore_anchors.txt' = "README.md`ndocs/ev/`n"; 'README.md' = "r`n"; 'docs/ev/nep0005/run.json' = "{}`n"; 'docs/other/x.md' = "x`n" }
    $d17 = New-Scratch 'seventeen' (With $anchored @{ '.publicignore' = ".publicignore`n**/*nep0005*`n" })
    $r17 = Invoke-Publisher $d17
    Check ($r17.Code -eq 1 -and $r17.Out -match 'anchored path' -and $r17.Out.Contains('docs/ev/nep0005/run.json')) "a broad name line that reaches a folder of public evidence exits 1 and names the path"
    $d17b = New-Scratch 'seventeen-b' (With $anchored @{ '.publicignore' = ".publicignore`ndocs/other/`n" })
    $r17b = Invoke-Publisher $d17b
    Check ($r17b.Code -eq 0 -and $r17b.Out -match 'excluded 2 tracked path') "a list that leaves every anchor alone passes"
    $d17c = New-Scratch 'seventeen-c' (With $anchored @{ '.publicignore' = ".publicignore`ndocs/other/`n"; 'scripts/publicignore_anchors.txt' = "README.md`ndocs/gone/`n" })
    $r17c = Invoke-Publisher $d17c
    Check ($r17c.Code -eq 1 -and $r17c.Out -match "names no tracked path") "an anchor that names no tracked path exits 1"

    Write-Host "case 17: the publisher refuses a private file that lacks a phrase of the repository's phrase file"
    $d18 = New-Scratch 'eighteen' (With $req @{ 'keep/a.md' = "plain`n"; '.publicignore' = ".publicignore`n" })
    $r18 = Invoke-Publisher $d18
    Check ($r18.Code -eq 0) "with the real private file every assembled phrase is a needle"
    $oneShort = Join-Path $root 'one-phrase-short.txt'
    $skipped = $false
    $kept = foreach ($ln in (Get-Content -LiteralPath 'C:/Users/mrbla/.blarai-fleet/leakgate-patterns.txt')) {
        if (-not $skipped -and $ln -match '^\s*#phrase:') { $skipped = $true; continue }
        $ln
    }
    [System.IO.File]::WriteAllLines($oneShort, [string[]]@($kept), [System.Text.UTF8Encoding]::new($false))
    $r18b = Invoke-Publisher $d18 @('-PrivatePatternsPath', $oneShort)
    Check ($r18b.Code -eq 1 -and $r18b.Out -match 'lacks 1 of 27 phrases') "a private file one phrase short exits 1 and counts the gap"

    Write-Host "case 18: a list that matches every path of a tree is refused by the anchor check (the empty-tree refusal stays as a second lock)"
    $d19 = New-Scratch 'nineteen' (With $req @{ 'docs/a.md' = "x`n"; '.publicignore' = "*`n" })
    $r19 = Invoke-Publisher $d19
    Check ($r19.Code -eq 1 -and $r19.Out -match 'excludes \d+ anchored path' -and -not ($r19.Out -match 'leak gate: clean')) "exit 1 and the reason is the anchored paths"
    # toggle: with the anchored-path refusal removed from a copy of the publisher, the same tree reaches the empty-tree refusal
    $noAnchorCheck = [regex]::Replace((Get-Content -LiteralPath $Publisher -Raw -Encoding UTF8), '(?m)^\s*if \(\$removed\.Count -gt 0\) \{ throw "\.publicignore excludes[^\n]*$', '')
    Check ($noAnchorCheck -ne (Get-Content -LiteralPath $Publisher -Raw -Encoding UTF8)) "the toggle copy differs from the publisher (the anchored-path refusal is removed)"
    $noAnchorPath = Join-Path $root 'pub-no-anchor-check.ps1'
    [System.IO.File]::WriteAllText($noAnchorPath, $noAnchorCheck, [System.Text.UTF8Encoding]::new($false))
    $r19b = & pwsh -NoProfile -File $noAnchorPath -Only blarai -DryRun -RepoPathOverride $d19 2>&1 | Out-String
    Check ($LASTEXITCODE -eq 1 -and $r19b -match 'filtered tree is empty') "toggle: without the anchor check the empty-tree refusal still stops a list that matches every path"

    Write-Host "case 19: the self-test passes on the real table and fails on the mutated one"
    $mutated = Join-Path $root 'cases-mutated.json'
    [System.IO.File]::WriteAllText($mutated, $bad, [System.Text.UTF8Encoding]::new($false))
    & pwsh -NoProfile -File $Publisher -SelfTest -CasesFile $CasesFile *> $null
    Check ($LASTEXITCODE -eq 0) "-SelfTest passes on the shared table"
    & pwsh -NoProfile -File $Publisher -SelfTest -CasesFile $mutated *> $null
    Check ($LASTEXITCODE -eq 1) "-SelfTest fails on the mutated table"
    Write-Host "case 20: a tree that carries a list must carry the anchor file and the phrase file, or the repo is refused by name (#1785)"
    $d20 = New-Scratch 'twenty' $base
    $r20 = Invoke-Publisher $d20
    Check ($r20.Code -eq 0 -and $r20.Out -match 'leak gate: clean') "the complete tree passes (so the refusals below come from the missing file alone)"
    $noAnchors = $base.Clone()
    $noAnchors.Remove('scripts/publicignore_anchors.txt')
    $d20a = New-Scratch 'twenty-a' $noAnchors
    $r20a = Invoke-Publisher $d20a
    Check ($r20a.Code -eq 1 -and $r20a.Out -match 'FAILED - NOT published' -and $r20a.Out.Contains('scripts/publicignore_anchors.txt') -and -not ($r20a.Out -match 'leak gate: clean')) "no anchor file: exit 1, the file is named, nothing is published"
    $noPhraseFile = $base.Clone()
    $noPhraseFile.Remove('scripts/publicignore_phrases.json')
    $d20b = New-Scratch 'twenty-b' $noPhraseFile
    $r20b = Invoke-Publisher $d20b
    Check ($r20b.Code -eq 1 -and $r20b.Out -match 'FAILED - NOT published' -and $r20b.Out.Contains('scripts/publicignore_phrases.json') -and -not ($r20b.Out -match 'leak gate: clean')) "no phrase file: exit 1, the file is named, nothing is published"
    $neither = $noAnchors.Clone()
    $neither.Remove('scripts/publicignore_phrases.json')
    $d20c = New-Scratch 'twenty-c' $neither
    $r20c = Invoke-Publisher $d20c
    Check ($r20c.Code -eq 1 -and $r20c.Out -match 'FAILED - NOT published') "neither file: exit 1"
    $d20d = New-Scratch 'twenty-d' @{ 'keep/a.md' = "plain`n" }
    $r20d = Invoke-Publisher $d20d
    Check ($r20d.Code -eq 0 -and $r20d.Out -match 'no \.publicignore in this tree') "a tree with no list is not asked for either file"
    # toggle: the same publisher with both refusals removed passes the trees above, so the checks above do bite
    $weak = (Get-Content -LiteralPath $Publisher -Raw -Encoding UTF8) -replace '(?m)^\s*throw "this tree carries a \.publicignore but no scripts/publicignore_(anchors\.txt|phrases\.json)[^\n]*$', ''
    $weakPath = Join-Path $root 'pub-weak.ps1'
    [System.IO.File]::WriteAllText($weakPath, $weak, [System.Text.UTF8Encoding]::new($false))
    Check ($weak -ne (Get-Content -LiteralPath $Publisher -Raw -Encoding UTF8)) "the toggle copy differs from the publisher (both throws removed)"
    $rWeak = & pwsh -NoProfile -File $weakPath -Only blarai -DryRun -RepoPathOverride $d20c 2>&1 | Out-String
    Check ($LASTEXITCODE -eq 0 -and -not ($rWeak -match 'FAILED - NOT published')) "toggle: without the two refusals the tree with neither file passes, so the refusal is what stops it"

} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host "FAILED: $($failures.Count) check(s) failed, $passed passed" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
    exit 1
}
Write-Host "PASSED: $passed checks" -ForegroundColor Green
exit 0
