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

### ————————————————
### Helpers

# Rollback stack: each entry is a shell command that undoes a previous step.
ROLLBACK=()
push_rollback(){ ROLLBACK+=("$1"); }
do_rollback(){
  (( ${#ROLLBACK[@]} == 0 )) && return 0
  log "⚠️  Rolling back ${#ROLLBACK[@]} change(s)…"
  local i
  for (( i=${#ROLLBACK[@]}-1; i>=0; i-- )); do
    log "Rollback: ${ROLLBACK[$i]}"
    eval "${ROLLBACK[$i]}" 2>>"$LOGFILE" || log "⚠️  Rollback step failed: ${ROLLBACK[$i]}"
  done
  ROLLBACK=()
}

# HA neutralization state for the current guest (used to restore on abort).
HA_SID=""; HA_STATE="started"
restore_ha(){
  [[ -z "$HA_SID" ]] && return 0
  if ha-manager set "$HA_SID" --state "$HA_STATE" &>/dev/null; then
    log "Restored HA $HA_SID (state=$HA_STATE)"
  else
    log "⚠️  Could not restore HA $HA_SID"
  fi
}

# Reason string if the guest is busy, else empty + return 1 (idle).
# "Busy" = the config holds a "lock:" (set by backup/migrate/snapshot/clone/
# move-disk/rollback…) OR a task is actively running against this guest.
# Renaming underneath any of these would corrupt the in-flight operation.
guest_busy_reason(){
  local conf="$1" node="$2" id="$3" lock
  lock=$(awk '/^lock:/{print $2; exit}' "$conf" 2>/dev/null || true)
  if [[ -n "$lock" ]]; then printf 'config lock "%s"' "$lock"; return 0; fi
  # Server-side filter (--vmid) avoids 100-vs-1000 mismatches; --source active
  # lists only running tasks. A "upid" in the output means one is in flight.
  if pvesh get "/nodes/$node/tasks" --source active --vmid "$id" \
       --output-format=json 2>/dev/null | grep -q '"upid"'; then
    printf 'a running task'
    return 0
  fi
  return 1
}

# Build RBD_POOL + RBD_ARGS for a storage id (handles external Ceph clusters).
RBD_POOL=""; RBD_ARGS=()
rbd_set_args(){
  local st="$1" json monhost username
  json=$(pvesh get /storage/"$st" --output-format=json 2>/dev/null || echo '{}')
  RBD_POOL=$(grep -Po '"pool"\s*:\s*"\K[^"]+' <<<"$json" || echo "")
  [[ -z "$RBD_POOL" ]] && RBD_POOL="rbd"
  RBD_ARGS=(-p "$RBD_POOL")
  monhost=$(grep -Po '"monhost"\s*:\s*"\K[^"]+' <<<"$json" || echo "")
  username=$(grep -Po '"username"\s*:\s*"\K[^"]+' <<<"$json" || echo "")
  if [[ -n "$monhost" ]]; then
    RBD_ARGS+=(-m "${monhost// /,}")
    [[ -n "$username" ]] && RBD_ARGS+=(--id "$username")
    [[ -f "/etc/pve/priv/ceph/${st}.keyring" ]] && RBD_ARGS+=(--keyring "/etc/pve/priv/ceph/${st}.keyring")
  fi
}

# Extract renamable volume/source tokens from a stream of config lines.
_extract_vols(){
  grep -E '^(scsi|ide|virtio|sata|nvme|efidisk|tpmstate|unused)[0-9]+:|^(rootfs|mp[0-9]+):' \
    | grep -v -E '(none|\.iso)(,|$)' \
    | sed -E 's/^[^:]+:[[:space:]]*//' \
    | cut -d',' -f1
}

# True if a storage id is currently active (present in ACTIVE_STORAGES).
storage_is_active(){ printf '%s\n' "${ACTIVE_STORAGES[@]}" | grep -qx "$1"; }

# Abort the apply phase: roll everything back, restore HA, keep the old guest.
WORK_CONF=""
apply_fail(){
  trap - ERR   # avoid re-entering this handler if a rollback step fails
  local why="${1:-An error occurred during apply.}"
  do_rollback
  [[ -n "$WORK_CONF" && -e "$WORK_CONF" ]] && rm -f "$WORK_CONF"
  restore_ha
  log "ROLLED BACK: $why"
  dialog --title "❌ Rename failed – rolled back" --msgbox "$why

All changes were reverted. The guest remains as ID $ID_OLD." 12 72
  clear
  exit 1
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
  # Standalone mode: only the local host. Use the short name, which is what
  # Proxmox uses as the node name in the API (a FQDN here would break lookups).
  THIS_NODE=$(hostname -s)
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
    if (( ID_OLD < 100 || ID_OLD > 999999999 )); then
      dialog --msgbox "VMID must be between 100 and 999999999 (got $ID_OLD)." 6 50
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
    # ESC / Cancel here goes BACK to the current-VMID prompt instead of killing
    # the whole script, so a mistyped source VMID can be corrected.
    if ! ID_NEW=$(dialog --stdout --cancel-label "Back" \
                  --inputbox "Enter new free VMID (ESC = back):" 8 50); then
      log "User went back from the new-VMID prompt"
      continue 2
    fi
    # --- sanitize & validate ---
    ID_NEW=${ID_NEW//[$'\t\r\n ']/}
    if ! [[ $ID_NEW =~ ^[0-9]+$ ]]; then
      dialog --msgbox "Invalid VMID ‘$ID_NEW’: only digits are allowed." 6 50
      continue
    fi
    if (( ID_NEW < 100 || ID_NEW > 999999999 )); then
      dialog --msgbox "VMID must be between 100 and 999999999 (got $ID_NEW)." 6 50
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
      # extract the existing VM/CT name (QEMU exposes "name", LXC "hostname")
      if [[ "$TYPE_OCC" == lxc ]]; then OCC_KEY=hostname; else OCC_KEY=name; fi
      NAME_OCC=$(pvesh get "/nodes/$NODE_OCC/$TYPE_OCC/$ID_NEW/config" \
                 --output-format=json \
               | grep -Po "\"${OCC_KEY}\"\\s*:\\s*\"\\K[^\"]+" || echo "unknown")
      [[ -z "$NAME_OCC" ]] && NAME_OCC="unknown"
  
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
        if $BUSY; then (( NEXT++ )); else break; fi
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
    NAME=$(awk '/^name:/{print $2; exit}' "$CONF_PATH")
  else
    # LXC expose le nom sous "hostname:"
    NAME=$(awk '/^hostname:/{print $2; exit}' "$CONF_PATH")
  fi
  [[ -z "$NAME" ]] && NAME="unknown"
  log "Instance name: $NAME"
  
  ### 7) Active storages (the instance is stopped later, only after the
  ###    summary is confirmed, so an aborted run never leaves it stopped)
  # Only storages whose Status column is "active" count as online; an enabled
  # but unreachable storage shows up as "inactive" and must NOT pass the gate.
  mapfile -t ACTIVE_STORAGES < <(pvesm status 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}')
  log "Active storages: ${ACTIVE_STORAGES[*]:-none}"
  
  ### 8) Gather block volumes
  #   - exclude empty drives ("none") and ISO images (".iso") so install
  #     CD-ROMs are ignored, but KEEP cloud-init drives (usually media=cdrom).
  #   - nvme[0-9]+ is listed pre-emptively for future Proxmox bus support.
  #   - "main section" = currently attached devices (MUST exist);
  #     "whole file"   = also catches disks only referenced by a snapshot.
  mapfile -t MAIN_RAW < <(sed '/^\[/{q}' "$CONF_PATH" | _extract_vols)
  mapfile -t ALL_RAW  < <(_extract_vols < "$CONF_PATH")

  # Real storage volumes ("storage:volume") vs bind/device mounts (host paths
  # like mp0: /mnt/storage) and physical passthrough (ide2: cdrom).
  BIND_MOUNTS_OLD=(); VOL_MAIN=()
  declare -A _inmain=()
  for vol in "${MAIN_RAW[@]}"; do
    [[ -z "$vol" ]] && continue
    if [[ "$vol" == /* || "$vol" != *:* ]]; then
      BIND_MOUNTS_OLD+=("$vol")
      log "Skipping bind/device mount $vol: not a Proxmox storage volume"
      continue
    fi
    VOL_MAIN+=("$vol"); _inmain["$vol"]=1
  done

  VOL_SNAPONLY=()
  declare -A _insnap=()
  for vol in "${ALL_RAW[@]}"; do
    [[ -z "$vol" ]] && continue
    [[ "$vol" == /* || "$vol" != *:* ]] && continue
    [[ -n "${_inmain[$vol]:-}" || -n "${_insnap[$vol]:-}" ]] && continue
    VOL_SNAPONLY+=("$vol"); _insnap["$vol"]=1
  done
  unset _inmain _insnap

  VOL_OLD=("${VOL_MAIN[@]}")
  (( ${#VOL_SNAPONLY[@]} )) && VOL_OLD+=("${VOL_SNAPONLY[@]}")

  # Membership string for quick "is this snapshot-only?" tests later.
  SNAPONLY_SET=" ${VOL_SNAPONLY[*]:-} "

  log "Attached storage volumes: ${VOL_MAIN[*]:-none}"
  log "Snapshot-only volumes: ${VOL_SNAPONLY[*]:-none}"
  log "Bind/device mounts skipped: ${BIND_MOUNTS_OLD[*]:-none}"

  ### 9) vmstate volumes + snapshot section names
  mapfile -t VMSTATE_OLD < <(
    grep -E '^vmstate:' "$CONF_PATH" | sed -E 's/^vmstate:[[:space:]]*//' | cut -d',' -f1
  )
  mapfile -t SNAP_SECTIONS < <(grep -Po '^\[\K[^\]]+' "$CONF_PATH")
  log "Snapshot states: ${VMSTATE_OLD[*]:-none}"
  log "Snapshot sections: ${SNAP_SECTIONS[*]:-none}"

  ### 9.0) GATE – every storage backing an attached disk or a vmstate volume
  #         must be ONLINE. Renaming while a volume is on an offline/disabled
  #         storage would leave the guest pointing at a disk that still owns
  #         the old VMID, so we refuse and change nothing.
  OFFLINE=()
  for vol in "${VOL_MAIN[@]}" "${VMSTATE_OLD[@]}"; do
    [[ -z "$vol" || "$vol" != *:* ]] && continue
    st=${vol%%:*}
    storage_is_active "$st" || OFFLINE+=("$st  ($vol)")
  done
  if (( ${#OFFLINE[@]} )); then
    msg=$'This guest has a disk or saved state on an OFFLINE / disabled storage:\n\n'
    for o in "${OFFLINE[@]}"; do msg+="  • $o"$'\n'; done
    msg+=$'\nThat storage must be online so the volume can be renamed too;\notherwise the guest would break. Bring it online and retry.\n\nNothing was changed.'
    dialog --title "❌ Storage offline – cannot rename safely" --msgbox "$msg" 16 74
    log "ABORT: offline storage(s): ${OFFLINE[*]}"
    continue
  fi

  ### 9.1) GATE – a TEMPLATE with linked clones cannot be renamed (renaming the
  #         base volume breaks every linked clone that still references it).
  if grep -qE '^template:[[:space:]]*1' "$CONF_PATH"; then
    mapfile -t CLONE_REFS < <(
      grep -rlE "base-${ID_OLD}-disk-[0-9]+/" \
        /etc/pve/nodes/*/qemu-server/ /etc/pve/nodes/*/lxc/ 2>/dev/null \
        | grep -v "/${ID_OLD}\.conf$" || true
    )
    if (( ${#CLONE_REFS[@]} )); then
      msg=$'This guest is a TEMPLATE that still has linked clones:\n\n'
      for c in "${CLONE_REFS[@]}"; do msg+="  • $c"$'\n'; done
      msg+=$'\nRenaming it would break those clones. Convert them to full clones\nfirst, then retry. Nothing was changed.'
      dialog --title "❌ Template has linked clones" --msgbox "$msg" 16 74
      log "ABORT: template $ID_OLD has linked clones: ${CLONE_REFS[*]}"
      continue
    fi
  fi

  ### 9.2) GATE – existing replication jobs keep the old VMID on the target.
  if [[ -f /etc/pve/replication.cfg ]] \
     && grep -qE "^[[:alnum:]_-]+:[[:space:]]*${ID_OLD}-[0-9]+" /etc/pve/replication.cfg; then
    dialog --title "❌ Replication configured" --msgbox "\
This guest has one or more replication jobs.
Renaming would desynchronise the replicated datasets on the target node(s).

Remove the replication job(s) for VMID $ID_OLD first, then retry.
Nothing was changed." 12 74
    log "ABORT: replication jobs exist for $ID_OLD"
    continue
  fi

  ### 9.4) GATE – the guest must be idle. An in-flight backup, migration,
  #         snapshot, clone or disk-move holds a config lock; renaming while one
  #         of those runs would corrupt it. Refuse while the guest is busy.
  if reason=$(guest_busy_reason "$CONF_PATH" "$NODE_ASSIGNED" "$ID_OLD"); then
    dialog --title "❌ Guest is busy" --msgbox "\
This guest is currently busy ($reason).

A backup, migration, snapshot, clone or disk move may be in progress.
Wait for it to finish, or clear a stale lock with:
    $( [[ "$TYPE" == qemu ]] && echo qm || echo pct ) unlock $ID_OLD
then retry. Nothing was changed." 13 74
    log "ABORT: guest $ID_OLD is busy ($reason)"
    continue
  fi
  
  ### 9.3) Verify each volume exists. Attached volumes are a HARD requirement
  #         (abort if missing); snapshot-only volumes are best-effort (warn).
  ok=true
  for vol in "${VOL_OLD[@]}"; do
    st=${vol%%:*}; rel=${vol#*:}
    soft=false
    case "$SNAPONLY_SET" in *" $vol "*) soft=true ;; esac

    st_json=$(pvesh get /storage/"$st" --output-format=json 2>/dev/null) || st_json="{}"
    st_type=$(grep -Po '"type"\s*:\s*"\K[^"]+' <<<"$st_json" || echo "")
    found=true
    if [[ "$st_type" =~ lvm ]]; then
      vg=$(grep -Po '"vgname"\s*:\s*"\K[^"]+' <<<"$st_json" || echo "")
      lvdisplay "$vg/${rel##*/}" &>/dev/null || found=false
    elif [[ "$st_type" == "zfspool" ]]; then
      pool=$(grep -Po '"pool"\s*:\s*"\K[^"]+' <<<"$st_json" || echo "")
      zfs list "${pool}/${rel##*/}" &>/dev/null || found=false
    elif [[ "$st_type" == "rbd" ]]; then
      # also proves the rbd CLI can reach the cluster (needed for the rename)
      rbd_set_args "$st"
      rbd "${RBD_ARGS[@]}" info "$rel" &>/dev/null || found=false
    else
      sp=$(grep -Po '"path"\s*:\s*"\K[^"]+' <<<"$st_json" || echo "")
      [[ -n "$sp" && -e "$sp/images/$rel" ]] || found=false
    fi

    if ! $found; then
      if $soft; then
        log "⚠️  Snapshot-only volume not found, will skip: $vol"
      else
        dialog --title "❌ Volume not found / unreachable" --msgbox "\
Could not locate (or reach) a volume backing the guest:

  $vol   (storage type: ${st_type:-unknown})

Verify the storage is online and the volume exists.
Nothing was changed." 12 74
        log "ABORT: missing/unreachable volume $vol"
        ok=false; break
      fi
    fi
  done
  $ok || continue
  log "All attached volumes verified."

  ### 10) Existing LVM snapshot volumes (snap_vm-<id>-…)
  mapfile -t SNAP_LV_OLD < <(
    lvs --noheadings -o lv_name,vg_name 2>/dev/null \
      | awk '{print $1 ":" $2}' | grep "^snap_vm-${ID_OLD}-" || true
  )
  log "LVM snapshot volumes: ${SNAP_LV_OLD[*]:-none}"

  ### 11) Classify volumes: LVM / ZFS / RBD / file-based
  LVM_OLD=(); ZFS_OLD=(); RBD_OLD=(); FILE_OLD=()
  for vol in "${VOL_OLD[@]}"; do
    st=${vol%%:*}
    st_json=$(pvesh get /storage/"$st" --output-format=json 2>/dev/null || echo '{}')
    stype=$(grep -Po '"type"\s*:\s*"\K[^"]+' <<<"$st_json" || echo "")
    if   [[ "$stype" =~ lvm ]];       then LVM_OLD+=("$vol")
    elif [[ "$stype" == "zfspool" ]]; then ZFS_OLD+=("$vol")
    elif [[ "$stype" == "rbd" ]];     then RBD_OLD+=("$vol")
    else                                   FILE_OLD+=("$vol")
    fi
  done
  (( ${#FILE_OLD[@]} )) && mapfile -t FILE_OLD < <(printf "%s\n" "${FILE_OLD[@]}" | sort -u)
  log "LVM: ${LVM_OLD[*]:-none} | ZFS: ${ZFS_OLD[*]:-none} | RBD: ${RBD_OLD[*]:-none} | FILE: ${FILE_OLD[*]:-none}"

  ### 11.a) Detect HA membership (only previewed now; disabled after confirm)
  if [[ "$TYPE" == qemu ]]; then HA_PREFIX=vm; else HA_PREFIX=ct; fi
  HA_MANAGED=false; HA_STATE=started; HA_SID=""
  if command -v ha-manager &>/dev/null \
     && grep -qE "^[[:space:]]*${HA_PREFIX}:[[:space:]]*${ID_OLD}([^0-9]|$)" /etc/pve/ha/resources.cfg 2>/dev/null; then
    HA_MANAGED=true
    HA_STATE=$(awk -v p="$HA_PREFIX" -v id="$ID_OLD" '
      $0 ~ "^[[:space:]]*"p":[[:space:]]*"id"([^0-9]|$)" {blk=1; next}
      blk && /^[^[:space:]]/ {blk=0}
      blk && $1=="state" {print $2; exit}
    ' /etc/pve/ha/resources.cfg)
    [[ -z "$HA_STATE" ]] && HA_STATE=started
    log "Guest is HA-managed (${HA_PREFIX}:$ID_OLD, state=$HA_STATE)"
  fi
  
  ### 11.b) Gather backups
  BKDIRS=(/var/lib/vz/dump /mnt/pve/*/dump)
  BK_OLD=()
  for d in "${BKDIRS[@]}"; do
    log "Searching backups in $d"
    [[ -d "$d" ]] || continue
    while IFS= read -r f; do BK_OLD+=("$f"); done \
      < <(find "$d" -type f -name "*-${ID_OLD}-*" 2>/dev/null)
  done
  log "Backups found: ${#BK_OLD[@]} files"

  ### 11.c) Detect Proxmox Backup Server (PBS) snapshots for this guest.
  #          PBS backups are immutable, content-addressed snapshots indexed by
  #          VMID inside the datastore; they cannot be "mv"-renamed like file
  #          dumps, so we only DETECT and WARN — they keep the old VMID.
  mapfile -t PBS_STORAGES < <(pvesm status 2>/dev/null | awk 'NR>1 && $2=="pbs" {print $1}')
  PBS_BK_OLD=()
  for st in "${PBS_STORAGES[@]:-}"; do
    [[ -z "$st" ]] && continue
    while IFS= read -r volid; do
      [[ -n "$volid" ]] && PBS_BK_OLD+=("$st:$volid")
    done < <(pvesm list "$st" --vmid "$ID_OLD" 2>/dev/null | awk 'NR>1 {print $1}')
  done
  log "PBS snapshots found for $ID_OLD: ${#PBS_BK_OLD[@]}"
  
  ### 12) Build summary
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
      child="${oldds##*/}"; newchild="${child//$ID_OLD/$ID_NEW}"
      if [[ "$oldds" == */* ]]; then newds="${oldds%/*}/${newchild}"; else newds="$newchild"; fi
      echo "    $st: $oldds → $newds"
    done
    echo; echo "• RBD volumes:"
    for vol in "${RBD_OLD[@]}"; do
      st=${vol%%:*}; oldrbd=${vol#*:}
      echo "    $st: $oldrbd → ${oldrbd//$ID_OLD/$ID_NEW}"
    done
    echo; echo "• LVM volumes:"
    for vol in "${LVM_OLD[@]}"; do
      st=${vol%%:*}; oldlv=${vol#*:}
      echo "    $st: $oldlv → ${oldlv//$ID_OLD/$ID_NEW}"
    done
    echo; echo "• LVM snapshot volumes:"
    for entry in "${SNAP_LV_OLD[@]}"; do
      old_snap=${entry%%:*}; vg=${entry#*:}
      echo "    $vg/$old_snap → $vg/${old_snap//$ID_OLD/$ID_NEW}"
    done
    echo; echo "• File-based volumes:"
    for vf in "${FILE_OLD[@]}"; do
      echo "    $vf → ${vf//$ID_OLD/$ID_NEW}"
    done
    if (( ${#VOL_SNAPONLY[@]} )); then
      echo; echo "• Snapshot-only volumes (renamed if still present):"
      for v in "${VOL_SNAPONLY[@]}"; do echo "    $v → ${v//$ID_OLD/$ID_NEW}"; done
    fi
    if (( ${#BIND_MOUNTS_OLD[@]} )); then
      echo; echo "• Bind/device mount points (left untouched):"
      for bm in "${BIND_MOUNTS_OLD[@]}"; do echo "    $bm"; done
    fi
    echo; echo "• Snapshot sections:"
    for s in "${SNAP_SECTIONS[@]}"; do echo "    [$s]"; done
    echo; echo "• vmstate entries:"
    for s in "${VMSTATE_OLD[@]}"; do echo "    $s → ${s//$ID_OLD/$ID_NEW}"; done
    echo; echo "• Backups (local dumps – renamed):"
    for f in "${BK_OLD[@]}"; do
      b=$(basename "$f"); echo "    $b → ${b//-$ID_OLD-/-$ID_NEW-}"
    done
    if (( ${#PBS_BK_OLD[@]} )); then
      echo; echo "• ⚠️  PBS backups (NOT renamed – they will keep VMID $ID_OLD):"
      for v in "${PBS_BK_OLD[@]}"; do echo "    $v"; done
      echo "    → restore/prune these manually if you need them under $ID_NEW."
    fi
    echo; echo "• jobs.cfg & replication.cfg:"
    for f in /etc/pve/jobs.cfg /etc/pve/replication.cfg; do
      [[ -f "$f" ]] && grep -qE "\bvmid[[:space:]]+$ID_OLD\b" "$f" \
        && echo "    $f: vmid $ID_OLD → $ID_NEW"
    done
    echo; echo "• Pools & ACL (/etc/pve/user.cfg): acl/pool lines, $ID_OLD → $ID_NEW"
    echo; echo "• HA & firewall:"
    $HA_MANAGED && echo "    HA resource: ${HA_PREFIX}:$ID_OLD → ${HA_PREFIX}:$ID_NEW (state=$HA_STATE; disabled during rename)"
    [[ -f "/etc/pve/firewall/${ID_OLD}.fw" ]] && echo "    Firewall: ${ID_OLD}.fw → ${ID_NEW}.fw"
  } >> "$SUMMARY"
  # tput can return nothing without a proper TTY/TERM, which would yield a
  # negative width and abort the script under "set -e"; fall back to 80x24.
  TERM_COLS=$(tput cols 2>/dev/null || true);  [[ "$TERM_COLS"  =~ ^[0-9]+$ ]] || TERM_COLS=80
  TERM_LINES=$(tput lines 2>/dev/null || true); [[ "$TERM_LINES" =~ ^[0-9]+$ ]] || TERM_LINES=24
  fold -s -w $(( TERM_COLS-4 )) "$SUMMARY" > "${SUMMARY}.wrapped"
  
  ### 13) Show summary & confirm
  dialog --title "Summary before apply" \
         --textbox "${SUMMARY}.wrapped" $(( TERM_LINES-4 )) $(( TERM_COLS-4 ))
  dialog --yesno "Apply changes?" 8 50 || { log "Aborted by user (nothing changed)"; continue; }
  log "User confirmed apply"

  ### 14) Neutralize HA so the CRM cannot restart the guest mid-rename
  if $HA_MANAGED; then
    if ha-manager set "${HA_PREFIX}:$ID_OLD" --state disabled &>/dev/null; then
      HA_SID="${HA_PREFIX}:$ID_OLD"
      log "HA ${HA_PREFIX}:$ID_OLD set to disabled (will restore state=$HA_STATE)"
    else
      log "⚠️  Could not disable HA ${HA_PREFIX}:$ID_OLD"
    fi
  fi

  ### 15) Stop the instance if needed
  if [[ "$TYPE" == qemu ]]; then STATE=$(qm status "$ID_OLD" 2>/dev/null | awk '{print $2}')
  else STATE=$(pct status "$ID_OLD" 2>/dev/null | awk '{print $2}'); fi
  log "Status: ${STATE:-unknown}"
  if [[ "$STATE" != stopped ]]; then
    if dialog --yesno "Instance is '${STATE:-unknown}'. Stop it now?" 7 50; then
      log "Stopping $TYPE $ID_OLD"
      if [[ "$TYPE" == qemu ]]; then qm shutdown "$ID_OLD" || true; else pct shutdown "$ID_OLD" || true; fi
      for _ in {1..20}; do
        sleep 3
        if [[ "$TYPE" == qemu ]]; then STATE=$(qm status "$ID_OLD" 2>/dev/null | awk '{print $2}')
        else STATE=$(pct status "$ID_OLD" 2>/dev/null | awk '{print $2}'); fi
        [[ "$STATE" == stopped ]] && break
      done
      if [[ "$STATE" != stopped ]]; then
        dialog --msgbox "Failed to stop the instance. Aborting (nothing changed)." 6 55
        log "ABORT: failed to stop $ID_OLD"
        restore_ha
        continue
      fi
      log "Instance stopped"
    else
      log "User declined to stop; aborting (nothing changed)"
      restore_ha
      continue
    fi
  fi

  ### 15.5) Re-check the target VMID is still free (it was validated back in
  #          step 4; another node/admin/CRM may have claimed it since then).
  for N in "${CLUSTER_NODES[@]}"; do
    if pvesh get "/nodes/$N/qemu/$ID_NEW/config" &>/dev/null \
       || pvesh get "/nodes/$N/lxc/$ID_NEW/config" &>/dev/null; then
      dialog --msgbox "VMID $ID_NEW was taken in the meantime (node $N). Aborting (nothing changed)." 7 60
      log "ABORT: target VMID $ID_NEW became occupied on $N before apply"
      restore_ha
      continue 2
    fi
  done

  # Re-check the guest is still idle: a backup/snapshot/clone may have grabbed a
  # lock between the summary confirmation and now. Abort cleanly if so.
  if reason=$(guest_busy_reason "$CONF_PATH" "$NODE_ASSIGNED" "$ID_OLD"); then
    dialog --msgbox "Guest became busy ($reason) before apply. Aborting (nothing changed)." 7 60
    log "ABORT: guest $ID_OLD became busy ($reason) before apply"
    restore_ha
    continue 2
  fi

  ### 16) Execute renaming (transactional: rename volumes, edit a working copy
  #        of the config, then commit; on any failure roll everything back)
  log "Applying changes…"
  ROLLBACK=()
  # From here until the commit (16.f) any unguarded command failure must roll
  # everything back and restore HA, so route "set -e" errors through apply_fail.
  trap 'apply_fail "Unexpected error during apply"' ERR
  WORK_CONF=$(mktemp)
  cp "$CONF_PATH" "$WORK_CONF" || apply_fail "Could not create a working copy of the config"

  # 16.a) The config is committed only at the very end (16.f). Until then every
  #        edit targets "$WORK_CONF" and the live $ID_OLD.conf stays intact, so a
  #        rollback simply discards the working copy and reverts the volumes.

  # 16.b) Rename LVM volumes. Replacing the VMID inside the name preserves the
  #        convention Proxmox encodes there (vm-/base-/…-cloudinit).
  for vol in "${LVM_OLD[@]}"; do
    st=${vol%%:*}; oldlv=${vol#*:}
    newlv="${oldlv//$ID_OLD/$ID_NEW}"
    [[ "$oldlv" == "$newlv" ]] && { sed -i "s|$st:$oldlv|$st:$newlv|g" "$WORK_CONF"; continue; }
    vg=$(pvesh get /storage/"$st" --output-format=json | grep -Po '"vgname"\s*:\s*"\K[^"]+' || echo "")
    [[ -z "$vg" ]] && apply_fail "No volume group found for storage $st"
    lvdisplay "$vg/$oldlv" &>/dev/null || { log "⚠️  LVM $vg/$oldlv missing, skipped"; continue; }
    lvrename "$vg" "$oldlv" "$newlv" || apply_fail "lvrename $vg/$oldlv → $newlv failed"
    push_rollback "lvrename '$vg' '$newlv' '$oldlv'"
    sed -i "s|$st:$oldlv|$st:$newlv|g" "$WORK_CONF"
    log "LVM: $vg/$oldlv → $vg/$newlv"
  done
  
  # 16.b bis) Rename LVM snapshot volumes (snap_vm-<id>-… , any suffix)
  mapfile -t SNAP_LV_OLD < <(
    lvs --noheadings -o lv_name,vg_name 2>/dev/null \
      | awk '{print $1 ":" $2}' | grep "^snap_vm-${ID_OLD}-" || true
  )
  for entry in "${SNAP_LV_OLD[@]}"; do
    old_snap=${entry%%:*}; vg=${entry#*:}
    new_snap="${old_snap//$ID_OLD/$ID_NEW}"
    [[ "$old_snap" == "$new_snap" ]] && continue
    if lvdisplay "$vg/$old_snap" &>/dev/null; then
      lvrename "$vg" "$old_snap" "$new_snap" || apply_fail "lvrename snapshot $vg/$old_snap failed"
      push_rollback "lvrename '$vg' '$new_snap' '$old_snap'"
      log "LVM snapshot: $vg/$old_snap → $vg/$new_snap"
    else
      log "⚠️  Snapshot $vg/$old_snap not found, skipped"
    fi
  done

  # Update snapshot-volume references in the working config copy
  sed -i "s/snap_vm-${ID_OLD}-/snap_vm-${ID_NEW}-/g" "$WORK_CONF"
  
  # 16.c) Rename ZFS volumes
  declare -A ZFS_POOL=()
  for st in $(printf '%s\n' "${ZFS_OLD[@]}" | cut -d: -f1 | sort -u); do
    ZFS_POOL[$st]=$(pvesh get /storage/"$st" --output-format=json | grep -Po '"pool"\s*:\s*"\K[^"]+' || echo "")
  done

  for vol in "${ZFS_OLD[@]}"; do
    st=${vol%%:*}; rel=${vol#*:}
    pool=${ZFS_POOL[$st]:-}
    [[ -z "$pool" ]] && apply_fail "No ZFS pool found for storage $st"

    # Linked clones use a composite volid "base-…/vm-…"; only the child (after
    # the last '/') is a real dataset, the parent base must stay untouched.
    child="${rel##*/}"; newchild="${child//$ID_OLD/$ID_NEW}"
    if [[ "$rel" == */* ]]; then newrel="${rel%/*}/${newchild}"; else newrel="$newchild"; fi

    if [[ "$child" == "$newchild" ]]; then
      sed -i "s|$st:$rel|$st:$newrel|g" "$WORK_CONF"; continue
    fi
    if ! zfs list "$pool/$child" &>/dev/null; then
      log "⚠️  ZFS $pool/$child missing, skipped"; continue
    fi
    zfs rename "$pool/$child" "$pool/$newchild" || apply_fail "zfs rename $pool/$child failed"
    push_rollback "zfs rename '$pool/$newchild' '$pool/$child'"

    # If an explicit mountpoint still carries the old id, update it as well.
    mp=$(zfs get -H -o value mountpoint "$pool/$newchild" 2>/dev/null || echo "")
    if [[ -n "$mp" && "$mp" != none && "$mp" != legacy && "$mp" == *"$ID_OLD"* ]]; then
      newmp="${mp//$ID_OLD/$ID_NEW}"
      if zfs set mountpoint="$newmp" "$pool/$newchild" 2>/dev/null; then
        push_rollback "zfs set mountpoint='$mp' '$pool/$newchild'"
        log "ZFS mountpoint: $mp → $newmp"
      fi
    fi
    sed -i "s|$st:$rel|$st:$newrel|g" "$WORK_CONF"
    log "ZFS: $pool/$child → $pool/$newchild"
  done

  # 16.c bis) Rename Ceph/RBD images (block storage, no file under images/)
  for vol in "${RBD_OLD[@]}"; do
    st=${vol%%:*}; rel=${vol#*:}
    newrel="${rel//$ID_OLD/$ID_NEW}"
    [[ "$rel" == "$newrel" ]] && { sed -i "s|$st:$rel|$st:$newrel|g" "$WORK_CONF"; continue; }
    rbd_set_args "$st"
    rbd "${RBD_ARGS[@]}" info "$rel" &>/dev/null || { log "⚠️  RBD $RBD_POOL/$rel missing, skipped"; continue; }
    rbd "${RBD_ARGS[@]}" rename "$rel" "$newrel" || apply_fail "rbd rename $RBD_POOL/$rel → $newrel failed"
    push_rollback "rbd ${RBD_ARGS[*]} rename '$newrel' '$rel'"
    sed -i "s|$st:$rel|$st:$newrel|g" "$WORK_CONF"
    log "RBD: $RBD_POOL/$rel → $RBD_POOL/$newrel"
  done

  # 16.d) Rename file-based volumes in place (correct images/<vmid>/ prefix)
  if (( ${#FILE_OLD[@]} > 0 )); then
    declare -A ST_PATH=()
    while IFS= read -r st; do
      [[ -z "$st" ]] && continue
      ST_PATH[$st]=$(pvesh get /storage/"$st" --output-format=json 2>/dev/null \
                     | grep -Po '"path"\s*:\s*"\K[^"]+' || echo "")
    done < <(printf '%s\n' "${FILE_OLD[@]}" | cut -d: -f1 | sort -u)

    for vol in "${FILE_OLD[@]}"; do
      st=${vol%%:*}; rel=${vol#*:}
      [[ -z "$st" ]] && continue
      path="${ST_PATH[$st]:-}"
      [[ -z "$path" ]] && { log "⚠️  No path for storage '$st', skipped: $vol"; continue; }
      oldf="$path/images/$rel"; newrel="${rel//$ID_OLD/$ID_NEW}"; newf="$path/images/$newrel"
      [[ "$oldf" == "$newf" ]] && { sed -i "s|$st:$rel|$st:$newrel|g" "$WORK_CONF"; continue; }
      [[ -e "$oldf" ]] || { log "⚠️  File not found, skipped: $oldf"; continue; }
      [[ -e "$newf" ]] && apply_fail "Target file already exists: $newf"
      mkdir -p "$(dirname "$newf")"
      mv "$oldf" "$newf" || apply_fail "mv $oldf → $newf failed"
      push_rollback "mv -- '$newf' '$oldf'"
      sed -i "s|$st:$rel|$st:$newrel|g" "$WORK_CONF"
      log "File: $oldf → $newf"
    done
  fi

  # 16.e) Rename snapshot vmstate volumes (RAM state); these can sit on any
  #        storage type and must follow the new VMID or rollback breaks.
  for vol in "${VMSTATE_OLD[@]}"; do
    [[ -z "$vol" || "$vol" != *:* ]] && continue
    st=${vol%%:*}; rel=${vol#*:}; newrel="${rel//$ID_OLD/$ID_NEW}"
    [[ "$rel" == "$newrel" ]] && { sed -i "s|$st:$rel|$st:$newrel|g" "$WORK_CONF"; continue; }
    st_json=$(pvesh get /storage/"$st" --output-format=json 2>/dev/null || echo '{}')
    stype=$(grep -Po '"type"\s*:\s*"\K[^"]+' <<<"$st_json" || echo "")
    case "$stype" in
      *lvm*)
        vg=$(grep -Po '"vgname"\s*:\s*"\K[^"]+' <<<"$st_json" || echo "")
        if [[ -n "$vg" ]] && lvdisplay "$vg/$rel" &>/dev/null; then
          lvrename "$vg" "$rel" "$newrel" || apply_fail "vmstate lvrename $vg/$rel failed"
          push_rollback "lvrename '$vg' '$newrel' '$rel'"
          log "vmstate LVM: $vg/$rel → $vg/$newrel"
        else log "⚠️  vmstate LVM $vg/$rel not found, skipped"; fi ;;
      zfspool)
        pool=$(grep -Po '"pool"\s*:\s*"\K[^"]+' <<<"$st_json" || echo "")
        if [[ -n "$pool" ]] && zfs list "$pool/$rel" &>/dev/null; then
          zfs rename "$pool/$rel" "$pool/$newrel" || apply_fail "vmstate zfs rename $pool/$rel failed"
          push_rollback "zfs rename '$pool/$newrel' '$pool/$rel'"
          log "vmstate ZFS: $pool/$rel → $pool/$newrel"
        else log "⚠️  vmstate ZFS $pool/$rel not found, skipped"; fi ;;
      rbd)
        rbd_set_args "$st"
        if rbd "${RBD_ARGS[@]}" info "$rel" &>/dev/null; then
          rbd "${RBD_ARGS[@]}" rename "$rel" "$newrel" || apply_fail "vmstate rbd rename $RBD_POOL/$rel failed"
          push_rollback "rbd ${RBD_ARGS[*]} rename '$newrel' '$rel'"
          log "vmstate RBD: $RBD_POOL/$rel → $RBD_POOL/$newrel"
        else log "⚠️  vmstate RBD $RBD_POOL/$rel not found, skipped"; fi ;;
      *)
        sp=$(grep -Po '"path"\s*:\s*"\K[^"]+' <<<"$st_json" || echo "")
        oldf="$sp/images/$rel"; newf="$sp/images/$newrel"
        if [[ -n "$sp" && -e "$oldf" ]]; then
          [[ -e "$newf" ]] && apply_fail "vmstate target already exists: $newf"
          mkdir -p "$(dirname "$newf")"
          mv "$oldf" "$newf" || apply_fail "vmstate mv $oldf failed"
          push_rollback "mv -- '$newf' '$oldf'"
          log "vmstate file: $oldf → $newf"
        else log "⚠️  vmstate file $oldf not found, skipped"; fi ;;
    esac
    sed -i "s|$st:$rel|$st:$newrel|g" "$WORK_CONF"
  done

  # 16.f) COMMIT — write the new config, then drop the old one. This is the
  #        point of no return; everything after is best-effort (logged only).
  cp "$WORK_CONF" "$CONF_DIR/$ID_NEW.conf" || apply_fail "Failed to write $ID_NEW.conf"
  rm -f "$WORK_CONF"; WORK_CONF=""
  rm -f "$CONF_PATH"
  ROLLBACK=()
  # Point of no return reached: stop auto-rolling-back on errors, the rest is
  # best-effort cleanup and must not undo the (now committed) rename.
  trap - ERR
  log "Config committed: $ID_OLD.conf → $ID_NEW.conf"
  
  # 16.g) Move backups — rename only the basename (never rewrite the directory
  #        path) and never overwrite an existing target.
  for f in "${BK_OLD[@]}"; do
    [[ -e "$f" ]] || { log "⚠️  Backup not found, skipped: $f"; continue; }
    d=$(dirname "$f"); b=$(basename "$f"); nb="${b//-$ID_OLD-/-$ID_NEW-}"
    [[ "$b" == "$nb" ]] && continue
    nf="$d/$nb"
    if [[ -e "$nf" ]]; then
      log "⚠️  Backup target exists, skipped: $nf"
      continue
    fi
    mv "$f" "$nf" && log "Backup: $f → $nf"
  done
  
  # 16.h) Update jobs.cfg & replication.cfg (only log when something changed)
  for f in /etc/pve/jobs.cfg /etc/pve/replication.cfg; do
    if [[ -f "$f" ]] && grep -qE "\bvmid[[:space:]]+$ID_OLD\b" "$f"; then
      sed -i "s/\bvmid[[:space:]]\+$ID_OLD\b/vmid $ID_NEW/" "$f"
      log "Updated vmid $ID_OLD → $ID_NEW in $f"
    fi
  done
  
  # 16.i) Pools & ACL — restrict the replacement to acl:/pool: lines so that
  #        unrelated numeric fields or comments elsewhere are never touched.
  if [[ -f /etc/pve/user.cfg ]]; then
    if sed -i -E "/^(acl|pool):/ s/\b$ID_OLD\b/$ID_NEW/g" /etc/pve/user.cfg; then
      log "Updated pools & ACL (acl/pool lines)"
    else
      log "⚠️  Failed to update ACL (skipped)"
    fi
  fi

  # 16.j) HA: rename the sid in resources.cfg, then restore the original state
  #        (the entry was set to 'disabled' before the rename).
  if $HA_MANAGED; then
    HA_CFG=/etc/pve/ha/resources.cfg
    if [[ -f "$HA_CFG" ]]; then
      sed -i -E "s/^([[:space:]]*${HA_PREFIX}:[[:space:]]*)$ID_OLD([^0-9]|$)/\1$ID_NEW\2/" "$HA_CFG"
      log "HA resource ${HA_PREFIX}:$ID_OLD → ${HA_PREFIX}:$ID_NEW"
    fi
    if ha-manager set "${HA_PREFIX}:$ID_NEW" --state "$HA_STATE" &>/dev/null; then
      log "HA restored: ${HA_PREFIX}:$ID_NEW state=$HA_STATE"
    else
      log "⚠️  Could not restore HA state for ${HA_PREFIX}:$ID_NEW"
    fi
    HA_SID=""   # handled; keep restore_ha() from touching the old sid
  fi

  # 16.k) Per-guest firewall rules (/etc/pve/firewall/<vmid>.fw)
  FW_OLD="/etc/pve/firewall/${ID_OLD}.fw"
  FW_NEW="/etc/pve/firewall/${ID_NEW}.fw"
  if [[ -f "$FW_OLD" ]]; then
    if [[ -e "$FW_NEW" ]]; then
      log "⚠️  Firewall target exists, skipped: $FW_NEW"
    else
      mv "$FW_OLD" "$FW_NEW" && log "Firewall: $FW_OLD → $FW_NEW"
    fi
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

