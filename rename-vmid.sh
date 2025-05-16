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
  read -n1 -r -p "Press any key to continue…" 
  clear
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
    read -n1 -r -p "Press any key to continue…" 
    clear
    exit 1
  fi
fi

### 1.5) WARNING DIALOG
dialog --title "⚠️ WARNING – USE AT YOUR OWN RISK!" \
  --msgbox "\
This script renames Proxmox VMIDs after confirmation.
If you do not fully understand what it does, you risk corrupting your infrastructure.
Potential bugs – developed in my spare time, with no guarantees despite thorough testing.

For issues or feature requests, please open a ticket at:
https://github.com/sannier3/proxmox-vmid-updater/issues

USE AT YOUR OWN RISK!" 14 70

### 2) Determine cluster nodes (or single node)
CLUSTER_NODES=()
if pvecm nodes &>/dev/null; then
  # Fetch node list via API, extract "node" fields from JSON
  mapfile -t CLUSTER_NODES < <(
    pvesh get /nodes --output-format=json 2>/dev/null \
      | grep -Po '"node"\s*:\s*"\K[^"]+'
  )
  log "Cluster nodes: ${CLUSTER_NODES[*]}"
else
  # Standalone mode: only the local host
  THIS_NODE=$(hostname)
  CLUSTER_NODES=("$THIS_NODE")
  log "Not in a cluster, using local node: $THIS_NODE"
fi

### 2.5) Quorum check (if in cluster)
if (( ${#CLUSTER_NODES[@]} > 1 )); then
  # Temporarily disable “exit on error” so pvecm status can return non-zero
  set +e
  RAW_STATUS=$(pvecm status 2>&1)
  RETVAL=$?
  set -e

  # If pvecm status failed, assume no quorum
  if (( RETVAL != 0 )); then
    QSTAT="No"
    log "pvecm status failed (exit $RETVAL), assuming no quorum"
  else
    # Extract “Yes” or “No” from the “Quorate:” line
    QSTAT=$(awk -F: '/Quorate:/ {
      gsub(/^[ \t]+|[ \t]+$/, "", $2)
      print $2
    }' <<<"$RAW_STATUS")
    log "Cluster quorum status: $QSTAT"
  fi

  if [[ "$QSTAT" != "Yes" ]]; then
    dialog --title "❌ No Quorum" \
           --msgbox "\
Cluster is not quorate (Quorate: $QSTAT).
Please restore quorum before proceeding." 8 60
    log "ERROR: Cluster not quorate ($QSTAT) – aborting"
    clear
    exit 1
  fi

  log "Cluster is quorate, proceeding"
else
  log "Standalone mode – skipping quorum check"
fi

while true; do
  ### 3) Prompt for old VMID, detect TYPE and host node (direct lookup)
  while true; do
    ID_OLD=$(dialog --stdout --inputbox "Enter current VMID (ESC to quit):" 8 50) || exit 1
    # --- sanitize & validate ---
    # remove any whitespace/tabs/newlines
    ID_OLD=${ID_OLD//[$'\t\r\n ']/}
    # must be all digits
    if ! [[ $ID_OLD =~ ^[0-9]+$ ]]; then
      dialog --msgbox "Invalid VMID ‘$ID_OLD’: only digits are allowed." 6 50
      continue
    fi
    # must be in Proxmox default range
    if (( ID_OLD < 100 || ID_OLD > 1000000 )); then
      dialog --msgbox "VMID must be between 100 and 1000000 (got $ID_OLD)." 6 50
      continue
    fi
    # -----------------------------
    log "User entered VMID: $ID_OLD"
  
    NODE_ASSIGNED=""
    log "Scanning for VMID $ID_OLD on nodes: ${CLUSTER_NODES[*]}"
  
    # try strict QEMU lookup via the /config endpoint
    for N in "${CLUSTER_NODES[@]}"; do
      log "Checking QEMU VM $ID_OLD on node $N"
      if pvesh get "/nodes/$N/qemu/$ID_OLD/config" &>/dev/null; then
        TYPE=qemu
        NODE_ASSIGNED=$N
        log "Found QEMU VM $ID_OLD on node $N"
        break
      fi
    done
  
    # if not found as QEMU, try strict LXC lookup
    if [[ -z "$NODE_ASSIGNED" ]]; then
      for N in "${CLUSTER_NODES[@]}"; do
        log "Checking LXC CT $ID_OLD on node $N"
        if pvesh get "/nodes/$N/lxc/$ID_OLD/config" &>/dev/null; then
          TYPE=lxc
          NODE_ASSIGNED=$N
          log "Found LXC CT $ID_OLD on node $N"
          break
        fi
      done
    fi
  
    if [[ -z "$NODE_ASSIGNED" ]]; then
      log "VMID $ID_OLD not found on any node"
      dialog --msgbox "VMID $ID_OLD not found on any node." 6 50
      continue
    fi
  
    LOCAL_NODE=$(hostname -s)
    log "VMID $ID_OLD is on node $NODE_ASSIGNED; local short hostname is $LOCAL_NODE"
    if [[ "$NODE_ASSIGNED" != "$LOCAL_NODE" ]]; then
      dialog --msgbox "\
  VMID $ID_OLD is hosted on node: $NODE_ASSIGNED
  Please run this script on that node." 8 60
      continue
    fi
  
    log "Detected $TYPE VMID $ID_OLD on node $NODE_ASSIGNED"
    break
  done
  
  ### 4) Prompt for new VMID, show occupant and suggest next free ID
  while true; do
    ID_NEW=$(dialog --stdout --inputbox "Enter new free VMID:" 8 40) || exit 1
    # --- sanitize & validate ---
    ID_NEW=${ID_NEW//[$'\t\r\n ']/}
    if ! [[ $ID_NEW =~ ^[0-9]+$ ]]; then
      dialog --msgbox "Invalid VMID ‘$ID_NEW’: only digits are allowed." 6 50
      continue
    fi
    if (( ID_NEW < 100 || ID_NEW > 1000000 )); then
      dialog --msgbox "VMID must be between 100 and 1000000 (got $ID_NEW)." 6 50
      continue
    fi
    # -----------------------------
    log "User entered new VMID: $ID_NEW"
  
    OCCUPIED=false
    for N in "${CLUSTER_NODES[@]}"; do
      # check QEMU
      if pvesh get "/nodes/$N/qemu/$ID_NEW/config" &>/dev/null; then
        TYPE_OCC=qemu
        NODE_OCC=$N
        OCCUPIED=true
        break
      fi
      # check LXC
      if pvesh get "/nodes/$N/lxc/$ID_NEW/config" &>/dev/null; then
        TYPE_OCC=lxc
        NODE_OCC=$N
        OCCUPIED=true
        break
      fi
    done
  
    if $OCCUPIED; then
      # extract the existing VM/CT name
      NAME_OCC=$(pvesh get "/nodes/$NODE_OCC/$TYPE_OCC/$ID_NEW/config" \
                 --output-format=json \
               | grep -Po '"name"\s*:\s*"\K[^"]+' || echo "unknown")
  
      # find next free ID
      NEXT=$((ID_NEW + 1))
      while true; do
        BUSY=false
        for M in "${CLUSTER_NODES[@]}"; do
          if pvesh get "/nodes/$M/qemu/$NEXT/config" &>/dev/null || \
             pvesh get "/nodes/$M/lxc/$NEXT/config" &>/dev/null; then
            BUSY=true
            break
          fi
        done
        $BUSY && (( NEXT++ )) || break
      done
  
      dialog --msgbox "\
  VMID $ID_NEW is already taken by $TYPE_OCC '$NAME_OCC' on node $NODE_OCC.
  Next available VMID is $NEXT." 8 60
      log "VMID $ID_NEW occupied by $TYPE_OCC '$NAME_OCC'; suggesting $NEXT"
      continue
    fi
  
    log "VMID $ID_NEW is free on all nodes"
    break
  done
  
  ### 5) Locate config file
  if [[ "$TYPE" == qemu ]]; then
    CONF_PATH="/etc/pve/nodes/$NODE_ASSIGNED/qemu-server/$ID_OLD.conf"
  else
    CONF_PATH="/etc/pve/nodes/$NODE_ASSIGNED/lxc/$ID_OLD.conf"
  fi
  if [[ ! -f "$CONF_PATH" ]]; then
    dialog --msgbox "Config not found: $CONF_PATH" 6 60
    clear
    exit 1
  fi
  CONF_DIR=$(dirname "$CONF_PATH")
  log "Config: $CONF_PATH"
  
  ### 6) Retrieve VM/LXC name from config
  if [[ "$TYPE" == "qemu" ]]; then
    # QEMU expose le nom sous "name:"
    NAME=$(grep -E '^name:' "$CONF_PATH" | head -n1 | awk '{print $2}' || echo "unknown")
  else
    # LXC expose le nom sous "hostname:"
    NAME=$(grep -E '^hostname:' "$CONF_PATH" | head -n1 | awk '{print $2}' || echo "unknown")
  fi
  log "Instance name: $NAME"
  
  ### 7) Stop instance if needed
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
        clear
        exit 1
      fi
      log "Instance stopped"
    } || exit 1
  fi
  
  ### 8) Active storages
  mapfile -t ACTIVE_STORAGES < <(pvesm status | awk 'NR>1 {print $1}')
  log "Storages: ${ACTIVE_STORAGES[*]}"
  
  ### 9) Gather block volumes from the main section (exclude CD-ROMs)
  mapfile -t VOL_OLD < <(
    sed '/^\[/{q}' "$CONF_PATH" \
      | grep -E '^(scsi|ide|virtio|sata|efidisk|tpmstate|unused)[0-9]+:|^(rootfs|mp[0-9]+):' \
      | grep -v ',media=cdrom' \
      | sed -E 's/^[^:]+:[[:space:]]*//' \
      | cut -d',' -f1
  )
  log "Raw volumes (excluding CD-ROM): ${VOL_OLD[*]}"
  
  ### 9.a) Verify each disk actually exists (LVM, ZFS or file-based)
  for vol in "${VOL_OLD[@]}"; do
    st=${vol%%:*}
    rel=${vol#*:}

    # fetch storage info
    st_json=$(pvesh get /storage/"$st" --output-format=json 2>/dev/null) || st_json="{}"
    st_type=$(grep -Po '"type"\s*:\s*"\K[^"]+' <<<"$st_json" || echo "")

    if [[ "$st_type" =~ lvm ]]; then
      # LVM: check logical volume
      vg=$(grep -Po '"vgname"\s*:\s*"\K[^"]+' <<<"$st_json" || echo "")
      lv_name=${rel##*/}
      if ! lvdisplay "$vg/$lv_name" &>/dev/null; then
        dialog --title "❌ LVM volume not found" \
               --msgbox "\
Failed to locate LVM volume:
  VG:    $vg
  LV:    $lv_name

Please verify the storage is online and the LV exists." 10 60
        log "ERROR: Missing LVM volume $vg/$lv_name on $st"
        clear; exit 1
      fi

    elif [[ "$st_type" == "zfspool" ]]; then
      # ZFS: check dataset exists
      pool=$(grep -Po '"pool"\s*:\s*"\K[^"]+' <<<"$st_json" || echo "")
      ds_name="${rel}"   # e.g. vm-302-disk-0
      if ! zfs list "${pool}/${ds_name}" &>/dev/null; then
        dialog --title "❌ ZFS dataset not found" \
               --msgbox "\
Failed to locate ZFS dataset:
  Pool:    $pool
  Dataset: ${pool}/${ds_name}

Please verify the ZFS pool is available." 10 60
        log "ERROR: Missing ZFS dataset ${pool}/${ds_name}"
        clear; exit 1
      fi

    else
      # file-based: check file under images/<VMID>
      storage_path=$(grep -Po '"path"\s*:\s*"\K[^"]+' <<<"$st_json" || echo "")
      disk_file="$storage_path/images/$rel"
      if [[ ! -e "$disk_file" ]]; then
        dialog --title "❌ Disk file not found" \
               --msgbox "\
Failed to locate disk file on storage:
  Storage: $st (path=$storage_path)
  Expected file: $disk_file

Please verify the filesystem is mounted and the file exists." 10 60
        log "ERROR: Missing disk file $disk_file on $st"
        clear; exit 1
      fi
    fi
  done

  log "All virtual disks exist, continuing…"
  
  ### 10) Gather vmstate entries from all snapshots
  mapfile -t VMSTATE_OLD < <(
    grep -E '^vmstate:' "$CONF_PATH" \
      | sed -E 's/^vmstate:[[:space:]]*//' \
      | cut -d',' -f1
  )
  log "Snapshot states: ${VMSTATE_OLD[*]}"
  
  ### 11) Gather snapshot section names
  mapfile -t SNAP_SECTIONS < <(grep -Po '^\[\K[^\]]+' "$CONF_PATH")
  log "Snapshot sections: ${SNAP_SECTIONS[*]}"
  
  ### 11.a) Gather existing LVM snapshot volumes
  mapfile -t SNAP_LV_OLD < <(
    lvs --noheadings -o lv_name,vg_name \
      | awk '{print $1 ":" $2}' \
      | grep "^snap_vm-${ID_OLD}-disk-"
  )
  log "Raw LVM snapshot volumes: ${SNAP_LV_OLD[*]}"
  
  ### 12) Classify volumes: LVM, ZFS, or file-based
  LVM_OLD=()
  ZFS_OLD=()
  FILE_OLD=()
  for vol in "${VOL_OLD[@]}"; do
    st=${vol%%:*}; rel=${vol#*:}
    # skip inactive storages
    if ! printf '%s\n' "${ACTIVE_STORAGES[@]}" | grep -qx "$st"; then
      log "Skipping volume $vol: storage '$st' not active"
      continue
    fi
  
    # fetch storage type
    st_json=$(pvesh get /storage/"$st" --output-format=json 2>/dev/null || echo '{}')
    stype=$(grep -Po '"type"\s*:\s*"\K[^"]+' <<<"$st_json" || echo "")
  
    if [[ "$stype" =~ lvm ]]; then
      LVM_OLD+=("$vol")
    elif [[ "$stype" == "zfspool" ]]; then
      ZFS_OLD+=("$vol")
    else
      FILE_OLD+=("$vol")
    fi
  done
  mapfile -t FILE_OLD < <(printf "%s\n" "${FILE_OLD[@]}" | sort -u)
  
  log "LVM volumes: ${LVM_OLD[*]}"
  log "ZFS volumes: ${ZFS_OLD[*]}"
  log "File volumes: ${FILE_OLD[*]}"
  
  ### 13) Gather backups
  BKDIRS=(/var/lib/vz/dump /mnt/pve/*/dump)
  BK_OLD=()
  for d in "${BKDIRS[@]}"; do
    log "Searching backups in $d"
    [[ -d "$d" ]] || continue
    while IFS= read -r f; do BK_OLD+=("$f"); done \
      < <(find "$d" -type f -name "*-${ID_OLD}-*" 2>/dev/null)
  done
  log "Backups found: ${#BK_OLD[@]} files"
  
  ### 14) Build summary
  SUMMARY=/tmp/rename_summary.txt
  :> "$SUMMARY"
  {
    echo "🚀 Renaming $TYPE '$NAME' (ID $ID_OLD) → ID $ID_NEW"
    echo "------------------------------------------------------"
    echo; echo "• Config:"
    echo "    $CONF_PATH → $CONF_DIR/$ID_NEW.conf"
    echo; echo "• ZFS volumes:"
    for vol in "${ZFS_OLD[@]}"; do
      st=${vol%%:*}; oldds=${vol#*:}
      newds="${oldds//$ID_OLD/$ID_NEW}"
      echo "    $st: $oldds → $newds"
    done
    echo; echo "• LVM volumes:"
    for vol in "${LVM_OLD[@]}"; do
      st=${vol%%:*}; oldlv=${vol#*:}
      vg=$(pvesh get /storage/"$st" --output-format=json \
           | grep -Po '"vgname"\s*:\s*"\K[^"]+' || echo "")
      if [[ -n "$vg" ]]; then
        echo "    $vg/$oldlv → $vg/vm-${ID_NEW}-disk-${oldlv##*-}"
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
    echo; echo "• Disques et points de montage (file-based):"
    for vf in "${FILE_OLD[@]}"; do
      echo "    $vf"
    done
    echo; echo "• Snapshots (sections):"
    for s in "${SNAP_SECTIONS[@]}"; do echo "    [$s]"; done
    echo; echo "• VMSTATE entries:"
    for s in "${VMSTATE_OLD[@]}"; do echo "    $s → ${s//$ID_OLD/$ID_NEW}"; done
    echo; echo "• Backups:"
    for f in "${BK_OLD[@]}"; do echo "    $f → ${f//-$ID_OLD-/-$ID_NEW-}"; done
    echo; echo "• jobs.cfg & replication.cfg:"
    for f in /etc/pve/jobs.cfg /etc/pve/replication.cfg; do
      [[ -f "$f" ]] && grep -q "vmid.*\b$ID_OLD\b" "$f" \
        && echo "    $f: vmid $ID_OLD → $ID_NEW"
    done
    echo; echo "• Pools & ACL (/etc/pve/user.cfg):"
    echo "    Global replace '$ID_OLD' → '$ID_NEW'"
  } >> "$SUMMARY"
  fold -s -w $(( $(tput cols)-4 )) "$SUMMARY" > "${SUMMARY}.wrapped"
  
  ### 15) Show summary & confirm
  dialog --title "Summary before apply" \
         --textbox "${SUMMARY}.wrapped" $(( $(tput lines)-4 )) $(( $(tput cols)-4 ))
  dialog --yesno "Apply changes?" 8 50 || { log "Aborted"; exit 1; }
  log "User confirmed apply"
  
  ### 16) Execute renaming
  log "Applying changes…"
  
  # 16.a) Config
  if [[ -e "$CONF_PATH" ]]; then
    mv "$CONF_PATH" "$CONF_DIR/$ID_NEW.conf"
    log "Config: $CONF_PATH → $CONF_DIR/$ID_NEW.conf"
  else
    log "⚠️  Config not found, skipped: $CONF_PATH"
  fi
  
  # 16.b) Rename LVM volumes
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
  
  # 16.b bis) Rename LVM snapshot volumes
  mapfile -t SNAP_LV_OLD < <(
    lvs --noheadings -o lv_name,vg_name \
      | awk '{print $1 ":" $2}' \
      | grep "^snap_vm-${ID_OLD}-disk-"
  )
  for entry in "${SNAP_LV_OLD[@]}"; do
    old_snap=${entry%%:*}
    vg=${entry#*:}
    suffix=${old_snap#snap_vm-${ID_OLD}-disk-}
    new_snap="snap_vm-${ID_NEW}-disk-${suffix}"
  
    if lvdisplay "$vg/$old_snap" &>/dev/null; then
      lvrename "$vg" "$old_snap" "$new_snap"
      log "LVM snapshot: $vg/$old_snap → $vg/$new_snap"
    else
      log "⚠️  Snapshot $vg/$old_snap not found, skipped"
    fi
  done
  
  # Update any references in the new config file
  sed -i "s/snap_vm-${ID_OLD}-disk-/snap_vm-${ID_NEW}-disk-/g" "$CONF_DIR/$ID_NEW.conf"
  
  # 16.c) Rename ZFS volumes
  # Build a map of storage ID → zfs pool
  declare -A ZFS_POOL
  for st in $(printf '%s\n' "${ZFS_OLD[@]}" | cut -d: -f1 | sort -u); do
    ZFS_POOL[$st]=$(pvesh get /storage/"$st" --output-format=json \
                    | grep -Po '"pool"\s*:\s*"\K[^"]+' )
  done

  # Loop over each ZFS volume and rename it
  for vol in "${ZFS_OLD[@]}"; do
    st=${vol%%:*}            # storage ID, e.g. SCSI3-ZFS
    rel=${vol#*:}            # dataset name, e.g. vm-302-disk-0

    pool=${ZFS_POOL[$st]}
    old_ds="${pool}/${rel}"
    newrel="${rel//$ID_OLD/$ID_NEW}"
    new_ds="${pool}/${newrel}"

    # perform the zfs rename
    if ! zfs rename "$old_ds" "$new_ds"; then
      log "ERROR: Failed to rename ZFS dataset from $old_ds to $new_ds"
      exit 1
    fi

    # update config to reference the new dataset
    sed -i "s|$st:$rel|$st:$newrel|g" "$CONF_DIR/$ID_NEW.conf"

    log "ZFS: $old_ds → $new_ds"
  done

  # 16.d) Rename all file-based volumes in place, with correct images/ prefix
  declare -A ST_PATH

  # Build a map of storage ID → storage path
  for st in $(printf '%s\n' "${FILE_OLD[@]}" | cut -d: -f1 | sort -u); do
    ST_PATH[$st]=$(pvesh get /storage/"$st" --output-format=json \
                   | grep -Po '"path"\s*:\s*"\K[^"]+' )
  done

  # Loop over each file-based volume and rename it
  for vol in "${FILE_OLD[@]}"; do
    st=${vol%%:*}           # storage ID
    rel=${vol#*:}           # e.g. "302/vm-302-disk-0.qcow2"

    oldf="${ST_PATH[$st]}/images/$rel"
    newrel="${rel//$ID_OLD/$ID_NEW}"
    newf="${ST_PATH[$st]}/images/$newrel"

    if [[ -e "$oldf" ]]; then
      mkdir -p "$(dirname "$newf")"
      mv "$oldf" "$newf"
      sed -i "s|$st:$rel|$st:$newrel|g" "$CONF_DIR/$ID_NEW.conf"
      log "File: $oldf → $newf"
    else
      log "⚠️  File not found, skipped: $oldf"
    fi
  done
  
  # 16.f) Move backups
  for f in "${BK_OLD[@]}"; do
    nf="${f//-$ID_OLD-/-$ID_NEW-}"
    # Check if src and dest are exactly the same file path
    if [[ "$f" == "$nf" ]]; then
      log "Backup source and target are the same: $f (skipping)"
      continue
    fi
    # Optional: also check inode (same file, hard link case)
    if [[ -e "$nf" && "$(stat -c '%d:%i' "$f")" == "$(stat -c '%d:%i' "$nf")" ]]; then
      log "Backup source and target are the same file (inode): $f (skipping)"
      continue
    fi
    if [[ -e "$f" ]]; then
      mv "$f" "$nf"
      log "Backup: $f → $nf"
    else
      log "⚠️  Backup not found, skipped: $f"
    fi
  done
  
  # 16.g) Update jobs.cfg & replication.cfg
  for f in /etc/pve/jobs.cfg /etc/pve/replication.cfg; do
    if [[ -f "$f" ]]; then
      sed -i "s/\bvmid[[:space:]]\+$ID_OLD\b/vmid $ID_NEW/" "$f"
      log "Updated vmid in $f"
    fi
  done
  
  # 16.h) Pools & ACL
  if sed -i "s/\b$ID_OLD\b/$ID_NEW/g" /etc/pve/user.cfg; then
    log "Updated pools & ACL"
  else
    log "⚠️  Failed to update ACL (skipped)"
  fi
  
  ### 17) Final message
  dialog --msgbox "✅ Renamed $TYPE '$NAME' (ID $ID_OLD) → ID $ID_NEW" 6 50
  if dialog --title "Continue?" --yesno "Would you like to rename another VM/CT?" 7 60; then
    continue
  else
    clear
    exit 0
  fi
done

