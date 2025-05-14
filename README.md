Here’s the updated **README** for **v1.2.0**, in plain English and natural markdown formatting:

---

# PROXMOX-VMID-UPDATER  v1.2.0

Interactive Bash script to safely rename a QEMU VM or LXC container VMID on Proxmox VE, with:

* **Cluster-wide checks**
  Verify the source VMID exists and the target VMID is free across all nodes.
* **Clean shutdown**
  Prompt and stop the VM/CT if it’s running.
* **Config renaming**
  Move `/etc/pve/.../<old>.conf` → `<new>.conf`.
* **Storage updates**

  * **LVM** volumes (via `lvrename` + config update)
  * **ZFS** datasets & snapshots (via `zfs rename` + config update)
  * **File-based** images under `…/images/<VMID>/…` (local FS, NFS, CIFS, GlusterFS, CephFS)
* **Snapshot & vmstate** entries
  Renamed both in the config file and on disk.
* **Backups & jobs**
  Rename `vzdump`, replication logs and entries to use the new VMID.
* **Pools & ACLs**
  Update `/etc/pve/user.cfg` cluster-wide.
* **Full logging**
  All operations timestamped to console and `rename-vmid.sh.log`.

---

## Prerequisites

* **Proxmox VE 6.x / 7.x**
  (commands: `bash`, `pvesh`, `pvecm`, `pvesm`, `qm`, `pct`)
* **dialog**
* **Root** privileges

---

## Quick Run

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/sannier3/proxmox-vmid-updater/main/rename-vmid.sh)"
```

Then follow the interactive prompts.

---

## Supported Storage Types

* **LVM** logical volumes
* **ZFS** datasets & snapshots
* **File-based** images under `storage/images/<VMID>/…`
  (treats NFS, CIFS, GlusterFS, CephFS mounts exactly like local files)

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
  Every destructive change is gated behind a “Yes/No” prompt.
* **Fully logged**
  All actions go into `rename-vmid.sh.log` in your current directory.

---

## License

Distributed under **GPL v3**.

---

## Get Help or Contribute

Open an issue or submit a PR on GitHub:
[https://github.com/sannier3/proxmox-vmid-updater/issues](https://github.com/sannier3/proxmox-vmid-updater/issues)
