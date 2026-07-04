# Network devices (routers, switches, clients) — coder reference

Covers writing scripts/configs to **query and configure** network gear: SSH-driven Cisco IOS-style
CLI on routers/switches, **SNMP** polling, and **Windows client networking** via PowerShell's
NetTCPIP / NetAdapter modules plus `Test-NetConnection`. Primary tools: an SSH client (Posh-SSH or
native OpenSSH `ssh`) for devices, an SNMP library (PowerShell has **no** built-in SNMP cmdlet — see
Pitfalls), and the in-box PowerShell networking cmdlets for Windows clients.

---

## Key tools / cmdlets / APIs

- **`ssh` (OpenSSH client)** — ships in Windows 10/11 + Server; non-interactive device CLI: `ssh user@host "show ..."`.
- **Posh-SSH** (`Install-Module Posh-SSH`) — PowerShell SSH module: `New-SSHSession`, `Invoke-SSHCommand`, `New-SSHShellStream` (the stream is needed for paged/interactive IOS config). Third-party; not present offline unless pre-installed.
- **Cisco IOS exec/config** — `show running-config`, `show ip interface brief`, `show vlan brief`; config mode via `configure terminal` (`conf t`) → commands → `end`; persist with `write memory` (`copy running-config startup-config`).
- **SNMP** — read with GET/WALK on OIDs (e.g. `sysDescr.0` = `1.3.6.1.2.1.1.1.0`, `ifTable` = `1.3.6.1.2.1.2.2`). On Windows use the **SnmpSharpNet** .NET library or the **Net-SNMP** `snmpwalk`/`snmpget` CLI; there is no native PowerShell SNMP cmdlet.
- **NetTCPIP module** — `Get-NetIPConfiguration`, `Get-NetIPAddress`, `Get-NetRoute`, `Get-NetIPInterface`, and the write cmdlets `New-NetIPAddress` / `Set-NetIPAddress` / `New-NetRoute` (all support `-WhatIf`).
- **NetAdapter module** — `Get-NetAdapter`, `Get-NetAdapterStatistics`; write cmdlets `Enable-NetAdapter` / `Disable-NetAdapter` / `Restart-NetAdapter` (support `-WhatIf`).
- **`Test-NetConnection`** (`tnc`) — connectivity/port probe: ICMP ping, TCP port test (`-Port`), traceroute (`-TraceRoute`), route diagnostics.
- **`Resolve-DnsName`** — DNS lookups (replaces `nslookup` in scripts).

---

## Common task patterns

> Read/query first. None of these examples change device or client state.

**1. Query a device over SSH (one-shot, native OpenSSH)**
```powershell
# Non-interactive; key-based auth assumed (preferred over passwords).
ssh -o BatchMode=yes admin@192.0.2.1 "show ip interface brief"
```

**2. Query a device with Posh-SSH (capture structured output)**
```powershell
Import-Module Posh-SSH
$cred    = Get-Credential                       # prompt; do NOT hardcode
$session = New-SSHSession -ComputerName 192.0.2.1 -Credential $cred -AcceptKey
$result  = Invoke-SSHCommand -SessionId $session.SessionId -Command 'show version'
$result.Output                                  # string[] of CLI lines
Remove-SSHSession -SessionId $session.SessionId
```

**3. Run several IOS show commands and save output**
```powershell
$cmds = 'show running-config', 'show vlan brief', 'show ip route'
foreach ($c in $cmds) {
    $r = Invoke-SSHCommand -SessionId $session.SessionId -Command $c
    $r.Output | Out-File ".\device-$($c -replace '\W','_').txt" -Encoding utf8
}
```

**4. SNMP walk with the Net-SNMP CLI (read-only)**
```powershell
# Requires Net-SNMP installed (snmpwalk.exe on PATH). Community string = secret; pass via env/cred.
snmpwalk -v2c -c $env:SNMP_COMMUNITY 192.0.2.1 1.3.6.1.2.1.1   # the 'system' subtree
snmpget  -v2c -c $env:SNMP_COMMUNITY 192.0.2.1 1.3.6.1.2.1.1.5.0   # sysName.0
```

**5. SNMP GET via SnmpSharpNet (.NET, read-only)**
```powershell
# Add-Type the SnmpSharpNet.dll first. API is stable; verify the exact type/method
# names against the SnmpSharpNet docs for your version.
Add-Type -Path 'C:\libs\SnmpSharpNet.dll'
$target = [SnmpSharpNet.UdpTarget]::new(
    [System.Net.IPAddress]::Parse('192.0.2.1'), 161, 2000, 1)
# ...build SimpleSnmp/Pdu, call Get(); see vendor docs for the full call shape.
```

**6. Windows client: full IP picture for an adapter**
```powershell
Get-NetIPConfiguration -InterfaceAlias 'Ethernet'      # IP, gateway, DNS in one view
Get-NetIPAddress       -AddressFamily IPv4 | Format-Table InterfaceAlias, IPAddress, PrefixLength
Get-NetRoute           -AddressFamily IPv4 | Sort-Object RouteMetric | Select-Object -First 10
Get-NetAdapter         | Format-Table Name, Status, LinkSpeed, MacAddress
```

**7. Windows client: connectivity + open-port probe**
```powershell
Test-NetConnection 8.8.8.8                              # ICMP ping
Test-NetConnection -ComputerName 192.0.2.1 -Port 22     # TCP reachability (returns TcpTestSucceeded)
Test-NetConnection -ComputerName 192.0.2.1 -TraceRoute  # hop-by-hop path
Resolve-DnsName example.com -Type A                     # DNS, scriptable (not nslookup)
```

**8. Windows client: interface + DNS health snapshot for a report**
```powershell
Get-NetAdapter | Where-Object Status -eq 'Up' | ForEach-Object {
    [pscustomobject]@{
        Name      = $_.Name
        LinkSpeed = $_.LinkSpeed
        IPv4      = (Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
        DNS       = (Get-DnsClientServerAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4).ServerAddresses
    }
}
```

---

## Pitfalls

- **No native PowerShell SNMP cmdlet.** Don't write `Get-SnmpData` / `Invoke-SnmpGet` etc. — they aren't built in. Use SnmpSharpNet (.NET) or the Net-SNMP CLI, and confirm the dependency exists (it often won't, offline).
- **IOS paging breaks one-shot capture.** Interactive sessions stop at `--More--`. Either run `terminal length 0` first in the same session, or use a shell stream. With one-shot `Invoke-SSHCommand`/`ssh "..."` IOS usually returns unpaged, but config-mode prompts (`(config)#`) need `New-SSHShellStream` to drive turn-by-turn.
- **`Test-NetConnection -Port` is TCP-only.** It cannot test UDP services (e.g. SNMP/161, DNS/53-over-UDP); a "failed" port test there is a false negative. Use a protocol-aware probe (`Resolve-DnsName`, an SNMP query) instead.
- **`-InterfaceAlias` names are localized/renamable.** "Ethernet", "Wi-Fi" vary by OS language and user renames; prefer `-InterfaceIndex` (`ifIndex`) for stable scripting and pipe from `Get-NetAdapter`.
- **Host-key & auth friction.** First SSH connection prompts to trust the host key; in automation use pre-seeded `known_hosts` (or `-AcceptKey` in Posh-SSH) and **key-based** auth. Never embed passwords/community strings in the script — use `Get-Credential`, env vars, or a secret store.
- **CIM/WMI cmdlets need elevation + RPC.** NetTCPIP/NetAdapter write operations require an elevated session locally; remote use needs WinRM/RPC reachable. A non-admin run fails with access-denied, not a config problem.

---

## Security — OPERATOR REVIEW REQUIRED

The coding agent **writes** these scripts; it must **never auto-execute** them. Each destructive
operation below changes live device or client state and must be run **deliberately by the human**.
Generate them with the safety flag shown, dry-run first, then have the operator execute.

> Cisco IOS has **no** `--dry-run` flag. The safe equivalents are: preview with `show` first; use the
> **`reload in <minutes>`** rollback timer so a bad change auto-reverts unless confirmed with `write memory`;
> and on supported platforms `configure replace` / `archive` for atomic rollback. PowerShell NetTCPIP /
> NetAdapter write cmdlets **do** support `-WhatIf`.

### 1. Writing a device running-config (IOS) — OPERATOR REVIEW REQUIRED — do not auto-run
```powershell
# Preview the exact change first (read-only):
Invoke-SSHCommand -SessionId $s.SessionId -Command 'show running-config | section interface'

# Apply WITH a rollback safety net. The 'reload in 5' reverts the box in 5 min UNLESS
# the operator confirms by saving. OPERATOR runs this, reviews, then saves or lets it roll back.
$stream = New-SSHShellStream -SessionId $s.SessionId
$stream.WriteLine('reload in 5')          # auto-rollback timer
$stream.WriteLine('configure terminal')
# ... the reviewed config lines ...
$stream.WriteLine('end')
# Verify it works, THEN explicitly cancel the rollback timer and persist. NOTE: 'write memory'
# does NOT cancel a pending 'reload' on its own — you must run 'reload cancel' or the box still reboots:
# $stream.WriteLine('reload cancel'); $stream.WriteLine('write memory')
```

### 2. Changing routes — OPERATOR REVIEW REQUIRED — do not auto-run
```powershell
# Windows client static route — DRY RUN FIRST:
New-NetRoute -DestinationPrefix '10.10.0.0/16' -InterfaceIndex 12 -NextHop 192.0.2.254 -WhatIf
# Operator removes -WhatIf to apply. Removal: Remove-NetRoute ... -WhatIf  (confirm before real run).

# IOS static route — preview, then apply inside the reviewed 'configure terminal' block above:
#   ip route 10.10.0.0 255.255.0.0 192.0.2.254
# Verify with:  show ip route  (read-only) before 'write memory'.
```

### 3. Changing VLANs / interfaces (IOS) — OPERATOR REVIEW REQUIRED — do not auto-run
```powershell
# Read current state first (safe):
Invoke-SSHCommand -SessionId $s.SessionId -Command 'show vlan brief'
Invoke-SSHCommand -SessionId $s.SessionId -Command 'show interfaces status'

# Changing a switchport VLAN can cut off the device/host you're managing. OPERATOR runs this
# deliberately, under the 'reload in' safety net from #1:
#   configure terminal
#     interface GigabitEthernet0/2
#       switchport access vlan 20
#     end
#   show vlan brief        <-- verify
#   write memory           <-- persist only after confirming reachability
```

### 4. Changing a client IP address — OPERATOR REVIEW REQUIRED — do not auto-run
```powershell
# Reassigning the management IP can drop your own remote session. DRY RUN FIRST:
New-NetIPAddress -InterfaceIndex 12 -IPAddress 192.0.2.50 -PrefixLength 24 `
                 -DefaultGateway 192.0.2.254 -WhatIf
# Operator removes -WhatIf to apply.  Set-NetIPAddress / Remove-NetIPAddress also support -WhatIf.
```

### 5. Disabling / restarting a network adapter — OPERATOR REVIEW REQUIRED — do not auto-run
```powershell
# Disabling the adapter you're connected over will sever remote access. DRY RUN FIRST:
Disable-NetAdapter -Name 'Ethernet' -WhatIf
Restart-NetAdapter -Name 'Ethernet' -WhatIf
# Operator removes -WhatIf (and adds -Confirm:$false only when truly intended) to apply.
```

**Rules for the coding agent:** (1) Default every generated write to its `-WhatIf` / `show`-preview /
`reload in` form. (2) Never pipe a write cmdlet straight into execution or chain `write memory`
without an explicit operator verify step. (3) Keep credentials and SNMP community strings out of the
script body — prompt or read from a secret store. (4) When in doubt about a cmdlet/API name or a
platform-specific feature (e.g. `configure replace` support), emit the read-only query and mark
"verify against current docs" rather than guessing.
