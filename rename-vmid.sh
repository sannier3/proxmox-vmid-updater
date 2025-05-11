#!/bin/bash
set -euo pipefail

### ————————————————
### Logging setup
LOGFILE="${PWD}/rename-vmid.sh.log"
touch "$LOGFILE"

log(){
  local ts msg
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  msg="$ts $*"
  echo "$msg" | tee -a "$LOGFILE"
}

### 0) Must be root
if [[ "$(id -u)" -ne 0 ]]; then
  echo "Please run as root!" >&2
  exit 1
fi
log "Running as root confirmed"

### 1) Ensure dialog, pvesh, pvecm, pvesm
NEEDS=()
for cmd in dialog pvesh pvecm pvesm; do
  command -v "$cmd" >/dev/null || NEEDS+=("$cmd")
done
if (( ${#NEEDS[@]} )); then
  echo "Missing packages: ${NEEDS[*]}"
  read -rp "Install via apt? [Y/n] " ans
  ans=${ans:-Y}
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    log "Installing: ${NEEDS[*]}"
    apt update && apt install -y "${NEEDS[@]}"
  else
    echo "Cannot continue without these tools." >&2
    exit 1
  fi
fi

# 1.5) WARNING DIALOG
dialog --title "⚠️ WARNING – USE AT YOUR OWN RISK!" \
  --msgbox "\
This script renames Proxmox VMIDs after confirmation.
If you do not fully understand what it does, you risk corrupting your infrastructure.
Potential bugs – developed in my spare time, with no guarantees despite thorough testing.

For issues or feature requests, please open a ticket at:
https://github.com/sannier3/proxmox-vmid-updater/issues

USE AT YOUR OWN RISK!" 14 70

### 2) Select type
TYPE=$(dialog --stdout --menu "What to rename?" 10 40 2 \
  qemu "QEMU VM" \
  lxc  "LXC Container") || exit 1
log "Type: $TYPE"

### 3) Determine cluster nodes (or single node)
CLUSTER_NODES=()
if pvecm nodes &>/dev/null; then
  mapfile -t CLUSTER_NODES < <(pvecm nodes | awk 'NR>1 {print $3}')
  log "Cluster nodes: ${CLUSTER_NODES[*]}"
else
  NODE=$(hostname)
  CLUSTER_NODES=("$NODE")
  log "Not in a cluster, using local node: $NODE"
fi

### 4) Ask old ID, verify exists
while true; do
  ID_OLD=$(dialog --stdout --inputbox "Enter current ID (ESC to quit):" 8 40) || exit 1
  log "Old ID: $ID_OLD"
  [[ -n "$ID_OLD" ]] || { dialog --msgbox "Empty ID!" 6 40; continue; }
  FOUND=0
  for N in "${CLUSTER_NODES[@]}"; do
    if pvesh get "/nodes/$N/$TYPE" --output-format=json 2>/dev/null \
       | grep -q "\"vmid\"[[:space:]]*:[[:space:]]*$ID_OLD"; then
      FOUND=1; break
    fi
  done
  (( FOUND )) && break || dialog --msgbox "ID $ID_OLD not found." 6 50
done

### 5) Ask new ID, verify free
while true; do
  ID_NEW=$(dialog --stdout --inputbox "Enter new free ID:" 8 40) || exit 1
  log "New ID: $ID_NEW"
  [[ -n "$ID_NEW" ]] || { dialog --msgbox "Empty ID!" 6 40; continue; }
  EXISTS=0
  for N in "${CLUSTER_NODES[@]}"; do
    for T in qemu lxc; do
      if pvesh get "/nodes/$N/$T" --output-format=json 2>/dev/null \
         | grep -q "\"vmid\"[[:space:]]*:[[:space:]]*$ID_NEW"; then
        EXISTS=1; break 2
      fi
    done
  done
  (( ! EXISTS )) && break || dialog --msgbox "ID $ID_NEW already in use." 6 50
done

### 6) Find host node holding ID_OLD
NODE_ASSIGNED=""
for N in "${CLUSTER_NODES[@]}"; do
  if pvesh get "/nodes/$N/$TYPE" --output-format=json 2>/dev/null \
     | grep -q "\"vmid\"[[:space:]]*:[[:space:]]*$ID_OLD"; then
    NODE_ASSIGNED=$N; break
  fi
done
if [[ -z "$NODE_ASSIGNED" ]]; then
  dialog --msgbox "Host node not found for $ID_OLD." 6 50
  exit 1
fi
log "Host node: $NODE_ASSIGNED"

### 7) Locate config file
if [[ "$TYPE" == qemu ]]; then
  CONF_PATH="/etc/pve/nodes/$NODE_ASSIGNED/qemu-server/$ID_OLD.conf"
else
  CONF_PATH="/etc/pve/nodes/$NODE_ASSIGNED/lxc/$ID_OLD.conf"
fi
if [[ ! -f "$CONF_PATH" ]]; then
  dialog --msgbox "Config not found: $CONF_PATH" 6 60
  exit 1
fi
CONF_DIR=$(dirname "$CONF_PATH")
log "Config: $CONF_PATH"

### 8) Stop instance if needed
if [[ "$TYPE" == qemu ]]; then
  STATE=$(qm status "$ID_OLD" 2>/dev/null | awk '{print $2}')
else
  STATE=$(pct status "$ID_OLD" 2>/dev/null | awk '{print $2}')
fi
log "Raw status: $STATE"
if [[ "$STATE" != stopped ]]; then
  dialog --yesno "Instance is '$STATE'. Stop it?" 7 50 && {
    log "Stopping $TYPE $ID_OLD"
    if [[ "$TYPE" == qemu ]]; then qm shutdown "$ID_OLD"; else pct shutdown "$ID_OLD"; fi
    for i in {1..20}; do
      sleep 3
      if [[ "$TYPE" == qemu ]]; then
        STATE=$(qm status "$ID_OLD" 2>/dev/null | awk '{print $2}')
      else
        STATE=$(pct status "$ID_OLD" 2>/dev/null | awk '{print $2}')
      fi
      [[ "$STATE" == stopped ]] && break
    done
    if [[ "$STATE" != stopped ]]; then
      dialog --msgbox "Failed to stop." 6 40
      exit 1
    fi
    log "Instance stopped"
  } || exit 1
fi

### 9) Active storages
mapfile -t ACTIVE_STORAGES < <(pvesm status | awk 'NR>1 {print $1}')
log "Storages: ${ACTIVE_STORAGES[*]}"

### 10) Gather block volumes from the main section
mapfile -t VOL_OLD < <(
  sed '/^\[/{q}' "$CONF_PATH" \
    | grep -E '^(scsi|ide|virtio|sata|efidisk|tpmstate|unused)[0-9]+:' \
    | sed -E 's/^[^:]+:[[:space:]]*//' \
    | cut -d',' -f1
)
log "Raw volumes: ${VOL_OLD[*]}"

### 10b) Gather vmstate entries from all snapshots
mapfile -t VMSTATE_OLD < <(
  grep -E '^vmstate:' "$CONF_PATH" \
    | sed -E 's/^vmstate:[[:space:]]*//' \
    | cut -d',' -f1
)
log "Snapshot states: ${VMSTATE_OLD[*]}"

### 10c) Gather snapshot section names
mapfile -t SNAP_SECTIONS < <(grep -Po '^\[\K[^\]]+' "$CONF_PATH")
log "Snapshot sections: ${SNAP_SECTIONS[*]}"

### 11) Classify volumes LVM vs file
LVM_OLD=()
FILE_OLD=()
for vol in "${VOL_OLD[@]}"; do
  st=${vol%%:*}; rel=${vol#*:}
  if ! printf '%s\n' "${ACTIVE_STORAGES[@]}" | grep -qx "$st"; then
    log "Skipping volume $vol: storage '$st' not active"
    continue
  fi
  stype=$(pvesh get /storage/"$st" --output-format=json 2>/dev/null \
          | grep -Po '"type"\s*:\s*"\K[^"]+' || echo "")
  if [[ "$stype" =~ lvm ]]; then
    LVM_OLD+=("$vol")
  else
    FILE_OLD+=("$vol")
  fi
done
mapfile -t FILE_OLD < <(printf "%s\n" "${FILE_OLD[@]}" | sort -u)
log "LVM volumes: ${LVM_OLD[*]}"
log "File volumes (deduped): ${FILE_OLD[*]}"

### 12) Gather backups
BKDIRS=(/var/lib/vz/dump /mnt/pve/*/dump)
BK_OLD=()
for d in "${BKDIRS[@]}"; do
  log "Searching backups in $d"
  [[ -d "$d" ]] || continue
  while IFS= read -r f; do BK_OLD+=("$f"); done \
    < <(find "$d" -type f -name "*-${ID_OLD}-*" 2>/dev/null)
done
log "Backups found: ${#BK_OLD[@]} files"

### 13) Build summary
SUMMARY=/tmp/rename_summary.txt
:> "$SUMMARY"
{
  echo "🚀 Renaming $TYPE $ID_OLD → $ID_NEW (host $NODE_ASSIGNED)"
  echo "------------------------------------------------------"
  echo; echo "• Config:"
  echo "    $CONF_PATH → $CONF_DIR/$ID_NEW.conf"
  echo

  echo "• LVM volumes:"
  for vol in "${LVM_OLD[@]}"; do
    st=${vol%%:*}; oldlv=${vol#*:}
    vg=$(pvesh get /storage/"$st" --output-format=json \
         | grep -Po '"vgname"\s*:\s*"\K[^"]+' || echo "")
    if [[ -z "$vg" ]]; then
      echo "    ❌ SKIP: no VG for $vol"
    else
      newlv="vm-${ID_NEW}-disk-${oldlv##*-}"
      echo "    $vg/$oldlv → $vg/$newlv"
    fi
  done
  echo; echo "• LVM snapshots:"
  mapfile -t SNAP_LV_OLD < <(
    lvs --noheadings -o lv_name,vg_name \
      | awk '{print $1 ":" $2}' \
      | grep "^snap_vm-${ID_OLD}-disk-"
  )
  for entry in "${SNAP_LV_OLD[@]}"; do
    old_snap=${entry%%:*}; vg=${entry#*:}
    suffix=${old_snap#snap_vm-${ID_OLD}-disk-}
    echo "    $vg/$old_snap → $vg/snap_vm-${ID_NEW}-disk-${suffix}"
  done

  echo; echo "• Disk volumes (file & unused):"
  for vol in "${FILE_OLD[@]}"; do
    echo "    $vol"
  done

  echo; echo "• Snapshots (sections):"
  for sec in "${SNAP_SECTIONS[@]}"; do
    echo "    [$sec]"
  done

  echo; echo "• Snapshot states (vmstate):"
  for s in "${VMSTATE_OLD[@]}"; do
    echo "    $s → ${s//$ID_OLD/$ID_NEW}"
  done

  echo; echo "• Backups:"
  for f in "${BK_OLD[@]}"; do
    b2=${f//-$ID_OLD-/-$ID_NEW-}
    echo "    $f → $b2"
  done

  echo; echo "• jobs.cfg & replication.cfg:"
  for f in /etc/pve/jobs.cfg /etc/pve/replication.cfg; do
    [[ -f "$f" ]] && grep -q "vmid.*\b$ID_OLD\b" "$f" \
      && echo "    $f: vmid $ID_OLD → $ID_NEW"
  done

  echo; echo "• Pools & ACL (/etc/pve/user.cfg):"
  echo "    Global replace '$ID_OLD' → '$ID_NEW'"
} >> "$SUMMARY"

ROWS=$(tput lines); COLS=$(tput cols)
HEIGHT=$(( ROWS - 4 )); WIDTH=$(( COLS - 4 ))
fold -s -w "$WIDTH" "$SUMMARY" > "${SUMMARY}.wrapped"

### 14) Show summary & confirm
dialog --title "Summary before apply" \
       --textbox "${SUMMARY}.wrapped" "$HEIGHT" "$WIDTH"
dialog --yesno "Apply changes?" 8 50 || { log "Aborted"; exit 1; }

### 15) Execute renaming
log "Applying changes…"

# 15.a) Config
if [[ -e "$CONF_PATH" ]]; then
  mv "$CONF_PATH" "$CONF_DIR/$ID_NEW.conf"
  log "Config: $CONF_PATH → $CONF_DIR/$ID_NEW.conf"
else
  log "⚠️  Config not found, skipped: $CONF_PATH"
fi

# 15.b) Rename LVM volumes
for vol in "${LVM_OLD[@]}"; do
  st=${vol%%:*}; oldlv=${vol#*:}
  vg=$(pvesh get /storage/"$st" --output-format=json \
       | grep -Po '"vgname"\s*:\s*"\K[^"]+' || echo "")
  newlv="vm-${ID_NEW}-disk-${oldlv##*-}"
  if [[ -n "$vg" ]]; then
    lvrename "$vg" "$oldlv" "$newlv"
    sed -i "s|$st:$oldlv|$st:$newlv|g" "$CONF_DIR/$ID_NEW.conf"
    log "LVM: $vg/$oldlv → $vg/$newlv"
  fi
done

# 15.c) Rename VM folders (file-based & unused)
declare -A ST_PATH
for vol in "${FILE_OLD[@]}"; do
  st=${vol%%:*}
  if [[ -z "${ST_PATH[$st]:-}" ]]; then
    ST_PATH[$st]=$(pvesh get /storage/"$st" --output-format=json \
                   | grep -Po '"path"\s*:\s*"\K[^"]+' )
    oldd="${ST_PATH[$st]}/images/$ID_OLD"
    newd="${ST_PATH[$st]}/images/$ID_NEW"
    if [[ -d "$oldd" ]]; then
      mv "$oldd" "$newd"
      log "Folder: $oldd → $newd"
    else
      log "⚠️  Folder not found, skipped: $oldd"
    fi
  fi
done

# 15.d) Rename volumes inside new folder
for vol in "${FILE_OLD[@]}"; do
  st=${vol%%:*}; rel=${vol#*:}
  oldf="${ST_PATH[$st]}/images/$ID_NEW/$(basename "$rel")"
  newf="${ST_PATH[$st]}/images/$ID_NEW/$(basename "${rel//$ID_OLD/$ID_NEW}")"
  if [[ -f "$oldf" ]]; then
    mv "$oldf" "$newf"
    sed -i "s|$st:$rel|$st:${rel//$ID_OLD/$ID_NEW}|g" "$CONF_DIR/$ID_NEW.conf"
    log "File: $oldf → $newf"
  else
    log "⚠️  File not found, skipped: $oldf"
  fi
done

# 15.e) Rename vmstate files
for s in "${VMSTATE_OLD[@]}"; do
  st=${s%%:*}; rel=${s#*:}
  fn=$(basename "$rel")
  dir="${ST_PATH[$st]}/images/$ID_NEW"
  oldfile="$dir/$fn"
  newfile="$dir/${fn//$ID_OLD/$ID_NEW}"
  if [[ -f "$oldfile" ]]; then
    mv "$oldfile" "$newfile"
    sed -i "s|^vmstate:[[:space:]]*$st:$rel|vmstate: $st:${rel//$ID_OLD/$ID_NEW}|" "$CONF_DIR/$ID_NEW.conf"
    log "VMSTATE: $oldfile → $newfile"
  else
    log "⚠️  VMSTATE file not found, skipped: $oldfile"
  fi
done

# 15.f) Move backups
for f in "${BK_OLD[@]}"; do
  nf="${f//-$ID_OLD-/-$ID_NEW-}"
  if [[ -e "$f" ]]; then
    mv "$f" "$nf"
    log "Backup: $f → $nf"
  else
    log "⚠️  Backup not found, skipped: $f"
  fi
done

# 15.g) Update jobs.cfg & replication.cfg
for f in /etc/pve/jobs.cfg /etc/pve/replication.cfg; do
  if [[ -f "$f" ]]; then
    sed -i "s/\bvmid[[:space:]]\+$ID_OLD\b/vmid $ID_NEW/" "$f"
    log "Updated vmid in $f"
  fi
done

# 15.h) Pools & ACL
if sed -i "s/\b$ID_OLD\b/$ID_NEW/g" /etc/pve/user.cfg; then
  log "Updated pools & ACL"
else
  log "⚠️  Failed to update ACL (skipped)"
fi

### 16) Done
dialog --msgbox "✅ Renamed $TYPE $ID_OLD → $ID_NEW" 6 50
clear
