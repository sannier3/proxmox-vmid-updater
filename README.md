# Proxmox VMID Updater

Interactive, **safe and transactional** renaming of a QEMU VM or LXC container **VMID** on Proxmox VE - config, storage volumes, snapshots, backups, HA and firewall included.

**__Readme Languages__** [![English](https://img.shields.io/badge/lang-English-blue.svg)](README.md) [![Français](https://img.shields.io/badge/lang-Français-lightgrey.svg)](README.fr.md) ![License](https://img.shields.io/badge/License-GPLv3-success?style=flat-square)

![Proxmox VE](https://img.shields.io/badge/Proxmox%20VE-8.x%2B-E57000?style=flat-square) ![Bash](https://img.shields.io/badge/Bash-script-4EAA25?style=flat-square&logo=gnubash&logoColor=white) ![Version](https://img.shields.io/badge/version-1.3.0-informational?style=flat-square)

---

> [!WARNING]
> This script renames VMIDs and moves **real storage volumes** and **`/etc/pve`** files.
> It is transactional and rolls back on failure, but **use it at your own risk**:
> always keep a working backup and test on a disposable guest first.

## Contents

- [What it does](#what-it-does)
- [Requirements](#requirements)
- [Quick run](#quick-run)
- [Supported storage types](#supported-storage-types)
- [How to use](#how-to-use)
- [Safety gates](#safety-gates)
- [Safety & integrity](#safety--integrity)
- [Testing & help wanted](#testing--help-wanted)
- [Contributing](#contributing)
- [License](#license)

---

## What it does

Renaming a VMID by hand means editing the config, renaming every disk, every
snapshot/vmstate volume, the backups, the HA resource, the firewall file… and
getting **all** of it consistent. This script does it for you, in one pass, and
undoes everything automatically if a step fails.

- **Cluster-wide checks** - verifies the source VMID exists and the target VMID is free on every node.
- **Clean shutdown** - prompts and stops the VM/CT if it is running.
- **Config rename** - `/etc/pve/.../<old>.conf` → `<new>.conf`.
- **Storage volumes** - LVM, ZFS, Ceph/RBD and file-based images (see the [table below](#supported-storage-types)).
- **Snapshots & vmstate** - renamed both in the config and on disk.
- **Backups & jobs** - `vzdump` dumps and `jobs.cfg` / `replication.cfg` entries updated; PBS snapshots are detected and reported.
- **Pools & ACLs** - `acl:` / `pool:` lines in `/etc/pve/user.cfg` updated cluster-wide.
- **HA & firewall** - the HA resource is disabled during the rename, its SID renamed and its original state restored; the per-guest `/etc/pve/firewall/<VMID>.fw` is moved.
- **Transactional with rollback** - the original config stays untouched until every rename succeeds; on any failure all renames are reverted and existing targets are never overwritten.
- **Full logging** - every action is timestamped to the console and to `rename-vmid.sh.log`.

---

## Requirements

- **Proxmox VE 8.x or newer** (`bash`, `pvesh`, `pvecm`, `pvesm`, `qm`, `pct`)
- **`dialog`** (the script offers to install it if missing)
- **root** privileges

---

## Quick run

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/sannier3/proxmox-vmid-updater/main/rename-vmid.sh)"
```

Then follow the interactive prompts.

---

## Supported storage types

| Storage | Renamed via |
| --- | --- |
| **LVM / LVM-thin** (incl. templates `base-*` and cloud-init drives) | `lvrename` |
| **ZFS** datasets & snapshots (incl. linked clones) | `zfs rename` |
| **Ceph/RBD** block images (incl. external clusters) | `rbd rename` |
| **File-based** under `images/<VMID>/…` (local, NFS, CIFS, GlusterFS, CephFS) | `mv` |

> [!NOTE]
> New: bind/device mount points (LXC `mpX: /host/path`) and ISO / empty CD-ROM drives
> are detected and **left untouched** automatically, following issue
> [#5](https://github.com/sannier3/proxmox-vmid-updater/issues/5).

---

## How to use

1. Become **root** on the node that hosts the guest.
2. Run the [Quick run](#quick-run) command (or `bash rename-vmid.sh`).
3. Enter the **current VMID**, then the **new VMID** when prompted.
4. Confirm the clean shutdown and **review the summary** of everything that will change.
5. On confirmation, the script renames everything in one transactional pass.

> [!TIP]
> The summary screen is read-only - nothing is modified until you confirm "Apply".

---

## Safety gates

Before touching anything, the script **aborts cleanly and changes nothing** if:

- a disk or saved state lives on an **offline / disabled storage**;
- the guest is a **template that still has linked clones**;
- a **replication job** exists for the guest;
- the guest is **busy** (a config `lock:` or an active task such as a backup,
  migration, snapshot, clone or disk-move is in flight).

The target VMID is also re-checked free, and the guest re-checked idle, right
before the rename is applied.

---

## Safety & integrity

- **No external connections** - uses only local Proxmox APIs and mounted filesystems.
- **Read-only until confirmation** - every destructive change is gated behind a confirmation prompt.
- **Atomic & reversible** - volume renames are tracked and rolled back automatically if any step fails; the config is committed only once all renames succeed.
- **Fully logged** - all actions go into `rename-vmid.sh.log` in the current directory.

---

## Testing & help wanted

This script touches storage volumes and `/etc/pve`, so broad real-world testing
across different setups is extremely valuable. **If you can help, please test one
or more of the scenarios below on a disposable guest** (use a throwaway VMID and
make sure you have a working backup first).

Scenarios to validate:

- [ ] **LXC** with a `mp0` bind mount (e.g. `mp0: /mnt/storage,mp=/data`) - must be left untouched
- [X] **QEMU on LVM / LVM-thin** (`local-lvm`), simple single disk
- [X] **QEMU on ZFS** and **LXC rootfs on a ZFS subvol**
- [ ] **Linked clone** (ZFS or file-based) - only the child volume is renamed
- [ ] VM with a **cloud-init** drive
- [ ] VM with a **snapshot + vmstate** (RAM state)
- [ ] VM with a per-guest **firewall** (`/etc/pve/firewall/<VMID>.fw`)
- [ ] **HA-managed** guest - resource disabled during rename, original state restored after
- [ ] **Ceph/RBD** volume (local cluster, and an external cluster if you have one)
- [ ] **Safety gates** abort cleanly: offline/disabled storage, template with linked clones, existing replication job, busy/locked guest (e.g. rename attempted while a backup runs)
- [ ] **Rollback** path: force a failure (e.g. a target volume that already exists) and confirm the guest is left intact under the old VMID
- [ ] **Cluster** vs **standalone** node, with and without quorum

> [!IMPORTANT]
> **Did you run one or more of these tests?** Please help the project:
> - open an **issue** with your result (success or failure), the storage type used, and the relevant lines from `rename-vmid.sh.log`; **or**
> - submit a **pull request** directly if you have a fix or an improvement.
>
> Even a simple *"tested scenario X on storage Y, works as expected"* report is
> useful - it tells everyone which configurations are field-validated.

---

## Contributing

Issues and pull requests are welcome:
[github.com/sannier3/proxmox-vmid-updater/issues](https://github.com/sannier3/proxmox-vmid-updater/issues)

---

## License

Distributed under the **GNU GPL v3**.
