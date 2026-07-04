# Windows 11 Pro administration — coder reference

Practical reference for writing PowerShell scripts and configs that administer Windows 11 Pro: scheduled tasks, BitLocker, TPM, PnP devices, services, and system/registry state. The primary surface is **built-in PowerShell modules** (`ScheduledTasks`, `BitLocker`, `TrustedPlatformModule`, `PnpDevice`) plus the legacy CLI `manage-bde.exe`; prefer cmdlets over CLI/WMI when a cmdlet exists. All cmdlet names below were verified against a live Windows 11 Pro 24H2 box (PowerShell 5.1 / 7+ both ship these as Windows modules).

**Run elevated.** Almost everything here (writing tasks, BitLocker, TPM, disabling devices, changing services, `HKLM` writes) requires an **Administrator** PowerShell session. Read/query operations mostly do not.

## Key tools / cmdlets / APIs

- **`Get-ScheduledTask` / `Get-ScheduledTaskInfo`** — list/inspect tasks; `Info` adds last/next run time + result. (module: `ScheduledTasks`)
- **`New-ScheduledTaskAction` / `-Trigger` / `-Principal` / `-SettingsSet`** — build the four parts of a task definition, then `Register-ScheduledTask` to create it.
- **`Register-ScheduledTask` / `Set-ScheduledTask` / `Unregister-ScheduledTask`** — create / modify / delete a task. `Export-ScheduledTask` emits the task XML.
- **`Enable-/Disable-/Start-/Stop-ScheduledTask`** — toggle or run on demand. (`schtasks.exe` is the legacy CLI equivalent.)
- **`Get-BitLockerVolume`** — encryption status, protection status, %, key protectors per volume. (module: `BitLocker`)
- **`Enable-BitLocker` / `Disable-BitLocker` / `Suspend-BitLocker` / `Resume-BitLocker`** — turn encryption on/off; suspend = keep encrypted but clear protectors temporarily (safe for firmware/TPM changes).
- **`*-BitLockerKeyProtector` (`Add-`/`Remove-`/`Backup-`)** + **`BackupToAAD-BitLockerKeyProtector`** — manage recovery keys / escrow to Entra ID (AD).
- **`manage-bde.exe`** — legacy BitLocker CLI; `-status`, `-on`, `-off`, `-pause`, `-resume`, `-protectors`. Useful where cmdlets are awkward (e.g. scripting recovery-password retrieval).
- **`Get-Tpm`** — TPM presence/ready/enabled/owned state. **`Get-TpmSupportedFeature`**, **`Get-TpmEndorsementKeyInfo`** — capability/EK queries. (module: `TrustedPlatformModule`)
- **`Clear-Tpm` / `Initialize-Tpm` / `Unblock-Tpm`** — owner-level TPM operations (DESTRUCTIVE — see Security).
- **`Get-PnpDevice` / `Get-PnpDeviceProperty`** — enumerate hardware + read device properties. **`Enable-PnpDevice` / `Disable-PnpDevice`** — toggle a device. (module: `PnpDevice`)
- **`Get-Service` / `Start-` / `Stop-` / `Restart-` / `Set-Service`** — query/control Windows services (`Set-Service` changes StartupType/status).
- **Registry as a drive** — `Get-ItemProperty` / `Get-ChildItem` over `HKLM:\`, `HKCU:\` to read; `Set-`/`New-ItemProperty` to write. `reg.exe` is the legacy CLI.
- **`Get-CimInstance`** (CIM/WMI) — for state not exposed by a dedicated cmdlet (e.g. `Win32_OperatingSystem`, `Win32_LogicalDisk`). Prefer `Get-CimInstance` over the deprecated `Get-WmiObject`.

## Common task patterns

> Read/query first. Every destructive change below has a read-only inspection step shown before it.

**1. Inspect scheduled tasks (read-only) and one task's run history**
```powershell
# List non-Microsoft tasks with state and last result
Get-ScheduledTask |
    Where-Object { $_.TaskPath -notlike '\Microsoft\*' } |
    Select-Object TaskName, TaskPath, State

# Drill into one task's timing/result
Get-ScheduledTask -TaskName 'MyBackup' | Get-ScheduledTaskInfo |
    Select-Object LastRunTime, LastTaskResult, NextRunTime
```

**2. Create a scheduled task (compose the 4 parts, then register)**
```powershell
# Runs a script daily at 02:00 as SYSTEM, highest privileges.
$action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                -Argument '-NoProfile -ExecutionPolicy Bypass -File "C:\scripts\backup.ps1"'
$trigger   = New-ScheduledTaskTrigger -Daily -At 2am
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd

Register-ScheduledTask -TaskName 'NightlyBackup' -TaskPath '\Custom\' `
    -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
    -Description 'Nightly backup job'
```
*(For a task that runs as a specific user with a stored password, add `-User <name> -Password <pw>`; prefer a [gMSA] or `SYSTEM`/`-RunLevel Highest` over storing passwords.)*

**3. Export a task to XML (portable, reviewable config)**
```powershell
Export-ScheduledTask -TaskName 'NightlyBackup' -TaskPath '\Custom\' |
    Out-File 'C:\scripts\NightlyBackup.xml' -Encoding utf8
# Re-create elsewhere from the XML:
# Register-ScheduledTask -TaskName 'NightlyBackup' -Xml (Get-Content 'C:\scripts\NightlyBackup.xml' -Raw)
```

**4. Check BitLocker status (read-only) across all volumes**
```powershell
Get-BitLockerVolume |
    Select-Object MountPoint, VolumeStatus, ProtectionStatus,
                  EncryptionPercentage, @{n='Protectors';e={$_.KeyProtector.KeyProtectorType}}

# CLI equivalent (no admin needed for -status on some configs):
# manage-bde -status C:
```

**5. Read TPM state (read-only) and supported features**
```powershell
Get-Tpm | Select-Object TpmPresent, TpmReady, TpmEnabled, TpmActivated, TpmOwned
Get-TpmSupportedFeature   # e.g. 'key attestation', 'memory protection'
```

**6. Enumerate devices and read a property (read-only)**
```powershell
# All devices in a problem state
Get-PnpDevice | Where-Object { $_.Status -ne 'OK' } |
    Select-Object FriendlyName, Class, Status, InstanceId

# Read the driver version of a specific device
$dev = Get-PnpDevice -Class 'Net' | Select-Object -First 1
Get-PnpDeviceProperty -InstanceId $dev.InstanceId `
    -KeyName 'DEVPKEY_Device_DriverVersion'
```

**7. Query services (read-only) — find what's auto-starting but stopped**
```powershell
# Get-Service has no StartType detail on PS5.1; use CIM for StartMode:
Get-CimInstance Win32_Service |
    Where-Object { $_.StartMode -eq 'Auto' -and $_.State -ne 'Running' } |
    Select-Object Name, DisplayName, StartMode, State
```

**8. Safely read system + registry state (read-only)**
```powershell
# OS build / install date / last boot
Get-CimInstance Win32_OperatingSystem |
    Select-Object Caption, Version, BuildNumber, OsArchitecture, LastBootUpTime

# Read a registry value WITHOUT erroring if the key/value is absent
$key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
(Get-ItemProperty -Path $key -Name 'DisplayVersion' -ErrorAction SilentlyContinue).DisplayVersion

# Test before you read, to avoid exceptions in scripts
if (Test-Path $key) { Get-ItemProperty -Path $key | Select-Object ProductName, DisplayVersion }
```

## Pitfalls

- **`Clear-Tpm` has NO `-WhatIf` and NO `-Confirm`** (verified on 24H2). It runs immediately and is **irreversible** — clearing the TPM invalidates keys sealed to it. There is no dry-run; never script it unattended. Same caution for `Initialize-Tpm`.
- **The TPM module is named `TrustedPlatformModule`, not "Tpm".** `Get-Module -ListAvailable TrustedPlatformModule`. The *cmdlets* are `*-Tpm`, but the module name differs — don't `Import-Module Tpm`.
- **Clearing the TPM can trigger BitLocker recovery.** If the OS volume is BitLocker-protected with a TPM protector, clearing/resetting the TPM (or some firmware changes) forces a recovery-key prompt at next boot. **Suspend BitLocker first** (`Suspend-BitLocker -MountPoint C: -RebootCount 1`) and confirm the recovery key is backed up before any TPM or firmware operation.
- **`schtasks.exe` vs the `ScheduledTasks` module use different path syntax.** Cmdlets split `-TaskName` and `-TaskPath` (e.g. `-TaskPath '\Custom\'`); `schtasks` uses one combined `\Custom\NightlyBackup`. Pick one tool per script. Trailing backslash matters in `-TaskPath`.
- **`Get-Service` is thin; use CIM for startup type.** On Windows PowerShell 5.1, `Get-Service` doesn't expose `StartType` reliably — use `Get-CimInstance Win32_Service` (`StartMode`) for accurate auto/manual/disabled state. (PS 7+ `Get-Service` does have `StartType`.)
- **`Disable-PnpDevice` can disable something you depend on** (the active NIC, the boot disk controller, the only display). Always print `FriendlyName`/`InstanceId` and confirm the target before disabling; a wrong `-Class` filter can hit many devices at once.
- **Registry reads throw on missing keys.** A bare `Get-ItemProperty` on an absent path/value raises a terminating-ish error in scripts. Guard with `Test-Path` and/or `-ErrorAction SilentlyContinue` as shown above. Use the `HKLM:`/`HKCU:` PSDrives, not raw `HKEY_LOCAL_MACHINE\...` strings.

## Security — OPERATOR REVIEW REQUIRED

**Posture: the coding agent WRITES these scripts; it MUST NOT auto-execute any operation in this section.** Each is destructive or state-changing on a security-sensitive subsystem (encryption, root-of-trust, hardware, services, the registry). Emit them as files for a human to review and run **deliberately, elevated, on the real machine**. Where a `-WhatIf` / dry-run exists, the agent should generate it as the *default* and leave the live form commented out.

> Verified on this host: `Disable-BitLocker`, `Suspend-BitLocker`, `Remove-BitLockerKeyProtector`, `Unregister-ScheduledTask`, `Stop-Service`, `Set-Service`, `Disable-PnpDevice` **all support `-WhatIf`/`-Confirm`**. `Clear-Tpm` does **not** — there is no dry-run for it.

**1. Disable / decrypt BitLocker — OPERATOR REVIEW REQUIRED — do not auto-run.**
Decryption removes at-rest protection from the entire volume and can take a long time.
```powershell
# DRY RUN first — shows what would happen, changes nothing:
Disable-BitLocker -MountPoint 'C:' -WhatIf

# To only temporarily suspend (stays encrypted; safer for firmware/TPM work):
Suspend-BitLocker -MountPoint 'C:' -RebootCount 1 -WhatIf

# LIVE decrypt (operator removes -WhatIf intentionally after review):
# Disable-BitLocker -MountPoint 'C:'
# CLI equivalent: manage-bde -off C:
```

**2. Remove a BitLocker key protector — OPERATOR REVIEW REQUIRED — do not auto-run.**
Deleting the wrong protector (e.g. the only recovery password) can lock you out.
```powershell
Get-BitLockerVolume -MountPoint 'C:' | Select-Object -ExpandProperty KeyProtector  # inspect IDs first
# Remove-BitLockerKeyProtector -MountPoint 'C:' -KeyProtectorId '{GUID}' -WhatIf   # dry run
# (remove -WhatIf only after confirming a recovery key is safely backed up)
```

**3. Clear the TPM — OPERATOR REVIEW REQUIRED — do not auto-run. NO DRY-RUN EXISTS.**
Irreversible; invalidates TPM-sealed keys and **will trigger BitLocker recovery** if the OS volume uses a TPM protector.
```powershell
# PRECONDITIONS the operator must satisfy BEFORE running:
#   - BitLocker recovery key backed up AND verified
#   - Suspend-BitLocker -MountPoint 'C:' -RebootCount 1   (done first)
# There is NO -WhatIf for Clear-Tpm. The line below is intentionally left commented:
# Clear-Tpm
```
*(Many TPM admin tasks are better done via the firmware/UEFI or `tpm.msc`. Treat `Clear-Tpm` as a last resort.)*

**4. Disable a PnP device — OPERATOR REVIEW REQUIRED — do not auto-run.**
Can knock out networking, storage, or display. Always confirm the exact target.
```powershell
$dev = Get-PnpDevice -InstanceId '<INSTANCE_ID>'
$dev | Select-Object FriendlyName, Class, Status   # confirm it's the right one
Disable-PnpDevice -InstanceId $dev.InstanceId -WhatIf            # dry run
# Disable-PnpDevice -InstanceId $dev.InstanceId -Confirm:$false  # live (operator only)
```

**5. Delete / replace a scheduled task — OPERATOR REVIEW REQUIRED — do not auto-run.**
```powershell
Get-ScheduledTask -TaskName 'NightlyBackup' -TaskPath '\Custom\'   # confirm it exists
Unregister-ScheduledTask -TaskName 'NightlyBackup' -TaskPath '\Custom\' -WhatIf   # dry run
# Unregister-ScheduledTask -TaskName 'NightlyBackup' -TaskPath '\Custom\' -Confirm:$false  # live
```

**6. Stop or reconfigure a service — OPERATOR REVIEW REQUIRED — do not auto-run.**
Disabling a dependency can destabilize the system; some services refuse to stop without `-Force`.
```powershell
Get-CimInstance Win32_Service -Filter "Name='Spooler'" |
    Select-Object Name, State, StartMode   # inspect first

Stop-Service -Name 'Spooler' -WhatIf                      # dry run
Set-Service  -Name 'Spooler' -StartupType Disabled -WhatIf
# Live forms (operator only, after review):
# Stop-Service -Name 'Spooler' -Force
# Set-Service  -Name 'Spooler' -StartupType Disabled
```

**7. Write to the registry — OPERATOR REVIEW REQUIRED — do not auto-run.**
`HKLM` writes are machine-wide and can break boot/security. Always read the current value first and back up the key.
```powershell
$key = 'HKLM:\SOFTWARE\MyApp'
Get-ItemProperty -Path $key -ErrorAction SilentlyContinue    # read current state
reg.exe export 'HKLM\SOFTWARE\MyApp' 'C:\backup\MyApp.reg'    # backup before any change

# Registry write cmdlets DO support -WhatIf and it is honored on the registry provider
# (verified: New-Item / New-ItemProperty / Set-ItemProperty / Remove-ItemProperty).
# Generate the dry run as the default; operator removes -WhatIf only after backup + review:
New-ItemProperty -Path $key -Name 'Setting' -Value 1 -PropertyType DWord -Force -WhatIf
# Live forms (operator only, after review):
# New-Item -Path $key -Force | Out-Null
# New-ItemProperty -Path $key -Name 'Setting' -Value 1 -PropertyType DWord -Force
```

---
*Cmdlet/module names verified against Windows 11 Pro 24H2 (build 26100) on 2026-06-24. `manage-bde` is `Configuration Tool version 10.0.26100`. If targeting a different Windows build or PowerShell major version, verify `Get-Command -Module <name>` and parameter support (`(Get-Command X).Parameters.ContainsKey('WhatIf')`) against current docs.*
