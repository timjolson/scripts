#!/usr/bin/env bash
# podman_route_srcip_simple.sh
# Simple helper to route a container's traffic via a specific host interface.
# Usage:
#  Apply:   podman_route_srcip_simple.sh apply <iface> <container> [-g GW] [-t TABLE] [-o "<podman opts>"]
#  Teardown:podman_route_srcip_simple.sh teardown <container> [-t TABLE] [--wait] [-o "<podman opts>"]
#  Harsh cleanup: podman_route_srcip_simple.sh cleanup

set -euo pipefail
IFS=$'\n\t'

SCRIPT_NAME=$(basename "$0")
WAIT_TIMEOUT=15
ONLINK_FLAG=0
WAIT_FOR_STOP=0

# store state files in /run so teardown/cleanup do not need podman --runroot
# This fixed location avoids a bootstrap problem where locating the state
# file would otherwise require knowing the podman's runroot used at apply time.
STATE_DIR="/run/podman/routes/"

usage(){
  cat <<EOF
Usage:
  $SCRIPT_NAME apply <iface> <container> [-g GW] [-t TABLE] [-o "<podman opts>"]
  $SCRIPT_NAME teardown <container> [-t TABLE] [--wait] [-o "<podman opts>"]
  $SCRIPT_NAME cleanup
Examples:
  sudo $SCRIPT_NAME apply eth0 containername
  sudo $SCRIPT_NAME apply eth0 containername -g 192.168.1.1 -o "--root /var/lib/containers --runroot /run/containers/storage"
  sudo $SCRIPT_NAME teardown containername -o "--root /var/lib/containers --runroot /run/containers/storage"
EOF
}

if [[ $# -lt 1 ]]; then
  usage; exit 2
fi

MODE=$1; shift

# Parse recognized options anywhere in the arguments list. Instead of
# accepting --root/--runroot directly, accept a single -o "<podman opts>"
# which will be split into individual podman args. Other recognized
# short options (e.g. -g, --onlink) are still supported.
OPTS_STRING=""
GW_OVERRIDE=""
EXTRA_ARGS=()  # collects remaining positional args after parsing known options
TABLE_ARG="main"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      OPTS_STRING="$2"; shift 2;;
    -t)
      TABLE_ARG="$2"; shift 2;;
    --wait)
      WAIT_FOR_STOP=1; shift;;
    -g)
      GW_OVERRIDE="$2"; shift 2;;
    --onlink)
      ONLINK_FLAG=1; shift;;
    *) EXTRA_ARGS+=("$1"); shift;;
  esac
done

# restore the remaining positional args
set -- "${EXTRA_ARGS[@]}"

STATE_DIR="${STATE_DIR%/}/"  # ensure trailing slash for consistent path handling

# Build `PODMAN_CMD` from the provided -o string, if any. Split the string
# on whitespace into an array. Also extract `--runroot` from those options so
# we can reconstruct equivalent `podman` invocations later; the state file
# location is fixed to `STATE_DIR` and will not be changed based on --runroot.
build_podman_cmd_from_string(){
  # usage: build_podman_cmd_from_string "<opts string>"
  local s="$1"
  PODMAN_CMD=(podman)
  PODMAN_OPTS_ARRAY=()
  if [[ -n "$s" ]]; then
    # split into array while respecting quoted sub-arguments
    # e.g. "--label 'some value' --runroot /run" -> preserves 'some value'
    eval "PODMAN_OPTS_ARRAY=($s)"
    for elt in "${PODMAN_OPTS_ARRAY[@]}"; do
      PODMAN_CMD+=("$elt")
    done
  fi
}

# Build initial podman command from any provided -o string
build_podman_cmd_from_string "$OPTS_STRING"

# ensure state directory exists and is writable
if ! mkdir -p "$STATE_DIR" >/dev/null 2>&1; then
  err "could not create state directory: $STATE_DIR"
fi

err(){ echo "Error: $*" >&2; exit 1; }

log_info(){ echo "[INFO] $*"; }
log_err(){ echo "[ERROR] $*" >&2; }

preflight_check(){
  for cmd in podman ip iptables sed awk; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      log_err "required command '$cmd' not found"
      exit 2
    fi
  done
}

preflight_check

wait_for_running(){
  local target="$1" timeout=${2:-$WAIT_TIMEOUT} t=0
  while true; do
    # capture both stdout and stderr for debugging
    status_raw=$("${PODMAN_CMD[@]}" inspect --format '{{.State.Status}}' "$target" 2>&1 || true)
    # normalize CRLF and extract first token
    status=$(printf "%s" "$status_raw" | tr -d '\r' | awk '{print $1}' || true)
    log_info "[DEBUG] wait_for_running try=$t target=$target cmd='${PODMAN_CMD[*]} inspect --format {{.State.Status}}' raw='$status_raw' parsed='$status'"

    if [[ "$status" == "running" ]]; then return 0; fi
    if [[ "$status" == "exited" || "$status" == "paused" ]]; then return 1; fi
    t=$((t+1))
    if [[ $t -ge $timeout ]]; then log_info "[DEBUG] wait_for_running timed out after $t seconds for $target"; return 1; fi
    sleep 1
  done
}

wait_for_stopped(){
  local target="$1" timeout=${2:-$WAIT_TIMEOUT} t=0
  while true; do
    status=$("${PODMAN_CMD[@]}" inspect --format '{{.State.Status}}' "$target" 2>/dev/null || true)
    if [[ -z "$status" || "$status" == "exited" || "$status" == "dead" ]]; then return 0; fi
    t=$((t+1))
    if [[ $t -ge $timeout ]]; then return 1; fi
    sleep 1
  done
}

state_file(){ echo "${STATE_DIR}${1}.state"; }

# Read a state file by full path and populate variables
read_state_from_file(){
  local sf="$1"
  CIP="" REMOTE_IP="" IFACE="" GW="" TABLE="" PODMAN_OPTS_STRING="" CONTAINER_ID="" TABLE_ID="" CREATED_TABLE=""
  if [[ -f "$sf" ]]; then
    while IFS='=' read -r k v; do
      case "$k" in
        CIP) CIP="$v";;
        REMOTE_IP) REMOTE_IP="$v";;
        IFACE) IFACE="$v";;
        GW) GW="$v";;
        TABLE) TABLE="$v";;
        CONTAINER_ID) CONTAINER_ID="$v";;
        TABLE_ID) TABLE_ID="$v";;
        CREATED_TABLE) CREATED_TABLE="$v";;
        PODMAN_OPTS) PODMAN_OPTS_STRING="$v";;
      esac
    done < "$sf"
  fi
}

# Read state by target name (resolves path via state_file)
read_state(){
  read_state_from_file "$(state_file "$1")"
}

# Save state for a given target name
save_state(){
  local target="$1" sf
  sf=$(state_file "$target")
  mkdir -p "$(dirname "$sf")" || true
  {
    echo "CIP=$CIP"
    echo "REMOTE_IP=$REMOTE_IP"
    echo "IFACE=$IFACE"
    echo "GW=$GW"
    echo "TABLE=$TABLE"
    echo "CONTAINER_ID=$CONTAINER_ID"
    echo "TABLE_ID=${TABLE_ID:-}"
    echo "CREATED_TABLE=${CREATED_TABLE:-}"
    echo "PODMAN_OPTS=$PODMAN_OPTS_STRING"
  } > "$sf"
}

iptables_add_if_missing(){
  local table="$1" chain="$2" rule_spec=(${@:3})
  if ! iptables -t "$table" -C "$chain" "${rule_spec[@]}" >/dev/null 2>&1; then
    if ! iptables -t "$table" -A "$chain" "${rule_spec[@]}" >/dev/null 2>&1; then
      log_err "Failed to add iptables rule to $table/$chain: ${rule_spec[*]}"
      return 1
    fi
  fi
}

iptables_del_if_present(){
  local table="$1" chain="$2" rule_spec=(${@:3})
  if iptables -t "$table" -C "$chain" "${rule_spec[@]}" >/dev/null 2>&1; then
    if ! iptables -t "$table" -D "$chain" "${rule_spec[@]}" >/dev/null 2>&1; then
      log_err "Failed to delete iptables rule from $table/$chain: ${rule_spec[*]}"
      return 1
    fi
  fi
}

# Check whether an ip rule exists for a specific source and table
ip_rule_exists(){
  local from="$1" table="$2"
  ip rule show 2>/dev/null | grep -q "from ${from} lookup ${table}"
}

# Resolve a podman target (name or id). Prefers the provided candidate, falls
# back to a saved CONTAINER_ID (if set), or attempts to match container names
# via `podman ps`. Always echoes a value (candidate or resolved id).
resolve_podman_target(){
  local candidate="$1"
  if "${PODMAN_CMD[@]}" inspect "$candidate" >/dev/null 2>&1; then
    echo "$candidate"; return 0
  fi
  if [[ -n "${CONTAINER_ID:-}" ]] && "${PODMAN_CMD[@]}" inspect "$CONTAINER_ID" >/dev/null 2>&1; then
    echo "$CONTAINER_ID"; log_info "Falling back to saved CONTAINER_ID for podman operations"; return 0
  fi
  # Only accept exact name matches (second field) — no substring matching
  found=$("${PODMAN_CMD[@]}" ps --format '{{.ID}} {{.Names}}' 2>/dev/null | awk -v c="$candidate" '$2==c{print $1; exit}') || true
  if [[ -n "$found" ]] && "${PODMAN_CMD[@]}" inspect "$found" >/dev/null 2>&1; then
    echo "$found"; log_info "Resolved podman target '$candidate' -> id $found"; return 0
  fi
  echo "$candidate"
}

# Ensure a named routing table exists. If TABLE is not 'main' and not present
# in /etc/iproute2/rt_tables, create a temporary entry and set CREATED_TABLE=1
ensure_table_exists(){
  if [[ "${TABLE:-}" == "main" || -z "${TABLE:-}" ]]; then
    return 0
  fi
  # check if table exists (capture id if present)
  existing_id=$(rt_tables_get_id "$TABLE")
  if [[ -n "$existing_id" ]]; then
    TABLE_ID="$existing_id"
    CREATED_TABLE=0
    return 0
  fi

  # try to add a new entry
  if rt_tables_add "$TABLE"; then
    TABLE_ID=$(rt_tables_get_id "$TABLE")
    CREATED_TABLE=1
    log_info "Created routing table $TABLE with id $TABLE_ID"
  else
    log_err "Failed to create routing table entry for $TABLE"
  fi
}

# Remove a previously-created routing table entry if it is empty (no routes and
# no ip rules referencing it). Only removes entries that were created by us
# (CREATED_TABLE==1).
remove_table_if_empty(){
  if [[ "${CREATED_TABLE:-0}" != "1" ]]; then return 0; fi
  if [[ -z "${TABLE:-}" ]]; then return 0; fi
  # check for routes in the table
  if ip route show table "$TABLE" 2>/dev/null | grep -q .; then
    return 0
  fi
  # check for rules referencing the table (by name or id)
  if ip rule show 2>/dev/null | grep -E "lookup[[:space:]]+(${TABLE_ID:-}|${TABLE})" >/dev/null 2>&1; then
    return 0
  fi
  # safe to remove the rt_tables entry
  if rt_tables_get_id "$TABLE" >/dev/null; then
    if rt_tables_remove "$TABLE"; then
      log_info "Removed routing table entry for $TABLE from /etc/iproute2/rt_tables"
    fi
  fi
}

# rt_tables helpers
# Return the numeric id for a table name, or empty if not present
rt_tables_get_id(){
  local t="$1"
  awk -v t="$t" '$2==t{print $1; exit}' /etc/iproute2/rt_tables 2>/dev/null || true
}

# Add a table entry, selecting a free id >= 2000. Returns 0 on success.
rt_tables_add(){
  local t="$1"
  if [[ -z "$t" ]]; then return 1; fi
  # ensure not already present
  if rt_tables_get_id "$t" | grep -q .; then return 0; fi
  local nextid
  nextid=$(awk 'BEGIN{max=1999} /^[0-9]+[[:space:]]+[A-Za-z0-9_\-]+/ {if($1>max) max=$1} END{print max+1}' /etc/iproute2/rt_tables)
  # append to rt_tables (requires root)
  if echo "$nextid $t" >> /etc/iproute2/rt_tables; then
    return 0
  else
    log_err "Failed to append $t to /etc/iproute2/rt_tables"
    return 1
  fi
}

# Remove a table entry from /etc/iproute2/rt_tables. Returns 0 on success.
rt_tables_remove(){
  local t="$1"
  if [[ -z "$t" ]]; then return 1; fi
  # backup then remove
  if ! cp /etc/iproute2/rt_tables /etc/iproute2/rt_tables.bak 2>/dev/null; then
    log_err "Could not backup /etc/iproute2/rt_tables"
  fi
  if awk -v t="$t" '$2!=t' /etc/iproute2/rt_tables > /etc/iproute2/rt_tables.tmp && mv /etc/iproute2/rt_tables.tmp /etc/iproute2/rt_tables; then
    return 0
  else
    log_err "Failed to remove $t from /etc/iproute2/rt_tables"
    return 1
  fi
}

# Remove STATE_DIR if no matching state files remain. This keeps /run tidy
# when the script has removed all its own state files. It only checks for
# files matching *.state; if none exist it attempts to remove
# the directory (rmdir will harmlessly fail if other files remain).
remove_state_dir_if_empty(){
  if [[ -d "$STATE_DIR" ]]; then
    state_match=$(find "$STATE_DIR" -maxdepth 1 -name "*.state" -print -quit 2>/dev/null || true)
    if [[ -z "$state_match" ]]; then
      if rmdir "$STATE_DIR" >/dev/null 2>&1; then
        log_info "Removed state directory: $STATE_DIR"
      fi
      parent_dir=$(dirname "$STATE_DIR")
      # best-effort remove parent if empty
      if [[ -d "$parent_dir" ]]; then
        if rmdir "$parent_dir" >/dev/null 2>&1; then
          log_info "Removed parent directory: $parent_dir"
        fi
      fi
    fi
  fi
}

apply(){
  if [[ $# -lt 2 ]]; then usage; exit 2; fi
  local IFACE="$1" TARGET="$2"
  # Resolve the podman target and wait for the container to be running, then
  # query the container directly for IP and wg endpoint.
  PODMAN_TARGET=$(resolve_podman_target "$TARGET")
  wait_for_running "$PODMAN_TARGET" || err "container $TARGET not running within timeout"

  # get container IP (first network)
  CIP=$("${PODMAN_CMD[@]}" inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$PODMAN_TARGET" 2>/dev/null | awk '{print $1}' || true)
  if [[ -z "$CIP" ]]; then err "could not determine container IP for $TARGET"; fi

  # obtain WireGuard remote IP from inside the container (wg0)
  REMOTE_IP=$("${PODMAN_CMD[@]}" exec "$PODMAN_TARGET" sh -c 'wg showconf wg0 2>/dev/null | sed -nE "s/.*Endpoint[[:space:]]*=[[:space:]]*(([0-9]{1,3}\.){3}[0-9]{1,3}).*/\1/p"' 2>/dev/null | head -n1 || true)
  if [[ -z "$REMOTE_IP" ]]; then err "could not determine WireGuard remote IP inside $TARGET"; fi

  # determine gateway for IFACE towards remote
  if [[ -n "$GW_OVERRIDE" ]]; then
    GW="$GW_OVERRIDE"
    log_info "Using user-specified gateway: $GW"
  else
    # auto-detect gateway: first try to find a route to REMOTE_IP via IFACE, then fallback to default route if needed
    GW=$(ip route get "$REMOTE_IP" oif "$IFACE" 2>/dev/null | awk '/via/ {for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}' | head -n1)
    if [[ -z "$GW" ]]; then
      # fallback: try the system default route (use it even if via different dev)
      default_line=$(ip route show default 2>/dev/null | head -n1 || true)
      GW=$(echo "$default_line" | awk '/via/ {for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}' || true)
      default_dev=$(echo "$default_line" | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' || true)
      if [[ -n "$GW" ]]; then
        if [[ "$default_dev" != "$IFACE" && -n "$default_dev" ]]; then
          log_info "Using default gateway $GW (via $default_dev) as fallback for iface $IFACE — will force onlink"
          USE_ONLINK=1
        else
          log_info "Using default gateway $GW as fallback"
          USE_ONLINK=0
        fi
      else
        err "could not determine gateway from $IFACE to $REMOTE_IP"
      fi
    else
      USE_ONLINK=0
    fi
  fi

  TABLE="${TABLE_ARG:-main}"

  # ensure the named table exists (creates it if necessary)
  ensure_table_exists

  # apply host route (idempotent). If gateway is not actually reachable via IFACE, use 'onlink' to force.
  if [[ "${USE_ONLINK:-0}" -eq 1 ]]; then
    if ! ip route replace ${REMOTE_IP}/32 via "$GW" dev "$IFACE" onlink table $TABLE 2>/dev/null; then
      log_err "Failed to add route ${REMOTE_IP}/32 via $GW dev $IFACE (onlink) to table $TABLE"
    fi
  else
    if ! ip route replace ${REMOTE_IP}/32 via "$GW" dev "$IFACE" table $TABLE 2>/dev/null; then
      log_err "Failed to add route ${REMOTE_IP}/32 via $GW dev $IFACE to table $TABLE"
    fi
  fi

  # ip rule from container
  if ! ip_rule_exists "$CIP" "$TABLE"; then
    if ! ip rule add from "$CIP" lookup $TABLE 2>/dev/null; then
      log_err "Failed to add ip rule from $CIP lookup $TABLE"
    fi
  fi

  # NAT: masquerade container source when leaving via IFACE
  iptables_add_if_missing nat POSTROUTING -s ${CIP}/32 -o "$IFACE" -j MASQUERADE

  # save state for teardown (simple key=value), include podman opts
  PODMAN_OPTS_STRING="$OPTS_STRING"
  # store the container id so teardown can operate even if the name is no longer resolvable
  CONTAINER_ID=$("${PODMAN_CMD[@]}" inspect --format '{{.Id}}' "$PODMAN_TARGET" 2>/dev/null || true)
  save_state "$TARGET"

  log_info "Applied routing: $CIP -> $REMOTE_IP via $IFACE (gw $GW)"
}

teardown(){
  if [[ $# -lt 1 ]]; then usage; exit 2; fi
  local TARGET="$1"
  # try to read saved state (if present) so we can use CONTAINER_ID as fallback
  read_state "$TARGET"
  sf=$(state_file "$TARGET")

  # CLI table argument takes precedence over saved state; default to 'main'
  TABLE="${TABLE_ARG:-${TABLE:-main}}"

  # If podman options were saved, reconstruct PODMAN_CMD so inspect/exec use same options
  if [[ -n "${PODMAN_OPTS_STRING:-}" ]]; then
    build_podman_cmd_from_string "$PODMAN_OPTS_STRING"
  fi

  # Resolve podman target (may return id or the original candidate)
  PODMAN_TARGET=$(resolve_podman_target "$TARGET")

  if [[ "${WAIT_FOR_STOP:-0}" -eq 1 ]]; then
    wait_for_stopped "$PODMAN_TARGET" || err "container $TARGET did not stop within timeout"
  else
    log_info "Not waiting for container to stop (use --wait to enable)"
  fi

  if [[ ! -f "$sf" ]]; then
    log_info "state file $sf missing. Attempting best-effort cleanup."
    CIP=$("${PODMAN_CMD[@]}" inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$PODMAN_TARGET" 2>/dev/null | awk '{print $1}' || true)
    REMOTE_IP=""
    IFACE=""
    GW=""
    TABLE="${TABLE_ARG:-main}"
    PODMAN_OPTS_STRING=""
  fi

  # remove ip rule
  if [[ -n "$CIP" ]]; then
    if ip_rule_exists "$CIP" "$TABLE"; then
      ip rule del from "$CIP" lookup $TABLE || true
    fi
  fi

  # remove host route
  if [[ -n "$REMOTE_IP" && -n "$GW" && -n "$IFACE" ]]; then
    if ! ip route del ${REMOTE_IP}/32 via "$GW" dev "$IFACE" table $TABLE 2>/dev/null; then
      log_err "Failed to delete route ${REMOTE_IP}/32 via $GW dev $IFACE from table $TABLE"
    fi
  fi

  # remove nat rule
  if [[ -n "$CIP" && -n "$IFACE" ]]; then
    iptables_del_if_present nat POSTROUTING -s ${CIP}/32 -o "$IFACE" -j MASQUERADE
  fi

  rm -f "$sf" || true

  # If there are no remaining state files, remove the state directory to keep /run tidy
  remove_state_dir_if_empty

  # If we created a routing table for this target and it is now unused, remove it
  remove_table_if_empty

  log_info "Teardown complete for $TARGET"

}

cleanup(){
  # Scan for state files in STATE_DIR and perform best-effort cleanup.
  log_info "Running cleanup (scanning state directories)"
  found=0
  processed=""

  for sf in "${STATE_DIR}"*.state; do
    # glob may return literal pattern if no matches
    if [[ ! -f "$sf" ]]; then continue; fi
    # avoid processing same file twice
    case " $processed " in
      *" $sf "*) continue;;
    esac
    processed="$processed $sf"
    found=1
    log_info "Processing state file: $sf"

    # derive target name from filename: <target>.state
    bn=$(basename "$sf")
    target=${bn%.state}

    # Ensure teardown reads the saved PODMAN_OPTS/TABLE from the state file.
    # Preserve the caller's WAIT_FOR_STOP (i.e. respect --wait if provided).
    old_OPTS_STRING="${OPTS_STRING-}"
    old_TABLE_ARG="${TABLE_ARG-}"
    OPTS_STRING=""
    TABLE_ARG=""

    # call teardown to perform the same cleanup steps and remove the state file
    teardown "$target" || log_info "teardown failed for $target (continuing)"

    # restore caller state
    OPTS_STRING="$old_OPTS_STRING"
    TABLE_ARG="$old_TABLE_ARG"
  done

  log_info "Cleanup complete"
}

case "$MODE" in
  apply) apply "$@" ;; 
  teardown) teardown "$@" ;; 
  cleanup) cleanup "$@" ;; 
  *) usage; exit 2 ;;
esac
