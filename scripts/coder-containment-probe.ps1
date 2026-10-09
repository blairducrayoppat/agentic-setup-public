#requires -Version 5.1
<#
.SYNOPSIS
  The four ACP-01 Decision-1(b) containment probes (#775 / PHASE1 §5.3, ACP-01 §7.4), run IN THE
  CONTEXT IT IS LAUNCHED — designed to be spawned AS the blarai-coder account on a REAL child (never
  the launcher token) so the checks observe exactly what the dispatched coder can and cannot do.

.DESCRIPTION
  Emits a JSON result to -OutJson (and exits 0 regardless — the caller, verify-coder-containment.ps1,
  reads the file and decides pass/fail). The four checks:
    1. outbound_blocked      — a TCP connect to an EXTERNAL host:443 must FAIL (egress denied).
    2. secret_reads_denied   — reading each operator secret path must be ACL-DENIED.
    3. loopback_ok           — a GET to the model's loopback URL must SUCCEED (the positive control —
                               a too-broad rule that kills 127.0.0.1:8000 would silently no-op every
                               dispatch). In -LoopbackStub mode the verifier stands up a stub listener
                               so this proves the FIREWALL loopback scoping without OVMS/GPU.
    4. sid_is_coder          — this process's own token SID (emitted for the caller to assert equals the
                               blarai-coder SID) — proves the firewall keys on the token the coder
                               ACTUALLY runs under, not an impersonated/duplicated one.

  It is deliberately dependency-free (no fleet imports) so it runs cleanly under the powerless account.
#>
[CmdletBinding()]
param(
    [string[]]$SecretPaths = @(),
    [string]$LoopbackUrl = 'http://127.0.0.1:8000/v3/models',
    [string]$OutboundHost = '1.1.1.1',
    [int]$OutboundPort = 443,
    [int]$OutboundTimeoutMs = 5000,
    # The narrowing checks (#1678). Each is optional; a check runs only when its input is given, so a probe
    # job from before this change still produces the same four checks.
    [string[]]$WriteDenyDirs = @(),      # directories where creating a file must be DENIED (sibling repo, new repo)
    [string[]]$SourceGitRepos = @(),     # repos whose .git refs/objects must not be creatable
    [string[]]$ReadFiles = @(),          # files that must be READABLE (assets/README.txt of a seeded repo)
    [string[]]$WorktreePaths = @(),      # the coder's own worktrees: write works, git commit must fail
    # The tool-chain setup checks (#775 plan step 4). Each is optional; a check runs only when its input is given.
    [string]$ProxyUrl = '',              # the model repair proxy the coder's opencode config names (loopback :8099)
    [string[]]$OperatorDenyPaths = @(),  # operator profile paths the coder must NOT read (opencode config, .ssh, keystore)
    [string[]]$ToolchainExes = @(),      # executables that must start for the coder (--version)
    [int]$ToolchainTimeoutSec = 15,      # per executable: a --version that has not returned by then is a FAIL (it never blocks the probe)
    [string]$ConfigDir = '',             # the coder-owned opencode config folder (default: <USERPROFILE>\.config\opencode)
    [string[]]$ExtraWriteDenyDirs = @(), # more folders where creating a file must be DENIED (fleet root, fleet scripts, operator state)
    [switch]$CheckConfig,                # run the coder-config checks (config readable + write-protected, research log writable)
    [string]$ParamsFile = '',            # a JSON file holding any of the lists/values above (the way -Credential mode passes arrays)
    [Parameter(Mandatory)][string]$OutJson
)
if ($ParamsFile) {
    $pj = Get-Content -LiteralPath $ParamsFile -Raw | ConvertFrom-Json
    foreach ($k in 'SecretPaths', 'WriteDenyDirs', 'SourceGitRepos', 'ReadFiles', 'WorktreePaths', 'OperatorDenyPaths', 'ToolchainExes', 'ExtraWriteDenyDirs') { if ($null -ne $pj.$k) { Set-Variable -Name $k -Value @($pj.$k) } }
    foreach ($k in 'LoopbackUrl', 'OutboundHost', 'OutboundPort', 'OutboundTimeoutMs', 'ProxyUrl', 'ConfigDir', 'ToolchainTimeoutSec') { if ($null -ne $pj.$k) { Set-Variable -Name $k -Value $pj.$k } }
    if ($null -ne $pj.CheckConfig) { $CheckConfig = [bool]$pj.CheckConfig }
}

function Test-OutboundBlocked {
    # PASS when the external connect does NOT complete (SYN dropped by the per-SID block => timeout).
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($OutboundHost, $OutboundPort, $null, $null)
        $connected = $iar.AsyncWaitHandle.WaitOne($OutboundTimeoutMs, $false)
        if ($connected -and $client.Connected) {
            $client.EndConnect($iar); $client.Close()
            return @{ pass = $false; detail = "connected to $OutboundHost`:$OutboundPort — EGRESS IS NOT BLOCKED" }
        }
        $client.Close()
        return @{ pass = $true; detail = "no connection to $OutboundHost`:$OutboundPort within ${OutboundTimeoutMs}ms (blocked)" }
    } catch {
        # A hard failure (SocketException) also means the connect did not succeed -> blocked.
        return @{ pass = $true; detail = "connect threw ($($_.Exception.GetType().Name)) — not reachable (blocked)" }
    }
}

function Test-SecretReadsDenied {
    param([string[]]$Paths = $SecretPaths, [string]$What = 'each named operator secret path must be ACL-denied')
    $perPath = @{}
    $allDenied = $true
    $deniedCount = 0
    foreach ($p in $Paths) {
        if (-not (Test-Path $p -ErrorAction SilentlyContinue)) {
            # Nothing to leak here; not a failure, but record it honestly.
            $perPath[$p] = 'absent (nothing to read)'
            continue
        }
        try {
            if (Test-Path $p -PathType Container) {
                $null = Get-ChildItem -LiteralPath $p -Force -ErrorAction Stop | Select-Object -First 1
            } else {
                $null = Get-Content -LiteralPath $p -TotalCount 1 -ErrorAction Stop
            }
            # Read SUCCEEDED -> the coder can see a secret -> FAIL.
            $perPath[$p] = 'READABLE — not denied'
            $allDenied = $false
        } catch [System.UnauthorizedAccessException] {
            $perPath[$p] = 'denied (UnauthorizedAccess)'; $deniedCount++
        } catch {
            # Other errors (e.g. IO) — treat as not-a-clean-deny; be conservative and FAIL so the
            # coordinator inspects rather than a false green.
            if ($_.Exception -is [System.Security.SecurityException]) {
                $perPath[$p] = 'denied (SecurityException)'; $deniedCount++
            } else {
                $perPath[$p] = "inconclusive ($($_.Exception.GetType().Name)) — INSPECT"
                $allDenied = $false
            }
        }
    }
    # FAIL CLOSED: a check that read nothing certifies nothing. At least one named path must exist and be denied.
    $detail = $What
    if ($deniedCount -eq 0 -and $allDenied) { $detail = "read ZERO existing secret paths ($(@($Paths).Count) named): nothing was proven, so this check FAILS (a mangled or empty list must not pass)" }
    return @{ pass = ($allDenied -and $deniedCount -gt 0); detail = $detail; per_path = $perPath }
}

function Test-LoopbackOk {
    try {
        $resp = Invoke-WebRequest -Uri $LoopbackUrl -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
        return @{ pass = ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 500); detail = "GET $LoopbackUrl -> HTTP $($resp.StatusCode)" }
    } catch {
        # A 4xx still proves loopback REACHED the server (the socket was allowed); only a
        # connect/timeout failure means the firewall killed loopback.
        $status = $null
        try { $status = [int]$_.Exception.Response.StatusCode } catch {}
        if ($status -and $status -ge 400 -and $status -lt 500) {
            return @{ pass = $true; detail = "GET $LoopbackUrl -> HTTP $status (loopback reached the server)" }
        }
        return @{ pass = $false; detail = "GET $LoopbackUrl FAILED ($($_.Exception.Message)) — loopback to the model was blocked" }
    }
}

function Test-DeniedByAcl {
    # Run $Try (an attempt to create something). Returns @{ Denied; Detail }. Denied ONLY on an access-denied
    # error; success (the thing was created) is NOT denied, and any other error is inconclusive (not denied).
    param([scriptblock]$Try, [string]$What)
    try { & $Try; return @{ Denied = $false; Detail = "$What SUCCEEDED -- the coder can write there" } }
    catch {
        $inner = $_.Exception
        while ($inner.InnerException) { $inner = $inner.InnerException }
        if ($inner -is [System.UnauthorizedAccessException] -or $inner.HResult -eq -2147024891) { return @{ Denied = $true; Detail = "$What denied (UnauthorizedAccess)" } }
        return @{ Denied = $false; Detail = "$What inconclusive ($($_.Exception.GetType().Name): $($_.Exception.Message)) -- INSPECT" }
    }
}

function Test-WriteOutsideDenied {
    # one entry per named folder: per_path[dir] = @{ pass; detail }; the check passes only when EVERY one is denied
    $per = @{}; $all = $true
    foreach ($d in $WriteDenyDirs) {
        $f = Join-Path $d ("blarai-probe-" + [guid]::NewGuid().ToString('N') + '.tmp')
        $r = Test-DeniedByAcl -What "create file in $d" -Try { $s = [IO.File]::Create($f); $s.Dispose() }
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
        $per[$d] = @{ pass = [bool]$r.Denied; detail = $r.Detail }
        if (-not $r.Denied) { $all = $false }
    }
    return @{ pass = ($all -and $WriteDenyDirs.Count -gt 0); detail = 'creating a file in each named repo folder must be ACL-denied'; per_path = $per }
}

function Test-SourceGitWriteDenied {
    $per = @{}; $all = $true
    foreach ($repo in $SourceGitRepos) {
        $git = Join-Path $repo '.git'
        $tag = [guid]::NewGuid().ToString('N')
        $ref = Join-Path $git "refs\heads\blarai-probe-$tag"
        $r1 = Test-DeniedByAcl -What "create .git/refs/heads/x in $repo" -Try { $s = [IO.File]::Create($ref); $s.Dispose() }
        if (Test-Path -LiteralPath $ref) { Remove-Item -LiteralPath $ref -Force -ErrorAction SilentlyContinue }
        $dir = Join-Path $git ("objects\" + $tag.Substring(0, 2) + "-probe")
        $r2 = Test-DeniedByAcl -What "create .git/objects/xx in $repo" -Try { [void][IO.Directory]::CreateDirectory($dir) }
        if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
        $per["$repo refs"] = @{ pass = [bool]$r1.Denied; detail = $r1.Detail }
        $per["$repo objects"] = @{ pass = [bool]$r2.Denied; detail = $r2.Detail }
        if (-not ($r1.Denied -and $r2.Denied)) { $all = $false }
    }
    return @{ pass = ($all -and $SourceGitRepos.Count -gt 0); detail = 'creating a ref or an object folder in the source repo .git must be ACL-denied'; per_path = $per }
}

function Test-ReadFilesOk {
    $per = @{}; $all = $true
    foreach ($f in $ReadFiles) {
        try { $null = Get-Content -LiteralPath $f -TotalCount 1 -ErrorAction Stop; $per[$f] = @{ pass = $true; detail = 'readable' } }
        catch { $per[$f] = @{ pass = $false; detail = "NOT readable: $($_.Exception.Message)" }; $all = $false }
    }
    return @{ pass = ($all -and $ReadFiles.Count -gt 0); detail = 'each named file must be readable by the coder'; per_path = $per }
}

function Test-WorktreeWriteAndCommit {
    # In the coder's own worktree: a file write must WORK (the coder keeps Modify there) and `git commit` must
    # FAIL for a permission reason. The control that git itself runs for this account (git status exits 0) rules
    # out a refusal for another reason (ownership, a missing git), and HEAD must be unchanged.
    $perW = @{}; $perC = @{}; $writeOk = $true; $commitFails = $true
    $git = (Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    foreach ($wt in $WorktreePaths) {
        $f = Join-Path $wt 'probe-work.txt'
        try { Set-Content -LiteralPath $f -Value 'written by the coder' -Encoding ASCII -ErrorAction Stop; $perW[$wt] = @{ pass = $true; detail = 'write ok' } }
        catch { $perW[$wt] = @{ pass = $false; detail = "write FAILED: $($_.Exception.Message)" }; $writeOk = $false }
        if (-not $git) { $perC[$wt] = @{ pass = $false; detail = 'git not found for this account -- inconclusive' }; $commitFails = $false; continue }
        # safe.directory names exactly this worktree (the scoped value the coder leg uses); never '*'
        $base = @('-c', ('safe.directory=' + $wt.TrimEnd('\').Replace('\', '/')), '-c', 'user.name=coder-probe', '-c', 'user.email=probe@local', '-C', $wt, '--no-pager')
        $env:GIT_TERMINAL_PROMPT = '0'
        $status = & $git @base status --porcelain 2>&1 | Out-String; $statusRc = $LASTEXITCODE
        $headBefore = (& $git @base rev-parse HEAD 2>&1 | Out-String).Trim()
        $add = & $git @base add -A 2>&1 | Out-String; $addRc = $LASTEXITCODE
        $commit = & $git @base commit -m 'coder probe commit' 2>&1 | Out-String; $commitRc = $LASTEXITCODE
        $headAfter = (& $git @base rev-parse HEAD 2>&1 | Out-String).Trim()
        $perm = (($add + $commit) -match '(?i)permission denied|access is denied|unable to create|could not lock|cannot lock|unable to write|insufficient permission|unable to append')
        $failed = ($addRc -ne 0 -or $commitRc -ne 0)
        $ok = ($statusRc -eq 0) -and $failed -and $perm -and ($headBefore -eq $headAfter)
        $perC[$wt] = @{ pass = [bool]$ok; detail = "status rc=$statusRc (read control), add rc=$addRc, commit rc=$commitRc, permission-text=$perm, HEAD unchanged=$($headBefore -eq $headAfter)" }
        if (-not $ok) { $commitFails = $false }
    }
    return @{ write_ok = @{ pass = ($writeOk -and $WorktreePaths.Count -gt 0); detail = 'the coder can still write inside its own worktree'; per_path = $perW }
              commit_fails = @{ pass = ($commitFails -and $WorktreePaths.Count -gt 0); detail = 'git add/commit in the worktree must fail for a permission reason (the operator funnel commits)'; per_path = $perC } }
}

function Test-ProxyLoopbackOk {
    # the model repair proxy the coder's opencode config names: any HTTP answer from the socket proves loopback is open
    try {
        $resp = Invoke-WebRequest -Uri $ProxyUrl -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
        return @{ pass = ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 500); detail = "GET $ProxyUrl -> HTTP $($resp.StatusCode)" }
    } catch {
        $status = $null
        try { $status = [int]$_.Exception.Response.StatusCode } catch {}
        if ($status -and $status -ge 400 -and $status -lt 500) { return @{ pass = $true; detail = "GET $ProxyUrl -> HTTP $status (the proxy answered)" } }
        return @{ pass = $false; detail = "GET $ProxyUrl FAILED ($($_.Exception.Message)) - the proxy is not reachable for the coder" }
    }
}

function Test-GitStatusOk {
    # git status in each coder worktree with ONLY the scoped environment the coder leg uses (safe.directory for that
    # worktree, no wildcard). A refusal for ownership shows up here as a non-zero exit with 'dubious ownership'.
    $per = @{}; $all = $true
    $git = (Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    foreach ($wt in $WorktreePaths) {
        if (-not $git) { $per[$wt] = @{ pass = $false; detail = 'git not found for this account' }; $all = $false; continue }
        $wd = $wt.TrimEnd('\').Replace('\', '/')
        $saved = @{}
        $set = [ordered]@{ GIT_OPTIONAL_LOCKS = '0'; GIT_TERMINAL_PROMPT = '0'; GIT_CONFIG_COUNT = '2'; GIT_CONFIG_KEY_0 = 'safe.directory'; GIT_CONFIG_VALUE_0 = $wd; GIT_CONFIG_KEY_1 = 'core.fsmonitor'; GIT_CONFIG_VALUE_1 = 'false' }
        foreach ($k in $set.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, [string]$set[$k]) }
        try {
            $o = & $git -C $wt --no-pager status --porcelain 2>&1 | Out-String; $rc = $LASTEXITCODE
            # the second path: opencode's shell gets NO git variables, so the coder's own ~/.config/git/config alone must make git trust the worktree
            foreach ($k in $set.Keys) { [Environment]::SetEnvironmentVariable($k, $null) }
            $o2 = & $git -C $wt --no-pager status --porcelain 2>&1 | Out-String; $rc2 = $LASTEXITCODE
        } finally { foreach ($k in $set.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }
        $dubious = ($o -match '(?i)dubious ownership'); $dubious2 = ($o2 -match '(?i)dubious ownership')
        $per[$wt] = @{ pass = ($rc -eq 0 -and -not $dubious -and $rc2 -eq 0 -and -not $dubious2); detail = "git status rc=$rc dubious-ownership=$dubious (runner environment); rc=$rc2 dubious-ownership=$dubious2 (coder git config only)" }
        if (-not $per[$wt].pass) { $all = $false }
    }
    return @{ pass = ($all -and $WorktreePaths.Count -gt 0); detail = 'git status must run in each coder worktree under the scoped safe.directory'; per_path = $per }
}

function Test-ToolchainRuns {
    # Each executable is started with a hidden, redirected process and a hard wait: a hang is a failure, not a stall.
    $per = @{}; $all = $true
    foreach ($tool in $ToolchainExes) {
        if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) { $per[$tool] = @{ pass = $false; detail = 'not found / not readable for this account' }; $all = $false; continue }
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $tool; [void]$psi.ArgumentList.Add('--version')
            $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
            $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = $true
            $p = [System.Diagnostics.Process]::Start($psi)
            $p.StandardInput.Close()
            $so = $p.StandardOutput.ReadToEndAsync(); $se = $p.StandardError.ReadToEndAsync()
            if (-not $p.WaitForExit($ToolchainTimeoutSec * 1000)) {
                try { $p.Kill($true) } catch { }
                $per[$tool] = @{ pass = $false; detail = "no answer within ${ToolchainTimeoutSec}s (killed)" }
            } else {
                $p.WaitForExit()
                $first = ("$($so.GetAwaiter().GetResult())$($se.GetAwaiter().GetResult())").Trim().Split([char]10)[0]
                $per[$tool] = @{ pass = ($p.ExitCode -eq 0); detail = "rc=$($p.ExitCode) $first" }
            }
        } catch { $per[$tool] = @{ pass = $false; detail = "start failed: $($_.Exception.Message)" } }
        if (-not $per[$tool].pass) { $all = $false }
    }
    return @{ pass = ($all -and $ToolchainExes.Count -gt 0); detail = 'each named executable must start for the coder'; per_path = $per }
}

function Test-CoderConfigOk {
    $dir = if ($ConfigDir) { $ConfigDir } else { Join-Path $env:USERPROFILE '.config\opencode' }
    $f = Join-Path $dir 'opencode.json'
    try {
        $raw = Get-Content -LiteralPath $f -Raw -ErrorAction Stop
        $j = if ($PSVersionTable.PSVersion.Major -ge 6) { $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop } else { $raw | ConvertFrom-Json -ErrorAction Stop }
        $keys = if ($j -is [System.Collections.IDictionary]) { @($j.Keys) } else { @($j.PSObject.Properties.Name) }
        $perm = if ($j -is [System.Collections.IDictionary]) { $j['permission'] } else { $j.permission }
        $readBlock = if ($perm -is [System.Collections.IDictionary]) { $perm['read'] } elseif ($perm) { $perm.read } else { $null }
        $nRead = if ($readBlock -is [System.Collections.IDictionary]) { $readBlock.Count } elseif ($readBlock) { @($readBlock.PSObject.Properties).Count } else { 0 }
        $hasMcp = ($keys -contains 'mcp')
        # opencode reads ~/.config/opencode of the profile it RUNS in: the folder that was checked must be that one
        $home2 = Split-Path (Split-Path $dir -Parent) -Parent
        $homeOk = ($env:USERPROFILE -and ($env:USERPROFILE.TrimEnd('\') -ieq $home2.TrimEnd('\')))
        $ok = (-not $hasMcp) -and ($nRead -gt 20) -and $homeOk
        return @{ pass = [bool]$ok; detail = "read $f ok; mcp-block=$hasMcp; read-permission-entries=$nRead; USERPROFILE-is-the-config-profile=$homeOk ($env:USERPROFILE)" }
    } catch { return @{ pass = $false; detail = "cannot read or parse $f ($($_.Exception.GetType().Name): $($_.Exception.Message))" } }
}

function Test-CoderConfigWriteDenied {
    $dir = if ($ConfigDir) { $ConfigDir } else { Join-Path $env:USERPROFILE '.config\opencode' }
    $per = @{}; $all = $true
    foreach ($rel in 'opencode.json', 'AGENTS.md', 'plugin\command-timeout.js', 'tool\search_docs.js', '..\git\config') {
        $f = [IO.Path]::GetFullPath((Join-Path $dir $rel))
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { $per[$rel] = @{ pass = $false; detail = 'file is absent, so nothing was proven' }; $all = $false; continue }
        $r = Test-DeniedByAcl -What "append to $rel" -Try { $s = [IO.File]::Open($f, [IO.FileMode]::Append, [IO.FileAccess]::Write); $s.Dispose() }
        $d = Test-DeniedByAcl -What "delete $rel" -Try { [IO.File]::Delete($f) }
        $per[$rel] = @{ pass = ([bool]$r.Denied -and [bool]$d.Denied); detail = "$($r.Detail); $($d.Detail)" }
        if (-not $per[$rel].pass) { $all = $false }
    }
    # the folders themselves: nothing may be created in the config folder (a second opencode.jsonc would be merged in),
    # and the folder may not be renamed away; node_modules (opencode's own install) must stay writable
    $cf = Join-Path $dir ('blarai-probe-' + [guid]::NewGuid().ToString('N') + '.jsonc')
    $c = Test-DeniedByAcl -What "create a file in $dir" -Try { $s = [IO.File]::Create($cf); $s.Dispose() }
    if (Test-Path -LiteralPath $cf) { Remove-Item -LiteralPath $cf -Force -ErrorAction SilentlyContinue }
    $per['create-in-config-folder'] = @{ pass = [bool]$c.Denied; detail = $c.Detail }; if (-not $c.Denied) { $all = $false }
    $moved = "$dir.probe-moved"
    $m = Test-DeniedByAcl -What "rename $dir" -Try { [IO.Directory]::Move($dir, $moved) }
    if (Test-Path -LiteralPath $moved) { try { [IO.Directory]::Move($moved, $dir) } catch { } }
    $per['rename-config-folder'] = @{ pass = [bool]$m.Denied; detail = $m.Detail }; if (-not $m.Denied) { $all = $false }
    $nm = Join-Path $dir 'node_modules'; $nf = Join-Path $nm ('probe-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try { [IO.File]::WriteAllText($nf, 'x'); Remove-Item -LiteralPath $nf -Force; $per['node_modules-writable'] = @{ pass = $true; detail = 'created and removed a file in node_modules' } }
    catch { $per['node_modules-writable'] = @{ pass = $false; detail = "node_modules is not writable: $($_.Exception.Message)" }; $all = $false }
    return @{ pass = $all; detail = 'the coder must not be able to write, delete, rename or add to its own opencode config, rules, plugin, tool or git config files; only node_modules stays writable'; per_path = $per }
}

function Test-CoderConfigRootIntact {
    # The coder owns its profile root, so NTFS lets it rename ~/.config away (the parent's delete-child right) and
    # put something else in its place; that rename cannot be prevented by the folder's own access list, only
    # DETECTED. This check is that detection: each folder of the installed config (~/.config, opencode, plugin,
    # tool, git) must exist as a real folder (no link) whose OWNER is the Administrators group. A replacement the
    # coder makes is owned by the coder (or is a link, or is missing), so it fails here.
    $dir = if ($ConfigDir) { $ConfigDir } else { Join-Path $env:USERPROFILE '.config\opencode' }
    $xdg = Split-Path $dir -Parent
    $per = @{}; $all = $true
    foreach ($d in @($xdg, $dir, (Join-Path $dir 'plugin'), (Join-Path $dir 'tool'), (Join-Path $xdg 'git'))) {
        try {
            $a = [IO.File]::GetAttributes($d)
            if (-not ($a -band [IO.FileAttributes]::Directory)) { $per[$d] = @{ pass = $false; detail = 'not a folder' } }
            elseif ($a -band [IO.FileAttributes]::ReparsePoint) { $per[$d] = @{ pass = $false; detail = 'is a link (junction or symbolic link)' } }
            else {
                $o = (Get-Acl -LiteralPath $d -ErrorAction Stop).GetOwner([Security.Principal.SecurityIdentifier]).Value
                $per[$d] = @{ pass = ($o -eq 'S-1-5-32-544'); detail = "real folder, owner $o$(if ($o -ne 'S-1-5-32-544') { ' (expected S-1-5-32-544, Administrators)' })" }
            }
        } catch { $per[$d] = @{ pass = $false; detail = "cannot be inspected ($($_.Exception.GetType().Name): $($_.Exception.Message))" } }
        if (-not $per[$d].pass) { $all = $false }
    }
    return @{ pass = $all; detail = 'every folder of the installed config must be a real folder owned by Administrators; a folder the coder renamed away and replaced is owned by the coder, is a link, or is missing'; per_path = $per }
}

function Test-ResearchLogWritable {
    # the research usage log lives under the coder's OWN profile (the tool wrapper's default); the probe writes a
    # separate .tmp file there so the evidence stream is never polluted
    $dir = Join-Path $env:USERPROFILE '.local\share\blarai-coder'
    $f = Join-Path $dir ('probe-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [void][IO.Directory]::CreateDirectory($dir)
        [IO.File]::WriteAllText($f, 'probe')
        Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        return @{ pass = $true; detail = "created and removed a file in $dir" }
    } catch { return @{ pass = $false; detail = "cannot write in $dir ($($_.Exception.Message))" } }
}

function Test-ExtraWriteDenied {
    $per = @{}; $all = $true
    foreach ($d in $ExtraWriteDenyDirs) {
        if (-not (Test-Path -LiteralPath $d -PathType Container)) { $per[$d] = @{ pass = $false; detail = 'folder is absent, so nothing was proven' }; $all = $false; continue }
        $f = Join-Path $d ("blarai-probe-" + [guid]::NewGuid().ToString('N') + '.tmp')
        $r = Test-DeniedByAcl -What "create file in $d" -Try { $s = [IO.File]::Create($f); $s.Dispose() }
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
        $per[$d] = @{ pass = [bool]$r.Denied; detail = $r.Detail }
        if (-not $r.Denied) { $all = $false }
    }
    return @{ pass = ($all -and $ExtraWriteDenyDirs.Count -gt 0); detail = 'creating a file in each named folder must be ACL-denied'; per_path = $per }
}

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$result = [ordered]@{
    ran_as_user = $id.Name
    ran_as_sid  = $id.User.Value
    checks = [ordered]@{
        outbound_blocked    = (Test-OutboundBlocked)
        secret_reads_denied = (Test-SecretReadsDenied)
        loopback_ok         = (Test-LoopbackOk)
        sid_is_coder        = @{ pass = $true; detail = "token SID = $($id.User.Value) (caller asserts == blarai-coder SID)"; sid = $id.User.Value }
    }
}
if ($WriteDenyDirs.Count -gt 0)  { $result.checks.write_outside_denied = (Test-WriteOutsideDenied) }
if ($SourceGitRepos.Count -gt 0) { $result.checks.source_git_write_denied = (Test-SourceGitWriteDenied) }
if ($ReadFiles.Count -gt 0)      { $result.checks.read_files_ok = (Test-ReadFilesOk) }
if ($WorktreePaths.Count -gt 0)  { $wc = Test-WorktreeWriteAndCommit; $result.checks.worktree_write_ok = $wc.write_ok; $result.checks.worktree_commit_fails = $wc.commit_fails }
# the tool-chain setup checks (#775 plan step 4)
if ($ProxyUrl)                   { $result.checks.proxy_loopback_ok = (Test-ProxyLoopbackOk) }
if ($OperatorDenyPaths.Count -gt 0) { $result.checks.operator_profile_denied = (Test-SecretReadsDenied -Paths $OperatorDenyPaths -What 'each named operator profile path must be ACL-denied') }
if ($WorktreePaths.Count -gt 0)  { $result.checks.git_status_ok = (Test-GitStatusOk) }
if ($ToolchainExes.Count -gt 0)  { $result.checks.toolchain_runs = (Test-ToolchainRuns) }
if ($CheckConfig)                { $result.checks.coder_config_ok = (Test-CoderConfigOk); $result.checks.coder_config_write_denied = (Test-CoderConfigWriteDenied); $result.checks.research_log_writable = (Test-ResearchLogWritable); $result.checks.coder_config_root_intact = (Test-CoderConfigRootIntact) }
if ($ExtraWriteDenyDirs.Count -gt 0) { $result.checks.extra_write_denied = (Test-ExtraWriteDenied) }
$dir = Split-Path $OutJson -Parent
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
($result | ConvertTo-Json -Depth 8) | Set-Content -Path $OutJson -Encoding UTF8
Write-Host "containment probe wrote $OutJson (ran as $($id.Name))"
exit 0
