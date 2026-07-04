# Proxmox VE — coder reference

This covers automating Proxmox VE (PVE) from the node's shell: the REST API via `pvesh` (which walks the same API tree the web UI and the `pvedaemon`/`pveproxy` services serve), plus the higher-level wrappers `qm` (QEMU/KVM VMs), `pct` (LXC containers), `pvesm` (storage), and `vzdump` (backups). The primary, safest entry point for status/listing is **read-only** `... list` / `... status` / `... config` and `pvesh get`; this agent WRITES scripts/config and runs only read-only queries — it never auto-runs destructive operations (see Security).

## Key tools / cmdlets / APIs
- `pvesh get <api-path>` — read any API endpoint as the root user, e.g. `pvesh get /nodes`, `pvesh get /cluster/resources`. Read-only.
- `pvesh get <path> --output-format json` — same, but machine-parseable JSON (also `yaml`, `json-pretty`); pipe to `jq`. Read-only.
- `pvesh create|set|delete <path>` — the write/modify/delete verbs of the API (POST/PUT/DELETE). `create`/`delete` can be destructive — see Security.
- `qm list` / `qm status <vmid>` / `qm config <vmid>` — list VMs / one VM's runtime status / its config. Read-only.
- `qm create|start|shutdown|stop|reboot|clone|destroy <vmid> ...` — VM lifecycle (`shutdown` = graceful ACPI, `stop` = hard power-off, `destroy` = delete; see Security).
- `pct list` / `pct status <vmid>` / `pct config <vmid>` — list LXC containers / status / config. Read-only.
- `pct create|start|shutdown|stop|destroy <vmid> ...` — container lifecycle (same verbs/semantics as `qm`; `destroy` deletes — see Security).
- `pvesm status` / `pvesm list <storage>` — list storage pools (type/usage) / volumes on one pool. Read-only.
- `vzdump <vmid> --storage <store> ...` — create a backup of a VM/CT (no true dry-run — see Security).
- `qmrestore <archive> <newvmid>` / `pct restore <newvmid> <archive>` — restore a VM/CT from a backup archive into a **new** VMID.
- `pveum user token add <user> <tokenid> ...` — create an API token (preferred over password auth for scripts; root-only action — see Security).
- `pvenode` / `pvecm` — per-node tasks / cluster membership (`pvecm status`, `pvecm nodes` are read-only; `pvecm add`/`pvecm delnode` change the cluster — see Security).

## Common task patterns
Read/query first: every example in this section except where noted is read-only. Inspect what exists before you generate anything that changes it.

**1. Inventory the node/cluster (read-only).** Start here — see what's actually running before writing any change.
```bash
pvesh get /nodes --output-format json | jq -r '.[].node'   # node names
pvesh get /cluster/resources --output-format json \
  | jq -r '.[] | select(.type=="vm" or .type=="lxc") | "\(.vmid)\t\(.type)\t\(.name)\t\(.status)"'
qm list            # VMs on THIS node (VMID, name, status, mem, bootdisk, pid)
pct list           # LXC containers on THIS node
pvesm status       # storage pools: type, enabled, total/used/avail
```

**2. Inspect one guest before touching it (read-only).** Always dump config + current status first; the config is the source of truth for what a write would change.
```bash
qm config 100                 # full VM config (cores, memory, disks, net, boot order)
qm status  100                # current run state: status running|stopped, plus uptime/pid
pct config 200                # full LXC config (rootfs, net, features, unprivileged?)
pct status 200
# Same data via the API (handy when scripting / parsing):
pvesh get /nodes/$(hostname)/qemu/100/status/current --output-format json | jq
```

**3. Find a free VMID before creating anything (read-only).** Re-using a live VMID is a classic foot-gun; ask the cluster for the next free id.
```bash
pvesh get /cluster/nextid          # returns the next unused VMID, e.g. 101
# or list everything in use to choose deliberately:
pvesh get /cluster/resources --output-format json | jq -r '.[].vmid' | sort -n | uniq
```

**4. The SHAPE of creating a VM (review before running).** This is the canonical `qm create` form. It does write — emit it for operator review; do NOT auto-run. Note the explicit VMID from pattern 3, pinned resources, and an attached storage volume.
```bash
# Generated for OPERATOR REVIEW — creates a stopped VM shell (no auto-start):
qm create 101 \
  --name web-01 \
  --cores 2 --memory 2048 \
  --net0 virtio,bridge=vmbr0 \
  --scsihw virtio-scsi-single \
  --scsi0 local-lvm:32 \
  --ide2 local:iso/debian-12-netinst.iso,media=cdrom \
  --boot order=scsi0\;ide2 \
  --ostype l26
# Verify the result (read-only) before starting it:
qm config 101
```

**5. The SHAPE of creating an LXC container (review before running).** `pct create` needs a template (download targets are listed read-only via `pveam`). Writes — operator review.
```bash
pveam available --section system        # READ-ONLY: list downloadable CT templates
pveam list local                        # READ-ONLY: templates already on 'local' storage
# Generated for OPERATOR REVIEW — creates an unprivileged container:
pct create 201 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
  --hostname ct-01 \
  --cores 1 --memory 1024 --swap 512 \
  --rootfs local-lvm:8 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --unprivileged 1 --features nesting=0
pct config 201                          # verify before start
```

**6. Start / graceful-stop a guest (state change — review before running).** `shutdown` is the graceful ACPI path and is the safe default; never script a hard `stop` as the first choice. These change run state — emit for review, don't auto-run.
```bash
# Generated for OPERATOR REVIEW:
qm start 101                            # power on the VM
qm shutdown 101 --timeout 120          # graceful ACPI shutdown, wait up to 120s
pct start 201
pct shutdown 201 --timeout 60
# Check it took effect (read-only):
qm status 101 ; pct status 201
```

**7. Storage + backup listing, then the SHAPE of a backup (review before running).** Query storage first; a backup consumes space and I/O.
```bash
pvesm status                            # READ-ONLY: which stores exist + free space
pvesm list local                        # READ-ONLY: volumes/backups on 'local'
ls -lh /var/lib/vz/dump/ 2>/dev/null    # READ-ONLY: default backup dir on 'local'
# Generated for OPERATOR REVIEW — snapshot-mode backup of VM 101 to 'local':
vzdump 101 --storage local --mode snapshot --compress zstd --notes-template "{{guestname}}"
```

**8. Parse status in a script (read-only, offline-safe).** When generating monitoring/report scripts, prefer the JSON API + `jq` over screen-scraping `qm list`.
```bash
NODE=$(hostname)
# All VMs on this node with status + memory, as TSV:
pvesh get /nodes/$NODE/qemu --output-format json \
  | jq -r '.[] | [.vmid, .name, .status, .maxmem] | @tsv'
# One container's CPU/mem live metrics:
pvesh get /nodes/$NODE/lxc/201/status/current --output-format json \
  | jq '{status, cpu, mem, maxmem, uptime}'
```

## Pitfalls
- **VMID is global and re-use is silent disaster.** VMIDs are unique per cluster, not per node. Always pull `pvesh get /cluster/nextid` (or check `/cluster/resources`) before `create`/`clone`/`restore` — re-using an id collides with a live guest. There is no "rename VMID" — choose right the first time.
- **`stop` vs `shutdown`.** `qm stop` / `pct stop` is a hard power-cut (like pulling the plug) and risks filesystem corruption / data loss in the guest. `shutdown` is the graceful ACPI path. Scripts should default to `shutdown --timeout N`; only fall back to `stop` deliberately.
- **`destroy` is immediate and unrecoverable, and `--purge` makes it worse.** `qm destroy` / `pct destroy` delete the guest and its disks now — there is no recycle bin and **no `--dry-run`**. `--purge` additionally strips the VMID from backup jobs/HA/replication. Never put these in an auto-run path (see Security).
- **`vzdump` has no real dry-run, and `--mode` matters.** `--mode snapshot` needs storage/filesystem snapshot support; `--mode suspend` pauses the guest; `--mode stop` powers it off for the backup (downtime). Picking the wrong mode either fails or causes an outage. Confirm the mode with the operator; verify storage free space (`pvesm status`) first.
- **Storage names are config, not paths, and types differ.** `local-lvm` (LVM-thin) holds VM/CT disk images; `local` (dir) holds ISOs, templates, and backups by default. A store only accepts the *content types* it's configured for, so e.g. you cannot put a disk on a backup-only store. Check `pvesm status` and the store's `content` setting before referencing it in `create`.
- **`qm`/`pct` act on the LOCAL node only.** They manage guests on the node where you run them. For cluster-wide views use `pvesh get /cluster/resources`; to act on a guest residing elsewhere, target that node (SSH / the right API path), or it won't be found.
- **Root / token scope.** `pvesh` and the wrappers run as `root@pam` from the shell with full rights. Scripts authenticating over the API should use a **scoped API token** (least privilege), not the root password — see Security.

## Security — OPERATOR REVIEW REQUIRED
This agent writes Proxmox automation and runs only the **read-only** queries above (`... list` / `status` / `config`, `pvesh get`, `pvesm status`, `pveam list/available`). Everything that creates, changes run-state, deletes, or alters the cluster is for the human to run deliberately. Emit those as commented scripts tagged for review. Note: several Proxmox destructive ops have **no `--dry-run`/`-WhatIf`** — for those the safe substitute is a read-only *preview* (list/config) of exactly what would be affected, shown alongside.

- **Destroying a VM or container — OPERATOR REVIEW REQUIRED — do not auto-run.** `qm destroy` / `pct destroy` permanently delete the guest and its disks; `--purge` also removes it from backup/HA/replication jobs. **No `--dry-run` exists.** Preview with read-only config first.
  ```bash
  # PREVIEW (read-only, safe): prove which guest + disks this would delete
  qm config 101          # or: pct config 201   — lists the disks/volumes at risk
  qm status 101          # confirm you have the right, expected guest
  # OPERATOR-ONLY, irreversible data loss — run manually after reviewing the preview:
  # qm destroy 101                 # add --purge to also clean job/HA refs (more destructive)
  # pct destroy 201
  ```

- **Hard-stopping a running guest — OPERATOR REVIEW REQUIRED — do not auto-run.** `qm stop` / `pct stop` is a hard power-off (possible in-guest data loss / FS corruption). Prefer graceful `shutdown`.
  ```bash
  # PREVIEW (read-only): is it even running, and what is it?
  qm status 101 ; qm config 101 | grep -E '^name|^onboot'
  # PREFERRED (graceful) — still a state change, so operator-run:
  # qm shutdown 101 --timeout 120
  # OPERATOR-ONLY, abrupt power-cut — last resort:
  # qm stop 101
  ```

- **Deleting storage volumes / backups — OPERATOR REVIEW REQUIRED — do not auto-run.** Removing a disk image or a backup archive is permanent; deleting the wrong volume orphans or destroys a guest's data. **No `--dry-run`.** List first.
  ```bash
  # PREVIEW (read-only): exactly what lives on the store
  pvesm list local            # backups, ISOs, templates on 'local'
  pvesm list local-lvm        # disk images
  # OPERATOR-ONLY, permanent:
  # pvesm free local:backup/vzdump-qemu-101-....vma.zst     # delete one backup archive
  # pvesm free local-lvm:vm-101-disk-0                      # delete a VM disk volume
  ```

- **Removing/disabling a storage pool — OPERATOR REVIEW REQUIRED — do not auto-run.** Detaching or deleting a storage definition can make every guest disk on it unavailable cluster-wide.
  ```bash
  # PREVIEW (read-only): what would be affected
  pvesm status
  pvesh get /storage --output-format json | jq
  # OPERATOR-ONLY:
  # pvesm remove <storeid>                  # removes the storage *definition* from PVE config
  ```

- **Cluster membership changes — OPERATOR REVIEW REQUIRED — do not auto-run.** Adding/removing nodes or editing the cluster (corosync/quorum) can break quorum and take the whole cluster read-only or offline. There is no dry-run; treat these as manual, change-controlled actions.
  ```bash
  # PREVIEW (read-only):
  pvecm status        # quorum, votes, members
  pvecm nodes
  # OPERATOR-ONLY — can break quorum / the cluster:
  # pvecm add <existing-cluster-ip>     # join this node to a cluster
  # pvecm delnode <nodename>            # remove a node (do this carefully, per docs)
  ```

- **Migrating a guest — OPERATOR REVIEW REQUIRED — do not auto-run.** `qm migrate` / `pct migrate` moves a guest between nodes (live or offline) and can cause downtime, storage moves, and brief unavailability. No `--dry-run`; review target node + storage first.
  ```bash
  # PREVIEW (read-only): where does it live now, where could it go
  qm status 101 ; pvecm nodes
  # OPERATOR-ONLY, causes downtime/storage movement:
  # qm migrate 101 <target-node> --online        # live migrate (shared storage)
  # pct migrate 201 <target-node>                 # CT migrate (restart-migrate)
  ```

- **API tokens, users, and ACLs — review before applying.** Creating users/tokens or granting roles changes who can do what to the whole virtualization platform. Scripts should authenticate with a **scoped, least-privilege API token**, never the root password; never hard-code a token secret in a generated file (it is shown only once on creation). Treat any generated file containing a token/secret as OPERATOR REVIEW REQUIRED.
  ```bash
  # PREVIEW (read-only): existing users / tokens / permissions
  pveum user list ; pveum acl list
  # OPERATOR-ONLY — creates a token (the secret is printed ONCE; store it safely):
  # pveum user token add svc@pve automation --privsep 1
  # pveum acl modify /vms --tokens 'svc@pve!automation' --roles PVEVMUser
  ```

> Notes for the agent: when offline or unsure of an exact flag/endpoint (e.g. a less-common `vzdump`/`pvesm`/`pveum` option, or whether a given subcommand exists), **verify against current docs** (`man qm`, `man pct`, `man vzdump`, `pvesh ls <path>` to discover the API tree, `pvesh usage <path>`) rather than guessing — do NOT invent flags. For autonomous work, stay on the read-only queries in *Common task patterns*; route every create/change/delete/cluster action to the human via the reviewed scripts above.
