# Synology DS NAS and media server — coder reference

Practical reference for scripting a Synology DiskStation (DSM 7.x) and its media server. Two
control planes: the **DSM Web API** (HTTP/JSON over `/webapi/*.cgi`, auth via `SYNO.API.Auth`
→ session id) for app-style automation, and **SSH + `syno*` CLI tools** (`synopkg`,
`synoservice`/`synosystemctl`, `synouser`, `synoshare`) for box administration. Media is normally
**Plex** (its own token-based HTTP API); Synology's own **Video Station was removed in DSM 7.2**,
so prefer Plex unless the box is confirmed on DSM ≤ 7.1.

> Audience: an offline coding agent that **writes** scripts/configs. Default to **read/query**
> endpoints. Destructive operations are gated to the human — see the Security section.

## Key tools / cmdlets / APIs

- **`SYNO.API.Info`** (`/webapi/query.cgi`) — discover which APIs exist + their path + max version. Always query first.
- **`SYNO.API.Auth`** (`/webapi/auth.cgi`) — `login` returns a session id (`sid`); `logout` ends it. Honors 2FA (`otp_code`).
- **`SYNO.FileStation.*`** — `List`, `Download`, `Upload`, `CreateFolder`, `Rename`, `CopyMove`, `Delete`. The file/folder plane.
- **`SYNO.Core.Package` / `SYNO.Core.Package.*`** — list/query installed packages and their state via the Web API.
- **`SYNO.Core.System`, `SYNO.Core.System.Utilization`, `SYNO.Storage.*`** — system info, CPU/RAM load, volume/disk status (read-only telemetry).
- **`synopkg`** (SSH) — package CLI: `list`, `status <pkg>`, `start`/`stop`/`restart`/`install`/`uninstall`. The authoritative package tool on-box.
- **`synosystemctl`** (DSM 7) / **`synoservice`** (DSM 6) — service control: `status`, `get-active-list`, `start`/`stop`/`restart`.
- **`synouser` / `synogroup` / `synoshare`** (SSH) — manage DSM users, groups, and shared folders from the CLI.
- **Plex HTTP API** — `http://<nas>:32400/...` authenticated with an `X-Plex-Token` header/param; `/library/sections`, `/status/sessions`, `/library/sections/<id>/refresh`.
- **`synoindex`** (SSH) — tell Synology's own media indexer about file changes (`-A` add, `-R` reindex a path). Synology indexer only; not Plex.

> Web API base URL = `http(s)://<host>:<port>/webapi/`. Default ports 5000 (HTTP) / 5001 (HTTPS).
> Each call needs `api`, `version`, `method`, and (after login) `_sid` or the `id` cookie.

## Common task patterns

All examples **read/query first**. Replace `$NAS`, ports, and credentials with real values (pull
secrets from env or a secret store, never hard-code). `curl` examples are POSIX; PowerShell
equivalents use `Invoke-RestMethod`.

### 1. Discover available APIs (always do this first)

```bash
NAS="https://nas.local:5001"
# Ask which APIs the box exposes, and their path + max version.
curl -sk "$NAS/webapi/query.cgi?api=SYNO.API.Info&version=1&method=query&query=all" | jq '.data."SYNO.FileStation.List", .data."SYNO.API.Auth"'
```

The returned `path` (e.g. `entry.cgi` or `FileStation/file_share.cgi`) and `maxVersion` are what
you plug into later calls. **Do not assume a version — read it from here** (max versions drift
between DSM releases; verify against current docs if pinning).

### 2. Log in → get a session id (`sid`)

```bash
# session=FileStation scopes the login; format=sid returns the token in JSON.
SID=$(curl -sk "$NAS/webapi/auth.cgi" \
  --data-urlencode "api=SYNO.API.Auth" \
  --data-urlencode "version=6" \
  --data-urlencode "method=login" \
  --data-urlencode "account=$NAS_USER" \
  --data-urlencode "passwd=$NAS_PASS" \
  --data-urlencode "session=FileStation" \
  --data-urlencode "format=sid" | jq -r '.data.sid')
echo "sid=$SID"
```

If 2FA is enabled, add `--data-urlencode "otp_code=123456"`. A failed login returns
`{"success":false,"error":{"code":400}}` (see Pitfalls for the error-code map). **Always log out
when done** (pattern 8) to free the session slot.

### 3. List a shared folder (FileStation read)

```bash
curl -sk "$NAS/webapi/entry.cgi" \
  --data-urlencode "api=SYNO.FileStation.List" \
  --data-urlencode "version=2" \
  --data-urlencode "method=list" \
  --data-urlencode "folder_path=/volume1/media/Movies" \
  --data-urlencode "additional=[\"size\",\"time\",\"type\"]" \
  --data-urlencode "_sid=$SID" | jq '.data.files[] | {name, isdir, size: .additional.size}'
```

`method=list_share` (no `folder_path`) lists the top-level shares the account can see. Use that to
discover valid roots before drilling in.

### 4. Download a file

```bash
# mode=download streams the bytes; mode=open returns inline. -o writes to disk.
curl -sk -o ./movie.mkv "$NAS/webapi/entry.cgi" \
  --data-urlencode "api=SYNO.FileStation.Download" \
  --data-urlencode "version=2" \
  --data-urlencode "method=download" \
  --data-urlencode "path=/volume1/media/Movies/movie.mkv" \
  --data-urlencode "mode=download" \
  --data-urlencode "_sid=$SID"
```

### 5. List installed packages and their state (read-only)

Via the Web API:

```bash
curl -sk "$NAS/webapi/entry.cgi" \
  --data-urlencode "api=SYNO.Core.Package" \
  --data-urlencode "version=2" \
  --data-urlencode "method=list" \
  --data-urlencode "_sid=$SID" | jq '.data.packages[] | {id, version, status: .additional.status}'
```

Or over SSH (authoritative, works offline on-box):

```bash
ssh admin@nas.local 'synopkg list --name'          # installed package names
ssh admin@nas.local 'synopkg status PlexMediaServer' # running / stopped, version
```

### 6. PowerShell: login + system utilization (read-only telemetry)

```powershell
$nas = "https://nas.local:5001"
$body = @{
  api = "SYNO.API.Auth"; version = 6; method = "login"
  account = $env:NAS_USER; passwd = $env:NAS_PASS
  session = "Core"; format = "sid"
}
# -SkipCertificateCheck only for a self-signed cert on a trusted LAN; prefer a real cert.
$login = Invoke-RestMethod -Uri "$nas/webapi/auth.cgi" -Method Post -Body $body -SkipCertificateCheck
$sid   = $login.data.sid

$util = Invoke-RestMethod -Uri "$nas/webapi/entry.cgi" -Method Get -SkipCertificateCheck -Body @{
  api = "SYNO.Core.System.Utilization"; version = 1; method = "get"; _sid = $sid
}
$util.data.cpu, $util.data.memory
```

### 7. Plex: read libraries and active sessions, then refresh a library

```bash
# Plex uses its OWN token (X-Plex-Token), NOT the DSM sid. Token comes from a Plex sign-in / account page.
PLEX="http://nas.local:32400"; TOKEN="$PLEX_TOKEN"
# Read: list libraries (sections) and what's currently playing.
curl -s "$PLEX/library/sections?X-Plex-Token=$TOKEN"  -H "Accept: application/json" | jq '.MediaContainer.Directory[] | {key, title, type}'
curl -s "$PLEX/status/sessions?X-Plex-Token=$TOKEN"   -H "Accept: application/json" | jq '.MediaContainer.size'

# Action (non-destructive): rescan one library section. Section key from the list above.
curl -s "$PLEX/library/sections/1/refresh?X-Plex-Token=$TOKEN"
```

For Synology's own indexer (DSM ≤ 7.1 / Media Server / Photos), use `synoindex` over SSH instead:
`ssh admin@nas.local 'synoindex -A /volume1/media/Movies/new.mkv'`.

### 8. Always log out

```bash
curl -sk "$NAS/webapi/auth.cgi" \
  --data-urlencode "api=SYNO.API.Auth" \
  --data-urlencode "version=6" \
  --data-urlencode "method=logout" \
  --data-urlencode "session=FileStation" \
  --data-urlencode "_sid=$SID"
```

## Pitfalls

- **Don't hard-code API versions.** The right `version` and the right `.cgi` path (`auth.cgi` vs
  `entry.cgi` vs an app-specific cgi) come from `SYNO.API.Info`. Hard-coded versions break across
  DSM upgrades. If you must pin, comment it and mark **verify against current docs**.
- **`success:false` with a numeric code is the real error — read it.** Common Auth codes:
  `400` invalid account/password, `403` 2FA code required, `404` 2FA code invalid, `407` IP blocked
  / permission denied. FileStation has its own code space (e.g. `408` no such file/path,
  `414`/`415` permission). Don't treat HTTP 200 as success — Synology returns 200 with a JSON error body.
- **Session scoping and slots.** `session=` names the login; reusing the same `session` across
  scripts can invalidate the other's `sid`. Sessions are a finite resource — **always `logout`**.
  For unattended jobs, consider a dedicated low-privilege DSM account rather than the admin account.
- **Self-signed certs.** Out-of-box DSM uses a self-signed cert, hence `curl -k` /
  `-SkipCertificateCheck` in examples. That disables TLS verification — acceptable only on a
  trusted LAN; for anything routable, install a real cert and drop the flag.
- **Video Station is gone in DSM 7.2.** Synology removed Video Station (and Moments-era apps)
  in DSM 7.2; scripts targeting `SYNO.VideoStation.*` will fail on current boxes. Treat **Plex**
  as the media server and verify the DSM version (`SYNO.Core.System`) before using any
  Synology-native video API.
- **SSH paths and the root volume.** Real data lives under `/volume1`, `/volume2`, … (not `/`).
  The first volume is usually `/volume1` but **don't assume it** — confirm with
  `ssh admin@nas.local 'ls -d /volume*'` or the Storage API. SSH must be enabled in
  DSM (Control Panel → Terminal & SNMP) before any SSH pattern works.
- **Don't leak secrets into the URL / shell history.** Passing the Plex `X-Plex-Token` (and any
  `_sid`) in the query string — as the Plex examples do for brevity — writes the secret to shell
  history, proxy/web-server access logs, and process listings. For DSM, prefer the POST-body form
  (`--data-urlencode "_sid=…"`, as in the FileStation examples). For Plex, send the token as a
  header instead: `-H "X-Plex-Token: $TOKEN"`. Always source tokens/passwords from env or a secret
  store, never hard-code.

## Security — OPERATOR REVIEW REQUIRED

This agent **writes** scripts; it must **never auto-run destructive operations**. The operations
below change or delete data, users, config, or service state. Emit them as **scripts the human runs
deliberately**, each prefixed with the banner, dry-run first where one exists. **Do not execute
these from the agent.**

> Convention used below: every destructive script starts with
> `# OPERATOR REVIEW REQUIRED — do not auto-run` and, where supported, defaults to a dry run.

### Delete files / folders (FileStation) — OPERATOR REVIEW REQUIRED — do not auto-run

FileStation `Delete` is **asynchronous**: `method=start` returns a `taskid`, then you poll
`status` and may `stop`. There is **no built-in --dry-run**, so emit a **preview (list) step** the
operator inspects before the real delete is uncommented.

```bash
# OPERATOR REVIEW REQUIRED — do not auto-run.
# DRY RUN: show exactly what WOULD be deleted. Operator reviews this output first.
curl -sk "$NAS/webapi/entry.cgi" \
  --data-urlencode "api=SYNO.FileStation.List" --data-urlencode "version=2" --data-urlencode "method=list" \
  --data-urlencode "folder_path=/volume1/media/_trash" --data-urlencode "_sid=$SID" | jq '.data.files[].path'

# DESTRUCTIVE (leave commented until the operator approves the list above):
# TASK=$(curl -sk "$NAS/webapi/entry.cgi" \
#   --data-urlencode "api=SYNO.FileStation.Delete" --data-urlencode "version=2" --data-urlencode "method=start" \
#   --data-urlencode "path=/volume1/media/_trash" --data-urlencode "_sid=$SID" | jq -r '.data.taskid')
# curl -sk "$NAS/webapi/entry.cgi" --data-urlencode "api=SYNO.FileStation.Delete" --data-urlencode "version=2" \
#   --data-urlencode "method=status" --data-urlencode "taskid=$TASK" --data-urlencode "_sid=$SID"
```

### Delete / modify a shared folder — OPERATOR REVIEW REQUIRED — do not auto-run

```bash
# OPERATOR REVIEW REQUIRED — do not auto-run.
ssh admin@nas.local 'synoshare --list'              # read first: enumerate shares
# DESTRUCTIVE — removes the share definition (and can orphan data):
# ssh admin@nas.local 'synoshare --del MyShare'
```

`synoshare` has no `--dry-run`; the `--list` read is the mandatory preview step.

### Add / modify / delete a DSM user — OPERATOR REVIEW REQUIRED — do not auto-run

```bash
# OPERATOR REVIEW REQUIRED — do not auto-run.
ssh admin@nas.local 'synouser --enum local'         # read first: list local users
# DESTRUCTIVE / privilege-changing (run by a human, never auto):
# ssh admin@nas.local 'synouser --add  newuser "PASSWORD" "Full Name" 0 "" 0'   # creates a user
# ssh admin@nas.local 'synouser --del  someuser'                                  # deletes a user
```

> The exact `synouser --add` argument order is version-sensitive — **verify against current DSM
> docs** before the operator runs it. Prefer creating/altering accounts in the DSM GUI; expose CLI
> user changes only as reviewed, commented scripts.

### Stop / restart a package or service — OPERATOR REVIEW REQUIRED — do not auto-run

Stopping a service (Plex, the DSM web station, SMB, etc.) interrupts access. **Read status first.**

```bash
# OPERATOR REVIEW REQUIRED — do not auto-run.
ssh admin@nas.local 'synopkg status PlexMediaServer'        # read: is it running?
ssh admin@nas.local 'synosystemctl get-active-list'         # read: active services (DSM 7)
# DESTRUCTIVE to availability (human-run only):
# ssh admin@nas.local 'synopkg stop    PlexMediaServer'
# ssh admin@nas.local 'synopkg restart PlexMediaServer'
# ssh admin@nas.local 'synosystemctl restart pkgctl-PlexMediaServer'   # DSM 7 service name; verify exact unit
```

`synopkg` / `synosystemctl` have **no `--dry-run`**; the `status` / `get-active-list` reads are the
required preview, and the action lines stay commented for the operator.

### Install / uninstall a package — OPERATOR REVIEW REQUIRED — do not auto-run

```bash
# OPERATOR REVIEW REQUIRED — do not auto-run.
ssh admin@nas.local 'synopkg list --name'           # read: what's installed
# DESTRUCTIVE (human-run only): uninstall removes the package AND may delete its data dir.
# ssh admin@nas.local 'synopkg uninstall PlexMediaServer'
```

### Change DSM system config — OPERATOR REVIEW REQUIRED — do not auto-run

Network, firewall, SSH/Telnet enable, certificate, and shutdown/reboot changes (`synosystemctl`,
`synosetkeyvalue`, `poweroff`, `reboot`, firewall rules) can **lock you out of the box**. The agent
**must not** write self-executing scripts for these. Emit them as documented, commented runbooks
with a stated rollback, for the operator to apply by hand — ideally via the DSM GUI. Mark any exact
CLI key/path **verify against current docs**, since DSM config-CLI surfaces change between releases
and are sparsely documented.
