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
    [Parameter(Mandatory)][string]$OutJson
)

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
    $perPath = @{}
    $allDenied = $true
    foreach ($p in $SecretPaths) {
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
            $perPath[$p] = 'denied (UnauthorizedAccess)'
        } catch {
            # Other errors (e.g. IO) — treat as not-a-clean-deny; be conservative and FAIL so the
            # coordinator inspects rather than a false green.
            if ($_.Exception -is [System.Security.SecurityException]) {
                $perPath[$p] = 'denied (SecurityException)'
            } else {
                $perPath[$p] = "inconclusive ($($_.Exception.GetType().Name)) — INSPECT"
                $allDenied = $false
            }
        }
    }
    return @{ pass = $allDenied; detail = 'each named operator secret path must be ACL-denied'; per_path = $perPath }
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
$dir = Split-Path $OutJson -Parent
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
($result | ConvertTo-Json -Depth 8) | Set-Content -Path $OutJson -Encoding UTF8
Write-Host "containment probe wrote $OutJson (ran as $($id.Name))"
exit 0
