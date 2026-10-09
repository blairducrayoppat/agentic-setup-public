#requires -Version 5.1
<#
.SYNOPSIS
  The coder's own tool-chain setup under containment = restricted_account (#775 plan step 4): the read grants
  the restricted account needs to RUN its tool chain, and the coder-OWNED opencode configuration that replaces
  the operator's. Dot-source it; it has NO side effects on load. The functions that touch the machine
  (Install-/Remove-CoderOpencodeConfig) take every path as a parameter, so verify-coder-setup.ps1 drives them on
  a temp tree.

.DESCRIPTION
  CONTRACT
    * The restricted coder reads NOTHING of the operator's profile beyond the folders returned by
      Get-CoderToolchainReadGrants (read-and-run only, never write). Every grant is validated by
      Test-CoderGrantAllowed before it is returned: a path that equals, contains or sits inside a never-grant
      path (the repo roots, certs, the runtime keystore, the operator's secret folders, the profile root) is
      refused.
    * The coder's opencode configuration is built FROM the repo's configs/opencode.json (the SSOT), never copied
      from the operator's profile: the same provider wiring and the same permission block, minus the MCP block,
      no plugin declaration, no credential. Test-CoderOpencodeConfigSafe is the single verdict on that; the
      renderer refuses to produce a config that fails it.
    * The installed configuration is write-protected for the coder (explicit entries only: Administrators,
      SYSTEM and the operator full, the coder read-and-run). Test-CoderOpencodeConfigInstalled re-checks content,
      the set of files in plugin/ and tool/, and the access lists.
    * Nothing in this file is read by the containment=off path (verify-coder-off-differential.ps1 proves the
      off-path scripts never name it).
#>

# ---- paths in the manifest --------------------------------------------------------------------------------

function Test-CoderToolchainPathText {
    # Returns '' when the text is a usable absolute drive path, else the reason. No wildcard, no control or
    # shell character, no dot-dot segment, no stream/device syntax, no UNC or extended-length prefix.
    param([AllowEmptyString()][AllowNull()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return 'empty path' }
    if ($Path -notmatch '^[A-Za-z]:[\\/]') { return "not an absolute drive path: '$Path'" }
    if ($Path -match '[\x00-\x1f]') { return "control character in '$Path'" }
    if ($Path -match '[\*\?<>|";\[\]]') { return "wildcard or shell character in '$Path'" }
    if ($Path.Substring(2) -match ':') { return "stream or device syntax (a colon after the drive) in '$Path'" }
    if ($Path -match '(^|[\\/])\.\.([\\/]|$)') { return "dot-dot segment in '$Path'" }
    return ''
}

function ConvertTo-CoderWinPath {
    param([Parameter(Mandatory)][string]$Path)
    return (($Path -replace '/', '\').TrimEnd('\'))
}

function ConvertFrom-JsonCompat {
    # PowerShell 7 refuses a document with case-variant keys unless -AsHashtable; 5.1 tolerates it (the same
    # reason Get-CoderBaseUrl in fleet-lib.ps1 branches). Returns a hashtable (7) or a PSCustomObject (5.1).
    param([Parameter(Mandatory)][string]$Text)
    if ($PSVersionTable.PSVersion.Major -ge 6) { return ($Text | ConvertFrom-Json -AsHashtable -ErrorAction Stop) }
    return ($Text | ConvertFrom-Json -ErrorAction Stop)
}

function Get-JsonKeys {
    param($Obj)
    if ($null -eq $Obj) { return @() }
    if ($Obj -is [System.Collections.IDictionary]) { return @($Obj.Keys | ForEach-Object { [string]$_ }) }
    if ($Obj -is [pscustomobject]) { return @($Obj.PSObject.Properties | ForEach-Object { $_.Name }) }
    return @()
}

function Get-JsonMember {
    param($Obj, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [System.Collections.IDictionary]) { return $Obj[$Name] }
    $p = $Obj.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Read-CoderToolchainManifest {
    # Strict reader of configs/coder-toolchain.json. THROWS on a missing/garbled file, a missing or unknown key,
    # or a path that fails Test-CoderToolchainPathText: a manifest that cannot be trusted grants nothing.
    # Returns @{ OpencodePackageDir; OpencodeShimDir; OpencodeExe; PluginPackage; PluginVersion; MachineExes
    # (ordered name -> path); DocsetRelative } with backslash paths.
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "coder toolchain manifest not found: $Path" }
    $m = $null
    try { $m = ConvertFrom-JsonCompat -Text ([IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false))) } catch { throw "coder toolchain manifest is not valid JSON ($Path): $($_.Exception.Message)" }
    $allowed = @('opencode_package_dir', 'opencode_shim_dir', 'opencode_plugin_package', 'opencode_plugin_version', 'machine_exes', 'docset_dir_relative', 'note')
    foreach ($k in (Get-JsonKeys $m)) { if ($allowed -cnotcontains $k) { throw "coder toolchain manifest: unknown key '$k' (a typo here would silently drop a grant)" } }
    foreach ($k in 'opencode_package_dir', 'opencode_shim_dir', 'opencode_plugin_package', 'opencode_plugin_version', 'machine_exes', 'docset_dir_relative') {
        if ($null -eq (Get-JsonMember $m $k)) { throw "coder toolchain manifest: required key '$k' is missing" }
    }
    foreach ($k in 'opencode_package_dir', 'opencode_shim_dir') {
        $why = Test-CoderToolchainPathText ([string](Get-JsonMember $m $k))
        if ($why) { throw "coder toolchain manifest: $k - $why" }
    }
    $rel = [string](Get-JsonMember $m 'docset_dir_relative')
    if ($rel -notmatch '^[A-Za-z0-9_.-]+([\\/][A-Za-z0-9_.-]+)*$' -or $rel -match '(^|[\\/])\.\.?([\\/]|$)') { throw "coder toolchain manifest: docset_dir_relative '$rel' is not a plain relative path" }
    $plugVer = [string](Get-JsonMember $m 'opencode_plugin_version')
    if ($plugVer -notmatch '^\d+\.\d+\.\d+$') { throw "coder toolchain manifest: opencode_plugin_version '$plugVer' is not an exact x.y.z version" }
    $plugPkg = [string](Get-JsonMember $m 'opencode_plugin_package')
    if ($plugPkg -notmatch '^@?[a-z0-9][a-z0-9._-]*(/[a-z0-9][a-z0-9._-]*)?$') { throw "coder toolchain manifest: opencode_plugin_package '$plugPkg' is not a package name" }
    $mx = Get-JsonMember $m 'machine_exes'
    $exes = [ordered]@{}
    $want = 'node', 'git', 'git_bash', 'python'
    foreach ($k in (Get-JsonKeys $mx)) { if ($want -cnotcontains $k) { throw "coder toolchain manifest: machine_exes has unknown key '$k'" } }
    foreach ($k in $want) {
        $v = [string](Get-JsonMember $mx $k)
        $why = Test-CoderToolchainPathText $v
        if ($why) { throw "coder toolchain manifest: machine_exes.$k - $why" }
        $exes[$k] = ConvertTo-CoderWinPath $v
    }
    $pkg = ConvertTo-CoderWinPath ([string](Get-JsonMember $m 'opencode_package_dir'))
    return [pscustomobject]@{
        OpencodePackageDir = $pkg
        OpencodeShimDir    = ConvertTo-CoderWinPath ([string](Get-JsonMember $m 'opencode_shim_dir'))
        OpencodeExe        = (Join-Path $pkg 'bin\opencode.exe')
        PluginPackage      = $plugPkg
        PluginVersion      = $plugVer
        MachineExes        = $exes
        DocsetRelative     = ($rel -replace '/', '\')
    }
}

# ---- the read grants --------------------------------------------------------------------------------------

function Test-CoderGrantAllowed {
    # PURE. Returns '' when granting the coder read on $Path is allowed, else the reason. Refuses a path that
    # EQUALS or CONTAINS (so an inheritable grant would reach) any never-grant path, a path inside certs, a
    # path that names a secret folder component, and the operator's profile root or its AppData roots.
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Exclusions,
        [string]$OperatorProfile = ''
    )
    $norm = { param($p) ((($p -replace '/', '\').TrimEnd('\'))).ToLowerInvariant() }
    $n = & $norm $Path
    $why = Test-CoderToolchainPathText $Path
    if ($why) { return $why }
    foreach ($e in @($Exclusions | Where-Object { $_ })) {
        $en = & $norm $e
        if ($n -eq $en) { return "'$Path' is a never-grant path" }
        if ($en.StartsWith($n + '\')) { return "'$Path' contains the never-grant path '$e' (an inheritable grant would reach it)" }
    }
    foreach ($comp in ($n -split '\\')) {
        if ($comp -in '.ssh', '.aws', '.azure', '.gnupg', '.kube', '.docker', '.git-credentials', '.npmrc', '.netrc', 'certs', 'secrets', 'secret') { return "'$Path' names the secret folder '$comp'" }
    }
    if ($n -match '\\blarai(\\[^\\]+)*\\certs(\\|$)') { return "'$Path' is inside a certs folder" }
    if ($OperatorProfile) {
        $op = & $norm $OperatorProfile
        if ($n -eq $op) { return "'$Path' is the operator profile root" }
        foreach ($root in 'appdata', 'appdata\roaming', 'appdata\local', '.config') { if ($n -eq "$op\$root") { return "'$Path' is the operator's $root root" } }
    }
    return ''
}

function Get-CoderToolchainReadGrants {
    # PURE. The EXACT read-and-run grants the coder needs to run its tool chain, beyond Get-CoderCodeReadPaths.
    # Each: @{ Id; Path; Flags ('(OI)(CI)' inheritable, '' this folder only); Rights = 'RX'; Why }. Every entry
    # is validated by Test-CoderGrantAllowed; one that fails THROWS (a wrong list must not be partly applied).
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$AgenticRoot,
        [string]$BlarRoot = 'C:\Users\mrbla\blarai',
        [string]$OperatorProfile = 'C:\Users\mrbla'
    )
    $grants = @(
        [pscustomobject]@{ Id = 'opencode-package'; Path = $Manifest.OpencodePackageDir; Flags = '(OI)(CI)'; Rights = 'RX'; Why = 'the compiled opencode.exe the ACP client spawns' }
        [pscustomobject]@{ Id = 'opencode-shim-dir'; Path = $Manifest.OpencodeShimDir; Flags = ''; Rights = 'RX'; Why = 'this folder ONLY, so the coder can list the opencode shim names (where.exe); its children stay unreadable' }
        [pscustomobject]@{ Id = 'agentic-tools'; Path = (Join-Path $AgenticRoot 'tools'); Flags = '(OI)(CI)'; Rights = 'RX'; Why = 'tools/search_docs.py, the offline docset lookup the opencode tool runs' }
        [pscustomobject]@{ Id = 'docset'; Path = (Join-Path $BlarRoot $Manifest.DocsetRelative); Flags = '(OI)(CI)'; Rights = 'RX'; Why = 'the hash-pinned offline docset index the lookup reads' }
    )
    $excl = @(
        (Join-Path $BlarRoot 'certs'), $BlarRoot, $AgenticRoot,
        (Join-Path $env:LOCALAPPDATA 'BlarAI'), (Join-Path $OperatorProfile '.config\opencode'), (Join-Path $OperatorProfile '.ssh')
    )
    foreach ($g in $grants) {
        $why = Test-CoderGrantAllowed -Path $g.Path -Exclusions $excl -OperatorProfile $OperatorProfile
        # the shim dir lives under the operator's APPDATA\Roaming by construction; only its exact-root form is refused
        if ($why) { throw "coder toolchain grant '$($g.Id)' refused: $why" }
        $g.Path = ConvertTo-CoderWinPath $g.Path
    }
    return $grants
}

function Get-CoderToolchainPathPrefix {
    # PURE. The directories the coder-leg runner puts on the coder's PATH for a dispatch job so the ACP client
    # can resolve opencode (it resolves the compiled exe next to the shim). Exactly the manifest's shim dir.
    param([Parameter(Mandatory)]$Manifest)
    return @($Manifest.OpencodeShimDir)
}

function Get-CoderToolchainProbeExes {
    # PURE. The executables the toolchain probe runs (--version) as the coder: opencode plus the machine ones.
    param([Parameter(Mandatory)]$Manifest)
    $list = @($Manifest.OpencodeExe)
    foreach ($k in $Manifest.MachineExes.Keys) { $list += [string]$Manifest.MachineExes[$k] }
    return $list
}

# ---- the coder-owned opencode configuration ---------------------------------------------------------------

function Remove-JsonTopLevelProperty {
    # Remove ONE top-level property (key and value) from a JSON document by TEXT surgery, leaving every other
    # byte as it was: reserializing would depend on the shell (case-variant keys, escaping) and the installed
    # bytes would differ between PowerShell 5.1 and 7. THROWS unless the key occurs exactly once at depth 1.
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][string]$Name)
    $n = $Text.Length; $depth = 0; $i = 0
    $hits = New-Object System.Collections.ArrayList
    $skipValue = {
        param([int]$From)
        $j = $From
        while ($j -lt $n -and [char]::IsWhiteSpace($Text[$j])) { $j++ }
        if ($j -ge $n) { throw 'JSON ends where a value was expected' }
        $c0 = $Text[$j]
        if ($c0 -eq '{' -or $c0 -eq '[') {
            $d = 0; $inS = $false; $esc = $false
            while ($j -lt $n) {
                $c = $Text[$j]
                if ($inS) { if ($esc) { $esc = $false } elseif ($c -eq '\') { $esc = $true } elseif ($c -eq '"') { $inS = $false } }
                elseif ($c -eq '"') { $inS = $true }
                elseif ($c -eq '{' -or $c -eq '[') { $d++ }
                elseif ($c -eq '}' -or $c -eq ']') { $d--; if ($d -eq 0) { return ($j + 1) } }
                $j++
            }
            throw 'unterminated object or array'
        }
        if ($c0 -eq '"') {
            $j++; $esc = $false
            while ($j -lt $n) { $c = $Text[$j]; if ($esc) { $esc = $false } elseif ($c -eq '\') { $esc = $true } elseif ($c -eq '"') { return ($j + 1) }; $j++ }
            throw 'unterminated string'
        }
        while ($j -lt $n -and $Text[$j] -notin ',', '}', ']' -and -not [char]::IsWhiteSpace($Text[$j])) { $j++ }
        return $j
    }
    $inStr = $false; $esc = $false; $strStart = -1
    while ($i -lt $n) {
        $c = $Text[$i]
        if ($inStr) {
            if ($esc) { $esc = $false }
            elseif ($c -eq '\') { $esc = $true }
            elseif ($c -eq '"') {
                $inStr = $false
                if ($depth -eq 1) {
                    $k = $i + 1
                    while ($k -lt $n -and [char]::IsWhiteSpace($Text[$k])) { $k++ }
                    if ($k -lt $n -and $Text[$k] -eq ':') {
                        $key = $Text.Substring($strStart + 1, $i - $strStart - 1)
                        $end = & $skipValue ($k + 1)
                        if ($key -ceq $Name) { [void]$hits.Add(@{ Begin = $strStart; End = $end }) }
                        $i = $end; continue
                    }
                }
            }
            $i++; continue
        }
        if ($c -eq '"') { $inStr = $true; $strStart = $i }
        elseif ($c -eq '{' -or $c -eq '[') { $depth++ }
        elseif ($c -eq '}' -or $c -eq ']') { $depth-- }
        $i++
    }
    if ($hits.Count -ne 1) { throw "top-level property '$Name' occurs $($hits.Count) time(s) (exactly one expected)" }
    $s = [int]$hits[0].Begin; $e = [int]$hits[0].End
    # a following comma goes with the property (and the rest of its line); else the preceding comma does
    $k = $e
    while ($k -lt $n -and ($Text[$k] -eq ' ' -or $Text[$k] -eq "`t")) { $k++ }
    if ($k -lt $n -and $Text[$k] -eq ',') {
        $k++
        while ($k -lt $n -and ($Text[$k] -eq ' ' -or $Text[$k] -eq "`t")) { $k++ }
        if ($k -lt $n -and $Text[$k] -eq "`r") { $k++ }
        if ($k -lt $n -and $Text[$k] -eq "`n") { $k++ }
        $ls = $s
        while ($ls -gt 0 -and ($Text[$ls - 1] -eq ' ' -or $Text[$ls - 1] -eq "`t")) { $ls-- }
        return $Text.Substring(0, $ls) + $Text.Substring($k)
    }
    $p = $s - 1
    while ($p -ge 0 -and [char]::IsWhiteSpace($Text[$p])) { $p-- }
    if ($p -ge 0 -and $Text[$p] -eq ',') { return $Text.Substring(0, $p) + $Text.Substring($e) }
    return $Text.Substring(0, $s) + $Text.Substring($e)
}

function Get-CoderPermissionMap {
    # PURE. The permission block flattened to "category|pattern" -> value (case-sensitive keys: the document
    # carries case variants of the same pattern on purpose). A scalar category ("external_directory": "ask")
    # is "category|".
    param($Parsed)
    $map = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    $perm = Get-JsonMember $Parsed 'permission'
    foreach ($cat in (Get-JsonKeys $perm)) {
        $v = Get-JsonMember $perm $cat
        if ($v -is [string]) { $map["$cat|"] = $v; continue }
        foreach ($pat in (Get-JsonKeys $v)) { $map["$cat|$pat"] = [string](Get-JsonMember $v $pat) }
    }
    return $map
}

function Test-CoderOpencodeConfigSafe {
    # PURE verdict on the coder's opencode.json against the operator's source. Returns @{ Pass; Failed[] }.
    # Failed names: parse, mcp-present, plugin-declared, provider-not-loopback, credential-in-config,
    # autoupdate-not-disabled, share-not-disabled, permission-missing:<cat|pattern>, permission-weaker:<cat|pattern>.
    # Rule: every permission entry of the source that is not 'allow' must be present with the SAME value.
    param([Parameter(Mandatory)][string]$CoderText, [Parameter(Mandatory)][string]$OperatorText)
    $failed = New-Object System.Collections.ArrayList
    $c = $null; $o = $null
    try { $c = ConvertFrom-JsonCompat -Text $CoderText } catch { return [pscustomobject]@{ Pass = $false; Failed = @('parse-coder') } }
    try { $o = ConvertFrom-JsonCompat -Text $OperatorText } catch { return [pscustomobject]@{ Pass = $false; Failed = @('parse-operator') } }
    if ((Get-JsonKeys $c) -ccontains 'mcp') { [void]$failed.Add('mcp-present') }
    foreach ($k in 'plugin', 'plugins') { if ((Get-JsonKeys $c) -ccontains $k) { [void]$failed.Add('plugin-declared') } }
    foreach ($pn in (Get-JsonKeys (Get-JsonMember $c 'provider'))) {
        $prov = Get-JsonMember (Get-JsonMember $c 'provider') $pn
        $opts = Get-JsonMember $prov 'options'
        $url = [string](Get-JsonMember $opts 'baseURL')
        if ($url -notmatch '^http://(127\.0\.0\.1|localhost|\[::1\])(:\d{1,5})?(/|$)') { [void]$failed.Add("provider-not-loopback:$pn") }
        $ak = Get-JsonMember $opts 'apiKey'
        if ($null -ne $ak -and [string]$ak -cne 'local') { [void]$failed.Add("credential-in-config:provider.$pn.apiKey") }
        foreach ($ok in (Get-JsonKeys $opts)) {
            if ($ok -match '(?i)token|secret|password|passwd|authorization|bearer|credential' -and [string](Get-JsonMember $opts $ok)) { [void]$failed.Add("credential-in-config:provider.$pn.$ok") }
        }
    }
    if ($CoderText -match 'sk-[A-Za-z0-9]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{12,}|eyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY') { [void]$failed.Add('credential-in-config:token-shaped-text') }
    foreach ($flag in @(@('autoupdate', 'autoupdate-not-disabled'), @('share', 'share-not-disabled'))) {
        $ov = Get-JsonMember $o $flag[0]
        if ($null -ne $ov) {
            $cv = Get-JsonMember $c $flag[0]
            if ($null -eq $cv -or [string]$cv -cne [string]$ov) { [void]$failed.Add($flag[1]) }
        }
    }
    $om = Get-CoderPermissionMap $o; $cm = Get-CoderPermissionMap $c
    if ($om.Count -eq 0) { [void]$failed.Add('permission-missing:operator-source-has-no-permission-block') }
    foreach ($k in $om.Keys) {
        if ($om[$k] -ceq 'allow') { continue }
        if (-not $cm.ContainsKey($k)) { [void]$failed.Add("permission-missing:$k") }
        elseif ($cm[$k] -cne $om[$k]) { [void]$failed.Add("permission-weaker:$k") }
    }
    return [pscustomobject]@{ Pass = ($failed.Count -eq 0); Failed = @($failed) }
}

function ConvertTo-CoderOpencodeConfigText {
    # The coder's opencode.json text: the operator source with the MCP block removed (no browser tool: a new
    # capability starts denied). THROWS when the result fails Test-CoderOpencodeConfigSafe.
    param([Parameter(Mandatory)][string]$OperatorText)
    $text = $OperatorText
    $topKeys = Get-JsonKeys (ConvertFrom-JsonCompat -Text $OperatorText)
    if ($topKeys -ccontains 'mcp') { $text = Remove-JsonTopLevelProperty -Text $text -Name 'mcp' }
    $v = Test-CoderOpencodeConfigSafe -CoderText $text -OperatorText $OperatorText
    if (-not $v.Pass) { throw "the coder opencode config would be unsafe: $($v.Failed -join ', ')" }
    return $text
}

function New-CoderSearchDocsWrapperText {
    # The coder's copy of the opencode custom tool wrapper. It differs from the operator's in ONE place: the
    # usage log defaults to a folder under the CODER's own profile, so the lookup never needs write access to the
    # operator's state folder. An explicit BLARAI_RESEARCH_USAGE_LOG still wins.
    param([Parameter(Mandatory)][string]$AgenticRoot, [Parameter(Mandatory)]$Manifest)
    $imp = ((Join-Path $AgenticRoot 'configs\opencode-tools\search_docs.js') -replace '\\', '/')
    if ($imp -match '["`$\\\r\n]') { throw "agentic root '$AgenticRoot' cannot be embedded in the tool wrapper" }
    return @"
// search_docs.js - the restricted coder's opencode custom tool wrapper. GENERATED by provision-coder-setup.ps1
// (coder-setup-lib.ps1 New-CoderSearchDocsWrapperText); not edited by hand. Same tool as the operator's; the
// usage log defaults to the coder's OWN profile (no write access to the operator's state folder is granted).
import os from "node:os";
import path from "node:path";
import { tool } from "$($Manifest.PluginPackage)";
import { execute, DESCRIPTION } from "$imp";

if (!process.env.BLARAI_RESEARCH_USAGE_LOG) {
  process.env.BLARAI_RESEARCH_USAGE_LOG = path.join(os.homedir(), ".local", "share", "blarai-coder", "research-usage.jsonl");
}

export default tool({
  description: DESCRIPTION,
  args: {
    query: tool.schema.string().describe(
      "A concrete symbol (e.g. json.dumps), an exact error line (paste it whole), or a specific question."
    ),
    k: tool.schema.number().optional().describe("Max results to return (default 4)."),
  },
  execute: async (args) => execute(args),
});
"@
}

function Get-CoderGitConfigText {
    # The coder's global git config, at ~/.config/git/config (git's XDG location: it lives under the protected
    # .config folder, where the coder cannot replace it; a file in the profile root could be deleted and recreated
    # by the account that owns that folder). The coder runs git in worktrees that the OPERATOR created, and git
    # refuses a folder another account owns ("dubious ownership"). The runner's environment names the one worktree
    # for the git calls the runner makes, but opencode's shell gets a fixed environment, so the coder's global
    # config carries the answer too: safe.directory = <worktree base>/* , a prefix entry (git 2.46+) that matches
    # folders UNDER the worktree base and nothing else. Never '*', never a parent of the base.
    param([Parameter(Mandatory)][string]$WorktreeBase)
    $why = Test-CoderToolchainPathText $WorktreeBase
    if ($why) { throw "coder gitconfig: worktree base - $why" }
    $b = (($WorktreeBase -replace '\\', '/').TrimEnd('/'))
    # a prefix entry must name a dedicated folder: a drive root, or a top-level system/profile folder, is far too broad
    if ($b -match '^[A-Za-z]:$' -or $b -match '(?i)^[A-Za-z]:/(Users|Windows|Program Files|Program Files \(x86\)|ProgramData)(/[^/]+)?$') { throw "coder gitconfig: '$WorktreeBase' is too broad for a safe.directory prefix" }
    return (@('# generated by provision-coder-setup.ps1 (coder-setup-lib.ps1 Get-CoderGitConfigText); not edited by hand',
              '[safe]', "`tdirectory = $b/*", '[core]', "`tfsmonitor = false", '') -join "`n")
}

function Get-CoderOpencodeConfigPlan {
    # The files of the coder-owned opencode configuration, rendered from the repo (never from the operator's
    # profile). Returns objects @{ Rel; Bytes; Sha256 }. THROWS when a source is missing or the config is unsafe.
    # Get-CoderAgentsRulesText (coder-leg-queue.ps1) must be loaded by the caller.
    param([Parameter(Mandatory)][string]$AgenticRoot, [Parameter(Mandatory)]$Manifest, [string]$WorktreeBase = 'C:\blarai-fleet\worktrees')
    if (-not (Get-Command Get-CoderAgentsRulesText -ErrorAction SilentlyContinue)) { throw 'Get-CoderAgentsRulesText is not loaded (dot-source coder-leg-queue.ps1 first)' }
    $enc = [Text.UTF8Encoding]::new($false)
    $cfg = Join-Path $AgenticRoot 'configs'
    $files = New-Object System.Collections.ArrayList
    $add = { param([string]$Rel, [byte[]]$Bytes, [string]$Dir = 'config')
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $h = -join ($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) } finally { $sha.Dispose() }
        [void]$files.Add([pscustomobject]@{ Rel = $Rel; Dir = $Dir; Bytes = $Bytes; Sha256 = $h }) }
    $opText = [IO.File]::ReadAllText((Join-Path $cfg 'opencode.json'), $enc)
    & $add 'opencode.json' ($enc.GetBytes((ConvertTo-CoderOpencodeConfigText -OperatorText $opText)))
    $agents = [IO.File]::ReadAllText((Join-Path $cfg 'AGENTS.md'), $enc)
    & $add 'AGENTS.md' ($enc.GetBytes((Get-CoderAgentsRulesText -Text $agents -Containment 'restricted_account')))
    & $add 'package.json' ($enc.GetBytes((@('{', '  "dependencies": {', ('    "' + $Manifest.PluginPackage + '": "' + $Manifest.PluginVersion + '"'), '  }', '}', '') -join "`n")))
    foreach ($p in 'command-timeout.js', 'path-normalize.js') {
        $src = Join-Path $cfg "opencode-plugins\$p"
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { throw "plugin source missing: $src" }
        & $add "plugin\$p" ([IO.File]::ReadAllBytes($src))
    }
    & $add 'tool\search_docs.js' ($enc.GetBytes((New-CoderSearchDocsWrapperText -AgenticRoot $AgenticRoot -Manifest $Manifest)))
    & $add 'git\config' ($enc.GetBytes((Get-CoderGitConfigText -WorktreeBase $WorktreeBase))) 'xdg'
    return @($files)
}

function Get-CoderOpencodeConfigDir {
    param([Parameter(Mandatory)][string]$ProfilePath)
    return (Join-Path $ProfilePath '.config\opencode')
}

function Get-CoderProfilePath {
    # The coder's profile folder from its SID (Win32_UserProfile). $null when the account has never logged on
    # (Windows creates the profile at first logon). -Lookup is a test seam: { param($sid) '<path>' }.
    param([Parameter(Mandatory)][string]$Sid, [scriptblock]$Lookup = $null)
    if ($Sid -notmatch '^S-1-5-21-\d+-\d+-\d+-\d+$') { throw "not a local account SID: '$Sid'" }
    if ($Lookup) { return (& $Lookup $Sid) }
    $p = Get-CimInstance -ClassName Win32_UserProfile -Filter "SID='$Sid'" -ErrorAction Stop
    if (-not $p) { return $null }
    return [string]$p.LocalPath
}

# ---- installing it ------------------------------------------------------------------------------------------

function Get-CoderConfigWriteRightsMask {
    # FileSystemRights bits that mean "can change or replace this object" (data/attribute write, delete, and
    # the rights to rewrite its own access list or owner).
    $r = [Security.AccessControl.FileSystemRights]
    return [int]($r::WriteData -bor $r::AppendData -bor $r::WriteExtendedAttributes -bor $r::WriteAttributes -bor $r::Delete -bor $r::DeleteSubdirectoriesAndFiles -bor $r::ChangePermissions -bor $r::TakeOwnership)
}

function Test-RulesGrantWrite {
    # PURE. $Rules: objects @{ Sid; Rights (int); Type ('Allow'|'Deny') }. Returns the SIDs of $WatchSids that an
    # Allow rule gives a write-capable right (an explicit Deny of that bit by the same SID cancels it).
    param([AllowEmptyCollection()]$Rules, [Parameter(Mandatory)][string[]]$WatchSids)
    $mask = Get-CoderConfigWriteRightsMask
    $hit = New-Object System.Collections.ArrayList
    foreach ($sid in $WatchSids) {
        $allow = 0; $deny = 0
        foreach ($r in @($Rules)) {
            if ($r.Sid -ne $sid) { continue }
            if ($r.Type -eq 'Allow') { $allow = $allow -bor [int]$r.Rights } else { $deny = $deny -bor [int]$r.Rights }
        }
        if ((($allow -band (-bnot $deny)) -band $mask) -ne 0) { [void]$hit.Add($sid) }
    }
    return @($hit)
}

function Get-ObjectAccessRules {
    # The access rules of a file or folder as simple objects for Test-RulesGrantWrite (inherited ones included).
    param([Parameter(Mandatory)][string]$Path)
    $acl = Get-Acl -LiteralPath $Path
    return @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | ForEach-Object {
        [pscustomobject]@{ Sid = $_.IdentityReference.Value; Rights = [int]$_.FileSystemRights; Type = [string]$_.AccessControlType }
    })
}

function Get-CoderConfigWatchSids {
    # The SIDs whose write access to the installed config counts as "the coder can change it": the coder and the
    # groups every local account belongs to.
    param([Parameter(Mandatory)][string]$CoderSid)
    return @($CoderSid, 'S-1-5-32-545', 'S-1-5-11', 'S-1-1-0')
}

function Get-CoderConfigItemBase {
    # The folder a plan item is relative to: the opencode config folder ('config') or its parent ~/.config ('xdg',
    # for git/config).
    param([Parameter(Mandatory)][string]$ConfigDir, [Parameter(Mandatory)]$Item)
    if ($Item.Dir -eq 'xdg') { return (Split-Path $ConfigDir -Parent) }
    return $ConfigDir
}

function Test-PathIsLink {
    # $true when $Path exists and is a link (junction or symbolic link); $false when it does not exist. Any other
    # failure to read the attributes THROWS: a check that cannot see its subject must refuse, not pass.
    param([Parameter(Mandatory)][string]$Path)
    try { $a = [IO.File]::GetAttributes($Path) }
    catch [IO.FileNotFoundException], [IO.DirectoryNotFoundException] { return $false }
    return [bool]($a -band [IO.FileAttributes]::ReparsePoint)
}

function Test-CoderConfigLeaf {
    # A planned file location: a regular file or absent, and no component under $ConfigDir is a link.
    param([Parameter(Mandatory)][string]$ConfigDir, [Parameter(Mandatory)][string]$Rel)
    # The folder itself and its parent are checked too: the coder can rename a protected folder out of its parent
    # and put a link in its place, and the operator-side undo would then delete through it.
    foreach ($anchor in @((Split-Path $ConfigDir -Parent), $ConfigDir)) {
        if ($anchor -and (Test-PathIsLink -Path $anchor)) { return "link at '$anchor'" }
    }
    $cur = $ConfigDir
    foreach ($seg in ($Rel -split '\\')) {
        $cur = Join-Path $cur $seg
        if (Test-PathIsLink -Path $cur) { return "link at '$cur'" }
    }
    return ''
}

function Initialize-CoderHandleStamp {
    # Defines [CoderHandleStamp] once per session (lazy: nothing is compiled when the library is only dot-sourced,
    # and a second call is a no-op). The class opens a file or folder WITHOUT following a link, refuses a reparse
    # point, and applies owner + access list to the OPEN HANDLE, so the object that was checked is the object that
    # is changed whatever happens to the path afterwards.
    if ('CoderHandleStamp' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

public static class CoderHandleStamp {
    [StructLayout(LayoutKind.Sequential)] struct FILE_ATTRIBUTE_TAG_INFO { public uint FileAttributes; public uint ReparseTag; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr sa, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetFileInformationByHandleEx(SafeFileHandle h, int cls, out FILE_ATTRIBUTE_TAG_INFO info, uint size);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern uint GetFinalPathNameByHandleW(SafeFileHandle h, StringBuilder sb, uint len, uint flags);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool GetSecurityDescriptorOwner(IntPtr sd, out IntPtr owner, out bool defaulted);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool GetSecurityDescriptorDacl(IntPtr sd, out bool present, out IntPtr dacl, out bool defaulted);
    [DllImport("advapi32.dll")]
    static extern uint SetSecurityInfo(SafeFileHandle h, int objectType, uint info, IntPtr owner, IntPtr group, IntPtr dacl, IntPtr sacl);

    const uint READ_CONTROL = 0x20000, WRITE_DAC = 0x40000, WRITE_OWNER = 0x80000;
    const uint SHARE_ALL = 7, SHARE_READ_WRITE = 3, OPEN_EXISTING = 3, FILE_LIST_DIRECTORY = 1;
    const uint BACKUP_SEMANTICS = 0x02000000, OPEN_REPARSE_POINT = 0x00200000;
    const uint ATTR_REPARSE_POINT = 0x400;
    const uint OWNER_INFO = 1, DACL_INFO = 4, PROTECTED_DACL_INFO = 0x80000000;

    public static SafeFileHandle Open(string path) { return Open(path, false, true); }

    // Opens path itself (never its target). Throws when it cannot be opened or when it is a reparse point.
    // hold: also ask for READ_DATA and refuse sharing of DELETE (unless allowDelete), which keeps the object AND its
    // ancestors from being renamed or removed while the handle stays open.
    public static SafeFileHandle Open(string path, bool hold, bool allowDelete) {
        uint access = READ_CONTROL | WRITE_DAC | WRITE_OWNER | (hold ? FILE_LIST_DIRECTORY : 0);
        uint share = (hold && !allowDelete) ? SHARE_READ_WRITE : SHARE_ALL;
        SafeFileHandle h = CreateFileW(path, access, share, IntPtr.Zero, OPEN_EXISTING,
                                       BACKUP_SEMANTICS | OPEN_REPARSE_POINT, IntPtr.Zero);
        if (h.IsInvalid) { int e = Marshal.GetLastWin32Error(); throw new IOException("cannot open '" + path + "' for security change: " + "Win32 error " + e); }
        try {
            FILE_ATTRIBUTE_TAG_INFO info;
            if (!GetFileInformationByHandleEx(h, 9, out info, (uint)Marshal.SizeOf(typeof(FILE_ATTRIBUTE_TAG_INFO)))) {
                int e = Marshal.GetLastWin32Error(); throw new IOException("cannot read the attributes of '" + path + "': " + "Win32 error " + e);
            }
            if ((info.FileAttributes & ATTR_REPARSE_POINT) != 0) throw new IOException("refusing: '" + path + "' is a reparse point (link)");
        } catch { h.Dispose(); throw; }
        return h;
    }

    // The path the OS resolves this handle to NOW (it follows a rename of the object or of an ancestor), without the \\?\ prefix.
    public static string FinalPath(SafeFileHandle h) {
        StringBuilder sb = new StringBuilder(1024);
        uint n = GetFinalPathNameByHandleW(h, sb, (uint)sb.Capacity, 0);
        if (n == 0 || n >= sb.Capacity) { int e = Marshal.GetLastWin32Error(); throw new IOException("cannot resolve the path of an open handle: Win32 error " + e); }
        string s = sb.ToString();
        return s.StartsWith("\\\\?\\") ? s.Substring(4) : s;
    }

    // Applies the DACL (always protected) and, when setOwner, the owner of the self-relative descriptor sd to the handle.
    public static void Apply(SafeFileHandle h, byte[] sd, bool setOwner) {
        IntPtr p = Marshal.AllocHGlobal(sd.Length);
        try {
            Marshal.Copy(sd, 0, p, sd.Length);
            IntPtr owner = IntPtr.Zero, dacl = IntPtr.Zero; bool present, defaulted;
            if (!GetSecurityDescriptorDacl(p, out present, out dacl, out defaulted) || !present || dacl == IntPtr.Zero)
                throw new IOException("the descriptor carries no access list");
            uint info = DACL_INFO | PROTECTED_DACL_INFO;
            if (setOwner) {
                if (!GetSecurityDescriptorOwner(p, out owner, out defaulted) || owner == IntPtr.Zero)
                    throw new IOException("an owner was requested but the descriptor carries none");
                info |= OWNER_INFO;
            }
            uint rc = SetSecurityInfo(h, 1, info, owner, IntPtr.Zero, dacl, IntPtr.Zero);
            if (rc != 0) throw new IOException("SetSecurityInfo failed: " + "Win32 error " + rc);
        } finally { Marshal.FreeHGlobal(p); }
    }
}
'@
}

function Set-CoderSecurityByHandle {
    # Applies the access list $Sddl (and, with -SetOwner, its owner) to the object AT $Path through an open handle:
    # the object is opened without following a link, a reparse point is refused, and the change goes to the handle,
    # so a path swapped for a link after the open changes nothing outside the opened object. Throws on every failure.
    # -AfterOpen is a test seam run between the open and the apply (the window a path-based call leaves open).
    # -Handle: an already-open, already-verified handle of the object (from Add-CoderHeldDir); it is used as is and left open.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Sddl, [switch]$SetOwner, [scriptblock]$AfterOpen = $null,
          [Microsoft.Win32.SafeHandles.SafeFileHandle]$Handle = $null)
    Initialize-CoderHandleStamp
    $raw = [Security.AccessControl.RawSecurityDescriptor]::new($Sddl)
    $bytes = New-Object byte[] $raw.BinaryLength
    $raw.GetBinaryForm($bytes, 0)
    $h = if ($Handle) { $Handle } else { [CoderHandleStamp]::Open($Path) }
    try {
        if ($AfterOpen) { & $AfterOpen }
        [CoderHandleStamp]::Apply($h, $bytes, [bool]$SetOwner)
    } finally { if (-not $Handle) { $h.Dispose() } }
}

# ---- a verified chain of held folder handles ---------------------------------------------------------------
# A handle on the final component alone does not say where its ANCESTORS lead: a parent swapped for a link makes a
# real folder behind it look right. The chain below opens the profile root and then each folder under it, parents
# first; every open refuses a link and must resolve (GetFinalPathNameByHandle) to exactly the expected path, and
# every handle is held WITHOUT sharing delete, so the OS refuses to rename or remove a held folder or any ancestor
# of it. Assert-CoderHeldChain re-resolves every held handle and refuses when one has moved, before anything is
# created, stamped or written. A folder not yet opened can still be swapped: that is caught by its own open.

$script:CoderHoldAllowsDelete = $false   # test hook: lets a test defeat the OS hold to prove the re-resolve check on its own

function New-CoderHeldChain { return , (New-Object System.Collections.ArrayList) }

function Add-CoderHeldDir {
    # Opens $Path (a link is refused), requires it to resolve to the expected path, holds the handle and returns the
    # chain entry @{ Path; Final; Handle }. Expected: -ParentEntry's final path + the leaf name, or for the first
    # entry the full path itself. Re-checks the chain first, so nothing is opened under a parent that has moved.
    param([Parameter(Mandatory)]$Chain, [Parameter(Mandatory)][string]$Path, $ParentEntry = $null)
    Initialize-CoderHandleStamp
    Assert-CoderHeldChain -Chain $Chain
    $expected = if ($ParentEntry) { Join-Path $ParentEntry.Final (Split-Path $Path -Leaf) } else { [IO.Path]::GetFullPath($Path).TrimEnd('\') }
    $h = [CoderHandleStamp]::Open($Path, $true, $script:CoderHoldAllowsDelete)
    try {
        $final = [CoderHandleStamp]::FinalPath($h)
        if ($final.TrimEnd('\') -ine $expected.TrimEnd('\')) { throw "refusing: '$Path' resolves to '$final', expected '$expected' (a folder above it is a link or was replaced)" }
    } catch { $h.Dispose(); throw }
    $e = [pscustomobject]@{ Path = $Path; Final = $final.TrimEnd('\'); Handle = $h }
    [void]$Chain.Add($e)
    return $e
}

function Assert-CoderHeldChain {
    # Throws when any held folder now resolves somewhere else than where it was verified (renamed, or an ancestor
    # renamed/replaced). Called before every create, stamp and file write below the chain.
    param([Parameter(Mandatory)]$Chain)
    foreach ($e in $Chain) {
        $now = [CoderHandleStamp]::FinalPath($e.Handle).TrimEnd('\')
        if ($now -ine $e.Final) { throw "refusing: held folder '$($e.Path)' moved from '$($e.Final)' to '$now' (it or an ancestor was renamed or replaced)" }
    }
}

function Close-CoderHeldChain {
    param([Parameter(Mandatory)]$Chain)
    foreach ($e in $Chain) { try { $e.Handle.Dispose() } catch { } }
    $Chain.Clear()
}

function Protect-CoderConfigObject {
    # Replace the whole access list with an explicit, protected one: Administrators, SYSTEM and the operator full
    # control; the coder read-and-run (0x1200a9 = read + execute) unless -CoderMask says otherwise (the one
    # writable folder, node_modules, gets Modify). Nothing is inherited and nothing is left over from before: a
    # stray entry (a group granted Modify, an old coder entry) is gone after this call. A folder's entries inherit
    # to what it will hold (OICI). -SetOwner makes the Administrators group the OWNER, so the coder cannot rewrite
    # the list as the owner. SIDs are validated before they go into the descriptor text. The list is applied to an
    # open handle of the object itself (Set-CoderSecurityByHandle), never to a path: a link is refused and a path
    # swapped for a link mid-call changes nothing outside the opened object.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$CoderSid, [Parameter(Mandatory)][string]$OperatorSid,
          [switch]$IsDir, [switch]$SetOwner, [string]$CoderMask = '0x1200a9', [Microsoft.Win32.SafeHandles.SafeFileHandle]$Handle = $null)
    foreach ($s in $CoderSid, $OperatorSid) { if ($s -notmatch '^S-1-\d+(-\d+){1,14}$') { throw "not a SID: '$s'" } }
    if ($CoderSid -eq $OperatorSid) { throw 'the coder SID and the operator SID are the same account: refusing' }
    if ($CoderMask -notin '0x1200a9', '0x1301bf') { throw "unexpected coder access mask '$CoderMask'" }
    $inh = if ($IsDir) { 'OICI' } else { '' }
    $owner = if ($SetOwner) { 'O:BA' } else { '' }
    $sddl = "${owner}D:P(A;${inh};FA;;;BA)(A;${inh};FA;;;SY)(A;${inh};FA;;;${OperatorSid})(A;${inh};${CoderMask};;;${CoderSid})"
    Set-CoderSecurityByHandle -Path $Path -Sddl $sddl -SetOwner:$SetOwner -Handle $Handle
}

function Assert-CoderDirNotLink {
    # Throws when $Path exists and is a link (junction or symbolic link): an operation that FOLLOWS the path (a
    # create, an open without the reparse flag) would act on the link's target.
    param([Parameter(Mandatory)][string]$Path, [ValidateSet('before', 'after')][string]$When = 'before')
    if (Test-PathIsLink -Path $Path) {
        $target = try { (Get-Item -LiteralPath $Path -Force -ErrorAction Stop).Target -join ', ' } catch { 'unreadable' }
        throw "refusing: '$Path' is a link to '$target' (found $When the access list was applied)"
    }
}

function Protect-CoderConfigDir {
    # Protect-CoderConfigObject for one config folder (node_modules gets the coder Modify mask, every other folder
    # read-and-run), with a link check before and after the list is applied.
    # -Handle: the verified handle of this folder (Add-CoderHeldDir); the list is applied to it.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$CoderSid, [Parameter(Mandatory)][string]$OperatorSid,
          [Microsoft.Win32.SafeHandles.SafeFileHandle]$Handle = $null)
    Assert-CoderDirNotLink -Path $Path -When 'before'
    if ((Split-Path $Path -Leaf) -eq 'node_modules') { Protect-CoderConfigObject -Path $Path -CoderSid $CoderSid -OperatorSid $OperatorSid -IsDir -SetOwner -CoderMask '0x1301bf' -Handle $Handle }
    else { Protect-CoderConfigObject -Path $Path -CoderSid $CoderSid -OperatorSid $OperatorSid -IsDir -SetOwner -Handle $Handle }
    Assert-CoderDirNotLink -Path $Path -When 'after'
}

function Install-CoderOpencodeConfig {
    # Write the planned files under $ConfigDir (idempotent: an identical file is left alone) and protect every file
    # and every folder on the way: ~/.config, the opencode folder, plugin/, tool/ and git/ are read-and-run for the
    # coder and owned by Administrators (it cannot create, replace, rename or delete anything in them); the one
    # exception is node_modules, which opencode fills on first start (coder Modify). Refuses a link anywhere on the
    # way. Returns @{ Written[]; Unchanged[] }.
    param(
        [Parameter(Mandatory)][string]$ConfigDir, [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$CoderSid, [Parameter(Mandatory)][string]$OperatorSid,
        [scriptblock]$Out = $null,
        [scriptblock]$BeforeCreate = $null,   # test seam: runs with the folder about to be created, after the chain was verified
        [scriptblock]$BeforeFileWrite = $null # test seam: runs with the file about to be written, before the chain is re-verified
    )
    $say = { param($m) if ($Out) { & $Out $m } }
    $xdg = Split-Path $ConfigDir -Parent
    $profileRoot = Split-Path $xdg -Parent
    if (-not (Test-Path -LiteralPath $profileRoot -PathType Container)) { throw "profile folder '$profileRoot' does not exist" }
    $dirs = @($xdg, $ConfigDir, (Join-Path $ConfigDir 'plugin'), (Join-Path $ConfigDir 'tool'), (Join-Path $xdg 'git'), (Join-Path $ConfigDir 'node_modules'))
    # The profile root and every folder under it are opened parents-first into ONE verified chain of held handles
    # (see Add-CoderHeldDir): a link, or a folder that does not resolve to where it should, is refused before anything
    # is created, stamped or written below it. Each folder is protected the moment it exists, through its own held
    # handle, so the coder (who owns its profile root until then) cannot swap a protected folder while the files are
    # written. The chain is re-checked before every create and every file write.
    $chain = New-CoderHeldChain
    $written = @(); $same = @()
    try {
        $entries = @{}
        $entries[$profileRoot] = Add-CoderHeldDir -Chain $chain -Path $profileRoot
        foreach ($d in $dirs) {
            $parent = $entries[(Split-Path $d -Parent)]
            Assert-CoderHeldChain -Chain $chain
            if ($BeforeCreate) { & $BeforeCreate $d }
            Assert-CoderHeldChain -Chain $chain
            if (Test-PathIsLink -Path $d) { throw "refusing: '$d' is a link" }
            if (-not (Test-Path -LiteralPath $d)) { [void][IO.Directory]::CreateDirectory($d) }
            $entries[$d] = Add-CoderHeldDir -Chain $chain -Path $d -ParentEntry $parent
            Protect-CoderConfigDir -Path $d -CoderSid $CoderSid -OperatorSid $OperatorSid -Handle $entries[$d].Handle
        }
        foreach ($f in $Plan) {
            $base = Get-CoderConfigItemBase -ConfigDir $ConfigDir -Item $f
            $why = Test-CoderConfigLeaf -ConfigDir $base -Rel $f.Rel
            if ($why) { throw "refusing to write '$($f.Rel)': $why" }
            $dest = Join-Path $base $f.Rel
            $cur = $null
            if (Test-Path -LiteralPath $dest -PathType Leaf) {
                $sha = [Security.Cryptography.SHA256]::Create()
                try { $cur = -join ($sha.ComputeHash([IO.File]::ReadAllBytes($dest)) | ForEach-Object { $_.ToString('x2') }) } finally { $sha.Dispose() }
            }
            if ($cur -ceq $f.Sha256) { $same += $f.Rel } else {
                $tmp = "$dest.tmp-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
                if ($BeforeFileWrite) { & $BeforeFileWrite $dest }
                Assert-CoderHeldChain -Chain $chain
                [IO.File]::WriteAllBytes($tmp, $f.Bytes)
                Protect-CoderConfigObject -Path $tmp -CoderSid $CoderSid -OperatorSid $OperatorSid -SetOwner
                Assert-CoderHeldChain -Chain $chain
                Move-Item -LiteralPath $tmp -Destination $dest -Force
                $written += $f.Rel
            }
            # the list is (re)applied on every run, so a file whose list drifted is repaired even when its bytes match
            Assert-CoderHeldChain -Chain $chain
            Protect-CoderConfigObject -Path $dest -CoderSid $CoderSid -OperatorSid $OperatorSid -SetOwner
            & $say "  config $($f.Rel): $(if ($cur -ceq $f.Sha256) { 'unchanged' } else { 'written' }), protected"
        }
        # folders last: once the parents are read-only for the coder nothing more is written below them
        Assert-CoderHeldChain -Chain $chain
        foreach ($d in $dirs) { Protect-CoderConfigDir -Path $d -CoderSid $CoderSid -OperatorSid $OperatorSid -Handle $entries[$d].Handle }
    } finally { Close-CoderHeldChain -Chain $chain }
    return @{ Written = $written; Unchanged = $same }
}

function Remove-CoderOpencodeConfig {
    # The targeted undo of Install-CoderOpencodeConfig: delete exactly the planned files (never a link), then the
    # plugin/ and tool/ folders if they are empty. node_modules and anything opencode itself wrote stay. Returns
    # the relative names removed.
    param([Parameter(Mandatory)][string]$ConfigDir, [Parameter(Mandatory)]$Plan, [scriptblock]$Out = $null)
    $removed = @()
    foreach ($f in $Plan) {
        $base = Get-CoderConfigItemBase -ConfigDir $ConfigDir -Item $f
        $why = Test-CoderConfigLeaf -ConfigDir $base -Rel $f.Rel
        if ($why) { if ($Out) { & $Out "  not touching '$($f.Rel)': $why" }; continue }
        $p = Join-Path $base $f.Rel
        if (Test-Path -LiteralPath $p -PathType Leaf) { Remove-Item -LiteralPath $p -Force -ErrorAction Stop; $removed += $f.Rel }
    }
    foreach ($p in @((Join-Path $ConfigDir 'plugin'), (Join-Path $ConfigDir 'tool'), (Join-Path (Split-Path $ConfigDir -Parent) 'git'))) {
        if ((Test-Path -LiteralPath $p) -and -not (Test-PathIsLink -Path $p) -and @(Get-ChildItem -LiteralPath $p -Force).Count -eq 0) { Remove-Item -LiteralPath $p -Force }
    }
    return $removed
}

function Get-ObjectOwnerSid {
    param([Parameter(Mandatory)][string]$Path)
    return ((Get-Acl -LiteralPath $Path).GetOwner([Security.Principal.SecurityIdentifier])).Value
}

function Test-CoderOpencodeConfigInstalled {
    # Operator-side verdict on an installed configuration. Returns @{ Pass; Failed[] }. Failed names:
    # missing:<rel>, modified:<rel>, link:<rel>, unexpected-file:<rel>, writable-by-coder:<rel>, owned-by-coder:<rel>.
    # The folders ~/.config, opencode, plugin, tool and git must be unwritable for the coder and not owned by it
    # (an owner can rewrite the list); node_modules must exist (opencode fills it).
    param([Parameter(Mandatory)][string]$ConfigDir, [Parameter(Mandatory)]$Plan, [Parameter(Mandatory)][string]$CoderSid, [scriptblock]$ReadRules = $null, [scriptblock]$ReadOwner = $null)
    $failed = New-Object System.Collections.ArrayList
    $watch = Get-CoderConfigWatchSids -CoderSid $CoderSid
    $rules = if ($ReadRules) { $ReadRules } else { { param($p) Get-ObjectAccessRules -Path $p } }
    $owner = if ($ReadOwner) { $ReadOwner } else { { param($p) Get-ObjectOwnerSid -Path $p } }
    foreach ($f in $Plan) {
        $base = Get-CoderConfigItemBase -ConfigDir $ConfigDir -Item $f
        $why = Test-CoderConfigLeaf -ConfigDir $base -Rel $f.Rel
        if ($why) { [void]$failed.Add("link:$($f.Rel)"); continue }
        $p = Join-Path $base $f.Rel
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { [void]$failed.Add("missing:$($f.Rel)"); continue }
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $h = -join ($sha.ComputeHash([IO.File]::ReadAllBytes($p)) | ForEach-Object { $_.ToString('x2') }) } finally { $sha.Dispose() }
        if ($h -cne $f.Sha256) { [void]$failed.Add("modified:$($f.Rel)") }
        if (@(Test-RulesGrantWrite -Rules (& $rules $p) -WatchSids $watch).Count -gt 0) { [void]$failed.Add("writable-by-coder:$($f.Rel)") }
        if ((& $owner $p) -eq $CoderSid) { [void]$failed.Add("owned-by-coder:$($f.Rel)") }
    }
    $xdg = Split-Path $ConfigDir -Parent
    foreach ($dp in @($xdg, $ConfigDir, (Join-Path $ConfigDir 'plugin'), (Join-Path $ConfigDir 'tool'), (Join-Path $xdg 'git'))) {
        $rel = if ($dp -eq $xdg) { '.config' } elseif ($dp -eq $ConfigDir) { 'opencode' } elseif ($dp -like "$ConfigDir\*") { Split-Path $dp -Leaf } else { 'git' }
        if (-not (Test-Path -LiteralPath $dp -PathType Container)) { [void]$failed.Add("missing:$rel"); continue }
        if (Test-PathIsLink -Path $dp) { [void]$failed.Add("link:$rel"); continue }
        if (@(Test-RulesGrantWrite -Rules (& $rules $dp) -WatchSids $watch).Count -gt 0) { [void]$failed.Add("writable-by-coder:$rel") }
        if ((& $owner $dp) -eq $CoderSid) { [void]$failed.Add("owned-by-coder:$rel") }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $ConfigDir 'node_modules') -PathType Container)) { [void]$failed.Add('missing:node_modules') }
    foreach ($d in 'plugin', 'tool') {
        $dp = Join-Path $ConfigDir $d
        if (-not (Test-Path -LiteralPath $dp -PathType Container)) { continue }
        $planned = @($Plan | Where-Object { $_.Dir -ne 'xdg' -and $_.Rel -like "$d\*" } | ForEach-Object { Split-Path $_.Rel -Leaf })
        foreach ($e in @(Get-ChildItem -LiteralPath $dp -Force)) { if ($planned -cnotcontains $e.Name) { [void]$failed.Add("unexpected-file:$d\$($e.Name)") } }
    }
    $rootPlanned = @($Plan | Where-Object { $_.Dir -ne 'xdg' -and $_.Rel -notlike '*\*' } | ForEach-Object { $_.Rel }) + @('plugin', 'tool', 'node_modules')
    foreach ($e in @(Get-ChildItem -LiteralPath $ConfigDir -Force -ErrorAction SilentlyContinue)) { if ($rootPlanned -cnotcontains $e.Name) { [void]$failed.Add("unexpected-file:$($e.Name)") } }
    return [pscustomobject]@{ Pass = ($failed.Count -eq 0); Failed = @($failed) }
}

# ---- applying the read grants -----------------------------------------------------------------------------

function Get-CoderToolchainGrantCommand {
    # PURE. The icacls argument list (SID form) for one grant.
    param([Parameter(Mandatory)]$Grant, [Parameter(Mandatory)][string]$CoderSid)
    return @($Grant.Path, '/grant', "*${CoderSid}:$($Grant.Flags)$($Grant.Rights)")
}

function Test-CoderGrantTargetSafe {
    # The gate in front of a toolchain grant or its undo. Returns @{ Ok; Reason; Links[] }. REFUSES a path that
    # fails Test-CoderToolchainPathText, does not exist as a folder, is a link, or sits below a link. (The ACL
    # stage's own gate refuses everything under AppData by design; these grants live there on purpose, so they
    # are gated here.) -Tree lists links INSIDE the folder when Find-LinksUnder (coder-acl-lib.ps1) is loaded;
    # the grant and its undo never enter one.
    param([Parameter(Mandatory)][string]$Path, [switch]$Tree)
    $r = @{ Ok = $false; Reason = ''; Links = @() }
    $why = Test-CoderToolchainPathText $Path
    if ($why) { $r.Reason = $why; return $r }
    $full = [IO.Path]::GetFullPath(($Path -replace '/', '\')).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $full -PathType Container)) { $r.Reason = "'$Path' does not exist as a folder"; return $r }
    $cur = $full
    while ($cur -and $cur -notmatch '^[A-Za-z]:$') {
        $it = Get-Item -LiteralPath $cur -Force -ErrorAction SilentlyContinue
        if ($it -and ($it.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            $r.Reason = if ($cur -ieq $full) { "'$Path' is a link" } else { "'$Path' sits below the link '$cur'" }
            return $r
        }
        $parent = [IO.Path]::GetDirectoryName($cur)
        if (-not $parent -or $parent -eq $cur) { break }
        $cur = $parent
    }
    if ($Tree -and (Get-Command Find-LinksUnder -ErrorAction SilentlyContinue)) { $r.Links = @(Find-LinksUnder -Root $full) }
    $r.Ok = $true
    return $r
}

function Get-CoderToolchainGrantState {
    # 'absent' (no explicit coder entry), 'read' (an Allow entry without a write-capable right) or 'WRITE' (a
    # write-capable Allow entry: a finding, never expected).
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$CoderSid)
    $mine = @(Get-ObjectAccessRules -Path $Path | Where-Object { $_.Sid -eq $CoderSid -and $_.Type -eq 'Allow' })
    if ($mine.Count -eq 0) { return 'absent' }
    if (@(Test-RulesGrantWrite -Rules $mine -WatchSids @($CoderSid)).Count -gt 0) { return 'WRITE' }
    return 'read'
}

function Invoke-CoderToolchainGrant {
    # Apply one grant (icacls, SID form, NO /T: an inheritable entry reaches the children by inheritance and /T
    # follows directory symlinks) and read it back, or -Undo it with the no-follow removal. THROWS when the gate
    # refuses or the read-back does not show a read-only coder entry.
    param([Parameter(Mandatory)]$Grant, [Parameter(Mandatory)][string]$CoderSid, [switch]$Undo, [scriptblock]$Out = $null)
    $tree = ($Grant.Flags -ne '')
    $gate = Test-CoderGrantTargetSafe -Path $Grant.Path -Tree:$tree
    if (-not $gate.Ok) { throw "toolchain grant '$($Grant.Id)' refused: $($gate.Reason)" }
    if ($Out -and $gate.Links.Count -gt 0) { & $Out "  note: $($gate.Links.Count) link(s) inside $($Grant.Path) are never entered" }
    if ($Undo) {
        if ($tree) { $null = Invoke-AclTreeRemoveGrants -Root $Grant.Path -Sid $CoderSid -Type Allow }
        else { $null = Remove-ExplicitGrantOfSid -Path $Grant.Path -IsDir $true -Sid $CoderSid -Type Allow }
        if ((Get-CoderToolchainGrantState -Path $Grant.Path -CoderSid $CoderSid) -ne 'absent') { throw "toolchain grant '$($Grant.Id)': the coder entry is still on $($Grant.Path) after the undo" }
        return
    }
    $icOut = & icacls @(Get-CoderToolchainGrantCommand -Grant $Grant -CoderSid $CoderSid) 2>&1
    if ($LASTEXITCODE -ne 0) { throw "icacls failed granting '$($Grant.Id)' on $($Grant.Path) (exit $LASTEXITCODE): $(($icOut | Out-String).Trim())" }
    $state = Get-CoderToolchainGrantState -Path $Grant.Path -CoderSid $CoderSid
    if ($state -ne 'read') { throw "toolchain grant '$($Grant.Id)': read-back on $($Grant.Path) shows '$state', expected a read-only coder entry" }
}

# ---- the probe verdict for the setup checks ----------------------------------------------------------------

function Get-SetupChecksFromProbe {
    # PURE. Checks 15-21, 23 and 24 from the probe's result 'checks' object: every one HARD-required, and a probe
    # result that lacks a check FAILS it (never a skip). Returns @{ Rows[]; Verdict = @{ Pass; Failed[] } }.
    # -Checks: a hashtable (JSON parsed with -AsHashtable) or a PSCustomObject.
    param([Parameter(Mandatory)]$Checks)
    $defs = @(
        @{ N = 'check15-proxy-loopback-ok';      K = 'proxy_loopback_ok';        D = 'the coder reaches the model repair proxy on loopback (:8099), the address its opencode config names' },
        @{ N = 'check16-operator-profile-denied'; K = 'operator_profile_denied';  D = 'the coder cannot read the operator opencode config, .ssh or the runtime keystore' },
        @{ N = 'check17-git-status-ok';          K = 'git_status_ok';            D = 'git status runs in the coder worktree with only the scoped safe.directory (no wildcard)' },
        @{ N = 'check18-toolchain-runs';         K = 'toolchain_runs';           D = 'opencode, node, git, git-bash and python start for the coder' },
        @{ N = 'check19-coder-config-readable';  K = 'coder_config_ok';          D = 'the coder-owned opencode config parses, has no MCP block and keeps its permission block' },
        @{ N = 'check20-coder-config-protected'; K = 'coder_config_write_denied'; D = 'the coder cannot write its own opencode config, plugin or tool files' },
        @{ N = 'check21-research-log-writable';  K = 'research_log_writable';    D = 'the coder writes its research usage log under its own profile' },
        @{ N = 'check23-write-outside-extra';    K = 'extra_write_denied';       D = 'the coder cannot write in the fleet root, the fleet scripts, or the operator state folder' },
        @{ N = 'check24-config-root-intact';     K = 'coder_config_root_intact';  D = 'every folder of the installed config (~/.config, opencode, plugin, tool, git) is still a real folder owned by Administrators; a rename-and-replace by the coder is detected' }
    )
    $rows = New-Object System.Collections.ArrayList; $failed = New-Object System.Collections.ArrayList
    foreach ($d in $defs) {
        $c = Get-JsonMember $Checks $d.K
        $pass = $false; $detail = 'the probe result has no such check'
        if ($null -ne $c) { $pass = [bool](Get-JsonMember $c 'pass'); $detail = [string](Get-JsonMember $c 'detail') }
        [void]$rows.Add([pscustomobject]@{ Name = $d.N; Pass = $pass; Detail = $(if ($pass) { $d.D } else { "$($d.D) -- $detail" }) })
        if (-not $pass) { [void]$failed.Add($d.N) }
    }
    return [pscustomobject]@{ Rows = @($rows); Verdict = [pscustomobject]@{ Pass = ($failed.Count -eq 0); Failed = @($failed) } }
}

function Get-CoderProbeGitEnv {
    # The probe's own copy of Get-CoderLegGitEnv's three scoped keys (the probe is dependency-free by design).
    # verify-coder-setup.ps1 holds the two equal so they cannot drift.
    param([Parameter(Mandatory)][string]$WorkDir)
    $wd = $WorkDir.TrimEnd('\').Replace('\', '/')
    return [ordered]@{ GIT_OPTIONAL_LOCKS = '0'; GIT_TERMINAL_PROMPT = '0'; GIT_CONFIG_COUNT = '2'; GIT_CONFIG_KEY_0 = 'safe.directory'; GIT_CONFIG_VALUE_0 = $wd; GIT_CONFIG_KEY_1 = 'core.fsmonitor'; GIT_CONFIG_VALUE_1 = 'false' }
}
