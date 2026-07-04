# Bitdefender firewall rule editing — coder reference

Bitdefender business firewall is managed **centrally, per-policy** through the **GravityZone Control Center API**, which is a **JSON-RPC 2.0 over HTTPS** API (NOT REST, NOT a local cmdlet set). Firewall rules and network zones live *inside a Policy object's settings*, not as standalone per-endpoint objects — you read a policy, edit its firewall section, and (where supported) push the whole policy back. This reference is for scripting against that API to read and shape firewall rules; it is **strongly product/version dependent** (see the dependence note below) and the **write path is deliberately treated as unverified** because Bitdefender does not publish a stable public per-rule "create firewall rule" method.

> **Product/version dependence — read this first.**
> - **GravityZone (business)** — Control Center, on-prem or cloud (`cloud.gravityzone.bitdefender.com` / `gravityzone.bitdefender.com`). Has the JSON-RPC API described here. This is the *only* Bitdefender variant with a documented automation API.
> - **Endpoint product** (Bitdefender Endpoint Security Tools / BEST, the agent on a managed Windows/Linux/macOS host) — firewall is driven by the **policy assigned from Control Center**. There is **no supported local rule-editing API/CLI** on a managed endpoint; do not script `bduitool`/`bdconfig`-style local edits for firewall rules.
> - **Consumer Bitdefender** (Total Security / Internet Security on a home PC) — GUI-only firewall. **No documented scripting API.** If the operator's box is consumer Bitdefender, the right answer is "this must be done in the UI," not a script.
> - API surface differs between **on-prem GravityZone versions** and **cloud**, and methods have been added/changed across releases. **Treat every method name below as "verify against the API guide for THIS instance's version."**

## Key tools / cmdlets / APIs

- **Transport:** JSON-RPC 2.0, HTTP `POST`, `Content-Type: application/json`. One service per URL path.
- **Base URL shape:** `https://<control-center-host>/api/v1.0/jsonrpc/<service>` — `<service>` ∈ `network`, `policies`, `packages`, `push`, `accounts`, `licensing`, `companies`, `quarantine`, `incidents`, `reports`, `integrations` (availability varies by version/role).
- **Auth:** HTTP **Basic** where username = the **API key** and password = empty (`Authorization: Basic base64("<APIKEY>:")`). API keys are created in Control Center → **My Account → API keys**, each scoped to specific API services.
- **`policies` service** — the firewall lives here. Confident READ methods: **`getPoliciesList`**, **`getPolicyDetails`** (returns the full settings tree incl. the firewall section).
- **`network` service** — inventory + assignment. Confirmed reads: **`getEndpointsList`**, **`getManagedEndpointDetails`**, **`getNetworkInventoryItems`**. For *which policy a target has*, the field is typically returned inside `getManagedEndpointDetails` — a separate **`getPolicyAssignmentSettings`** method is **NOT confirmed in the current public API guide; verify it exists for this instance's version before relying on it** (some versions surface assignment only via the endpoint-details object). Read pattern #6 below uses it illustratively — fall back to `getManagedEndpointDetails` if it is absent.
- **`push` service** — event/notification config (`setPushEventSettings` / `getPushEventSettings`); relevant only if you want firewall-block telemetry, not for editing rules.
- **No native PowerShell module.** "Cmdlets" here means *you write thin PowerShell/Python wrappers* over the JSON-RPC endpoint (examples below). There is no `Get-BDFirewallRule`.
- **Firewall data model (inside a policy's settings):** a policy has a **firewall module** with an on/off + general settings, a set of **network adapter / zone (trusted/untrusted) settings**, and an ordered list of **custom rules** (each rule ≈ `{ name, action(allow/deny), direction(in/out/both), protocol, localPort, remotePort, remoteAddress, application/path, networkType, priority/order }`). **Exact field names and nesting are version-specific** — always derive them from a live `getPolicyDetails` dump, never from memory.

## Common task patterns

> **Read/query first, always.** Every edit starts from a fresh `getPolicyDetails` so you are editing the *current* shape, not an assumed one. Examples use `$CC` = Control Center host and `$KEY` = API key.

**1. PowerShell — build the auth header and a reusable JSON-RPC caller (READ-ONLY helper).**
```powershell
$CC  = 'gravityzone.example.com'           # Control Center host
$KEY = $env:GZ_API_KEY                      # API key from My Account -> API keys
$auth = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$KEY`:"))

function Invoke-GZ {
    param(
        [Parameter(Mandatory)] [string] $Service,   # e.g. 'policies'
        [Parameter(Mandatory)] [string] $Method,    # e.g. 'getPoliciesList'
        [hashtable] $Params = @{}
    )
    $body = @{ jsonrpc = '2.0'; id = [guid]::NewGuid().ToString()
               method = $Method; params = $Params } | ConvertTo-Json -Depth 20
    $uri = "https://$CC/api/v1.0/jsonrpc/$Service"
    $resp = Invoke-RestMethod -Method Post -Uri $uri -Body $body `
                -ContentType 'application/json' -Headers @{ Authorization = $auth }
    if ($resp.error) { throw "GZ API error $($resp.error.code): $($resp.error.message)" }
    $resp.result
}
```

**2. PowerShell — list policies, then find the firewall-bearing policy by name (READ).**
```powershell
$page = Invoke-GZ -Service policies -Method getPoliciesList -Params @{ page = 1; perPage = 100 }
$page.items | Select-Object id, name | Format-Table
$policyId = ($page.items | Where-Object name -eq 'Workstations - Standard').id
```

**3. PowerShell — dump one policy's full settings and locate the firewall section (READ, do this BEFORE any edit).**
```powershell
$pd = Invoke-GZ -Service policies -Method getPolicyDetails -Params @{ policyId = $policyId }
# Save the raw shape so you edit the REAL structure for this version, not an assumed one:
$pd | ConvertTo-Json -Depth 40 | Out-File ".\policy-$policyId.json" -Encoding utf8
# Inspect where the firewall lives in THIS version's tree (path varies by version):
$pd.PSObject.Properties.Name        # top-level keys
$pd.settings                        # drill down until you find the 'firewall' object
```

**4. Python — equivalent JSON-RPC client + read a policy (READ).**
```python
import os, base64, json, urllib.request

CC  = "gravityzone.example.com"
KEY = os.environ["GZ_API_KEY"]
AUTH = "Basic " + base64.b64encode(f"{KEY}:".encode()).decode()

def gz(service: str, method: str, params: dict | None = None):
    payload = json.dumps({"jsonrpc": "2.0", "id": "1",
                          "method": method, "params": params or {}}).encode()
    req = urllib.request.Request(
        f"https://{CC}/api/v1.0/jsonrpc/{service}", data=payload,
        headers={"Content-Type": "application/json", "Authorization": AUTH})
    with urllib.request.urlopen(req, timeout=30) as r:   # cert verified by default
        out = json.load(r)
    if "error" in out:
        raise RuntimeError(f"GZ error {out['error']['code']}: {out['error']['message']}")
    return out["result"]

policies = gz("policies", "getPoliciesList", {"page": 1, "perPage": 100})
pid = next(p["id"] for p in policies["items"] if p["name"] == "Workstations - Standard")
details = gz("policies", "getPolicyDetails", {"policyId": pid})
open(f"policy-{pid}.json", "w").write(json.dumps(details, indent=2))  # inspect real shape
```

**5. PowerShell — enumerate existing firewall custom rules from a saved dump (READ-ONLY reporting).**
```powershell
# Adjust the path to match what step 3 revealed for THIS version (e.g. .settings.firewall.rules.rules).
$pd = Get-Content ".\policy-$policyId.json" -Raw | ConvertFrom-Json
$rules = $pd.settings.firewall.rules.rules     # <-- VERIFY this path against your dump
$rules | Select-Object name, action, direction, protocol, remoteAddress, localPort, remotePort |
         Format-Table -AutoSize
```

**6. PowerShell — find which endpoints/groups a firewall policy is assigned to (READ, blast-radius check before any change).**
```powershell
$inv = Invoke-GZ -Service network -Method getNetworkInventoryItems -Params @{ page=1; perPage=100 }
# NOTE: getPolicyAssignmentSettings is UNVERIFIED for this version (see Key tools). If it errors with a
# 'method not found' (-32601), read the assigned policy from getManagedEndpointDetails instead, e.g.:
#   $d = Invoke-GZ -Service network -Method getManagedEndpointDetails -Params @{ endpointId = $item.id }
#   $assigned = $d.policy.id   # <-- confirm this path from a live details dump
foreach ($item in $inv.items) {
    $asg = Invoke-GZ -Service network -Method getPolicyAssignmentSettings -Params @{ targetId = $item.id }
    [pscustomobject]@{ Name=$item.name; Id=$item.id; AssignedPolicy=$asg.policyId }
} | Where-Object AssignedPolicy -eq $policyId   # who is affected if you edit this policy
```

**7. Shape of an add/edit (construct the object, DO NOT push here).**
```powershell
# A new custom rule, built to MATCH the field names you confirmed from the live dump (step 3).
# Field names below are ILLUSTRATIVE — reconcile each against policy-$policyId.json for this version.
$newRule = [ordered]@{
    name          = 'Allow internal RDP'
    action        = 'allow'          # allow | deny  (verify enum values from the dump)
    direction     = 'in'             # in | out | both
    protocol      = 'tcp'            # tcp | udp | ...
    localPort     = '3389'
    remotePort    = ''
    remoteAddress = '10.0.0.0/24'
    networkType   = 'trusted'        # trusted | untrusted / home/work/public — verify enum
    priority      = 1                # rule ORDER matters: first match wins
}
# To EDIT: load the dump, append/replace inside the rules array, keep ordering intentional:
$pd = Get-Content ".\policy-$policyId.json" -Raw | ConvertFrom-Json
$pd.settings.firewall.rules.rules = @($newRule) + $pd.settings.firewall.rules.rules   # prepend = highest priority
$pd | ConvertTo-Json -Depth 40 | Out-File ".\policy-$policyId.PROPOSED.json" -Encoding utf8
# STOP. Pushing this back is a DESTRUCTIVE op -> see the Security section.
```

**8. Confirm the API key actually has the needed service scope (READ, pre-flight).**
```powershell
# A cheap call against each service you plan to use surfaces 'access denied' (-32600/-32000 class)
# BEFORE you build an edit. If getPolicyDetails errors with an auth code, the key lacks 'policies'.
try   { Invoke-GZ -Service policies -Method getPoliciesList -Params @{ page=1; perPage=1 } | Out-Null
        'policies: OK' }
catch { "policies: $($_.Exception.Message)" }
```

## Pitfalls

- **It is JSON-RPC, not REST.** There are no `GET /policies/{id}` paths. Everything is `POST` to a per-service URL with `{jsonrpc, id, method, params}`. Calling it like REST returns errors or HTML login pages. The HTTP status is usually `200` even on logical errors — **you must check the `error` member of the response body**, not just the status code.
- **Field/path names for the firewall section are version-specific and undocumented in a stable form.** `settings.firewall.rules.rules` is the *typical* shape but **must be confirmed from a live `getPolicyDetails` dump** for the instance you target. Coding against remembered field names is the #1 source of silently-wrong rules.
- **No reliable public per-rule "create" method.** GravityZone's public API is **read-rich, write-thin** for policy contents; a documented stable `addFirewallRule`/`setPolicyDetails` is **not something to assume exists**. If a write method is genuinely needed, it must be **found in the API guide for that exact version** and marked verified — do **not** invent a method name (see Security). On many versions, firewall-rule authoring is intentionally UI-only.
- **Rule order is the policy.** Firewall rules are evaluated top-down, first match wins. An "allow" placed below a broad "deny" does nothing. Any edit must be explicit about *position*, not just contents.
- **Auth/scope gotchas:** the API key is the *username* with an **empty password** (note the trailing colon before base64). Each key is scoped per service — a key that can read `network` may be denied on `policies`. Also: on-prem instances may use a self-signed cert; **fix the trust store / pin the cert**, do **not** blanket-disable TLS verification in a security-first environment.
- **Blast radius:** a policy is shared by every endpoint/group assigned to it. One rule edit can change the firewall on hundreds of machines at once (see read pattern #6). There is no "preview on one machine" — the policy *is* the unit of change.

## Security — OPERATOR REVIEW REQUIRED

**Posture:** the coding agent **writes** these scripts; it must **never auto-execute** any of the destructive operations below. Reads (`getPoliciesList`, `getPolicyDetails`, inventory/assignment queries, building a *proposed* JSON object on disk) are safe for the agent to run. **Every operation that changes a firewall rule, the firewall module state, or policy/profile assignment is destructive and gated.**

There is **no native `-WhatIf` / `--dry-run` flag** on the GravityZone JSON-RPC API. The required substitute is a **two-file diff-and-confirm ritual**: the agent only ever produces a `*.PROPOSED.json`; a human reviews the diff and runs the push by hand.

**Destructive operations (each: OPERATOR REVIEW REQUIRED — do not auto-run):**

1. **Pushing an edited policy back / writing firewall rules** — OPERATOR REVIEW REQUIRED — do not auto-run.
   The exact write method name is **version-dependent and must be verified against the API guide for this instance — do not assume it exists or guess it.** Pattern the human runs deliberately:
   ```powershell
   # OPERATOR-RUN ONLY. Dry-run substitute = inspect the diff first, push nothing automatically.
   $current  = Get-Content ".\policy-$policyId.json"          -Raw   # captured by the agent (read)
   $proposed = Get-Content ".\policy-$policyId.PROPOSED.json" -Raw   # built by the agent (no push)
   Compare-Object ($current -split "`n") ($proposed -split "`n")     # <-- human reviews THIS

   # Only after the human approves the diff, and only with a write method VERIFIED for this version:
   #   $writeMethod = '<VERIFY-against-API-guide>'   # e.g. setPolicyDetails -- DO NOT GUESS
   #   Invoke-GZ -Service policies -Method $writeMethod -Params @{ policyId=$policyId; settings=$proposed }
   # ^ left commented on purpose. Operator uncomments after confirming the method + the diff.
   ```

2. **Adding or removing a single firewall rule** — OPERATOR REVIEW REQUIRED — do not auto-run.
   This is a special case of (1): it mutates `settings.firewall.rules.rules` and is pushed via the same verified write method. The agent's output stops at the `*.PROPOSED.json` + the `Compare-Object` diff. **No standalone per-rule add/delete call should be invoked by the agent.**

3. **Turning the firewall module on/off, or changing its general settings (stealth mode, default action, IDS)** — OPERATOR REVIEW REQUIRED — do not auto-run.
   Same gate: edit `settings.firewall.<...>` into a `*.PROPOSED.json`, human diffs, human pushes. Flipping the module off disables host firewalling fleet-wide — treat as high-impact.

4. **Assigning/unassigning a policy or changing a profile on endpoints/groups** — OPERATOR REVIEW REQUIRED — do not auto-run.
   Done via the `network` service (assignment method name is **version-specific — verify, do not guess**, e.g. an `assignPolicy`-style call). The agent may *report* current assignments (read pattern #6) and *list* intended targets, but **must not execute the assignment.** Pattern the human runs:
   ```powershell
   # OPERATOR-RUN ONLY. Agent produces the target list (read); human confirms blast radius, then assigns.
   $targets = Import-Csv ".\intended-targets.csv"   # built by the agent from read-only inventory
   $targets | Format-Table   # <-- human reviews who is affected BEFORE assigning
   # $assignMethod = '<VERIFY-against-API-guide>'    # DO NOT GUESS the method name
   # foreach ($t in $targets) { Invoke-GZ -Service network -Method $assignMethod -Params @{ ... } }
   ```

**Hard rules for the agent:**
- Never base64-bake an API key into a committed script; read it from `$env:GZ_API_KEY` / a secret store at runtime.
- Never disable TLS verification (no `-SkipCertificateCheck`, no `ssl._create_unverified_context`) to "make it work"; fix the trust store instead.
- Never invent a write/assignment **method name**. If the read shows the data but the write method is unknown, **say so and emit `verify against current docs` / `<VERIFY-against-API-guide>`** rather than guessing.
- Default deliverable for any change request = **read script + a `*.PROPOSED.json` + a diff command**, never an executed mutation.
