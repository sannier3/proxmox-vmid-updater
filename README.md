# PROXMOX-VMID-UPDATER
Interactive Proxmox VM/LXC ID renaming script with automatic logging, safety checks, and storage path updates.

## Description

Interactive Bash script to safely rename a QEMU VM or LXC container VMID on Proxmox VE.
• Verifies source ID exists and target ID is free (cluster-wide)
• Stops the instance cleanly (with confirmation)
• Renames config, LVM volumes and file-based storage (including NFS/CIFS/GlusterFS directories)
• Updates snapshots, vmstate, backups, vzdump & replication jobs, firewall rules and ACLs
• Logs every action with timestamp to console and rename-vmid.log

This script does **not** alter file integrity, never sends data off the nodes it runs on, and uses only local Proxmox APIs and commands.

## Prerequisites

• Proxmox VE 6.x/7.x (bash, pvesh, pvecm, pvesm, qm, pct)
• dialog
• root privileges

## Installation (single-line)

Run this on any Proxmox node to download & execute the latest version:

```
bash -c "$(curl -fsSL https://raw.githubusercontent.com/sannier3/proxmox-vmid-updater/main/rename-vmid.sh)"
```

## Usage

1. Become root (`sudo -i` or `su –`)
2. Paste the installation command above
3. Follow dialogs to select “qemu” or “lxc”, enter old and new VMID, confirm shutdown and summary
4. On confirmation, the VMID is migrated everywhere; on cancel or Ctrl-C any lock is released and no changes are made

## Supported storage types

• LVM (lvrename + config update)
• File-based image dirs (mv + sed)
• Network filesystems (NFS, CIFS, GlusterFS—treated as file-based and renamed accordingly)

## Planned in a future update

• ZFS datasets & snapshots support
• Hook scripts & Cloud-Init integration (detect & rename related scripts)
• Quorum verification before operations (skippable via manual override)
• Replication job updates (in addition to vzdump)
• Firewall rule parsing and VMID renaming if the VM uses firewall or references its ID
• Improved VM/LXC lock/unlock handling to avoid .lock conflicts

## Security & Integrity

• No external connections—only accesses local Proxmox cluster and filesystems
• Uses Proxmox CLI/API (`pvesh`, `qm`, `pct`) exclusively
• All operations logged locally; no credentials or data are exfiltrated

## License

GPL v3

## Support

Report issues or contribute on GitHub:
[https://github.com/sannier3/proxmox-vmid-updater/issues](https://github.com/sannier3/proxmox-vmid-updater/issues)
