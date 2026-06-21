# PROXMOX-VMID-UPDATER  v1.3.0

Interactive Bash script to safely rename a QEMU VM or LXC container VMID on Proxmox VE, with:

* **Cluster-wide checks**
  Verify the source VMID exists and the target VMID is free across all nodes.
* **Clean shutdown**
  Prompt and stop the VM/CT if it’s running.
* **Config renaming**
  Move `/etc/pve/.../<old>.conf` → `<new>.conf`.
* **Storage updates**

  * **LVM** volumes (via `lvrename` + config update), incl. templates (`base-*`) and cloud-init drives
  * **ZFS** datasets & snapshots (via `zfs rename` + config update), incl. linked clones
  * **Ceph/RBD** images (via `rbd rename` + config update)
  * **File-based** images under `…/images/<VMID>/…` (local FS, NFS, CIFS, GlusterFS, CephFS)
  * **Bind/device mount points** (e.g. `mp0: /mnt/storage`) are detected and left untouched
* **Snapshot & vmstate** entries
  Renamed both in the config file and on disk.
* **Backups & jobs**
  Rename `vzdump`, replication logs and entries to use the new VMID.
* **Pools & ACLs**
  Update `/etc/pve/user.cfg` cluster-wide.
* **HA & firewall**
  Temporarily disable the HA resource (so the CRM can't restart the guest mid-rename),
  update `/etc/pve/ha/resources.cfg`, restore its original state, and rename per-guest
  `/etc/pve/firewall/<VMID>.fw`.
* **Pre-flight safety gates** (abort cleanly, change nothing)
  * a disk or saved state on an **offline/disabled storage**;
  * a **template that still has linked clones**;
  * an existing **replication job** for the guest.
* **Transactional apply with rollback**
  The original config is kept untouched until every volume rename succeeds; on any
  failure all renames are reverted automatically. Existing target files are never
  overwritten.
* **Full logging**
  All operations timestamped to console and `rename-vmid.sh.log`.

---

## Prerequisites

* **Proxmox VE 8.x or newer**
  (commands: `bash`, `pvesh`, `pvecm`, `pvesm`, `qm`, `pct`)
* **dialog**
* **Root** privileges

---

## Quick Run

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/sannier3/proxmox-vmid-updater/dev/rename-vmid.sh)"
```

Then follow the interactive prompts.

---

## Supported Storage Types

* **LVM** logical volumes (incl. templates `base-*` and cloud-init drives)
* **ZFS** datasets & snapshots (incl. linked clones)
* **Ceph/RBD** block images
* **File-based** images under `storage/images/<VMID>/…`
  (treats NFS, CIFS, GlusterFS, CephFS mounts exactly like local files)

> Bind/device mount points (LXC `mpX: /host/path`) and ISO/empty CD-ROM drives
> are detected and skipped automatically.

---

## Usage Steps

1. Become root
2. Run the bash command above
3. Enter **old VMID** and **new VMID** when prompted
4. Confirm clean shutdown and review the summary
5. On confirmation, the script renames everything in one go

---

## Security & Integrity

* **No external connections**
  Uses only local Proxmox APIs and mounted filesystems.
* **Read-only until confirmation**
  Every destructive change is gated behind a “Yes/No” prompt, and risky scenarios
  (offline storage, linked clones, replication) abort before anything is touched.
* **Atomic & reversible**
  Volume renames are tracked and rolled back automatically if any step fails; the
  config is only committed once all renames succeed.
* **Fully logged**
  All actions go into `rename-vmid.sh.log` in your current directory.

---

## License

Distributed under **GPL v3**.

---

## Get Help or Contribute

Open an issue or submit a PR on GitHub:
[https://github.com/sannier3/proxmox-vmid-updater/issues](https://github.com/sannier3/proxmox-vmid-updater/issues)
