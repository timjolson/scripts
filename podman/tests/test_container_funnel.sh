#!/usr/bin/env bash

# Automated tests for container_funnel.sh
# Usage: sudo ./test_container_funnel.sh <iface> [cycles]
# Example: sudo ./test_container_funnel.sh eth0 3
#
# Notes:
# - The tested script stores state files under /run/podman/routes/ by default.
# - Podman options for the test environment are passed via -o "--root ... --runroot ..."

# Do not use 'set -e' per user preference; check errors explicitly
PROG=/usr/local/bin/scripts/podman/container_funnel.sh
PODMAN_ROOT=/usr/local/bin/configs/pods/containers
PODMAN_RUNROOT=/usr/local/bin/configs/pods/containers/tmp
CONTAINER_NAME=media-vpn
POD_NAME=media
SERVICE=vpn.service
DEFAULT_TABLE=main
IFACE=${1:-}
CYCLES=${2:-2}
TIMEOUT=20
SLEEP_BETWEEN=15

usage(){
  cat <<EOF
Usage: $0 <iface> [cycles]
Example: sudo $0 eth0 2
EOF
}

fail(){ echo "FAIL: $*" >&2; exit 1; }
info(){ echo "[INFO] $*"; }

require_root(){
  if [[ $(id -u) -ne 0 ]]; then
    fail "Test must be run as root"
  fi
}

# Debug helpers: print interface, addr, ip rules, route table, and iptables
dump_interface(){
  local iface="$1"
  echo "--- Interface: $iface ---"
  ip link show dev "$iface" || true
  ip -4 addr show dev "$iface" || true
}

dump_ip_rules(){
  echo "--- ip rules ---"
  ip rule show || true
}

dump_route_table(){
  local table="$1"
  echo "--- ip route table $table ---"
  ip route show table $table || true
}

dump_routes_for_iface(){
  local iface="$1"
  echo "--- ip route get 8.8.8.8 oif $iface ---"
  ip route get 8.8.8.8 oif "$iface" 2>/dev/null || true
}

dump_iptables_nat(){
  echo "--- iptables nat POSTROUTING ---"
  iptables -t nat -L POSTROUTING -n -v || true
}

debug_state(){
  local tag="$1" iface="$2" table="$3" cip="$4"
  echo "==== STATE: $tag ===="
  dump_interface "$iface"
  dump_routes_for_iface "$iface"
  dump_ip_rules
  dump_route_table "$table"
  if [[ -n "$cip" ]]; then
    echo "--- ip rule lookup for $cip ---"
    ip rule show | grep --color=never "$cip" || true
  fi
  dump_iptables_nat
  echo "==== END STATE: $tag ===="
}

test_state_dir(){
  info "Testing STATE_DIR creation and writability"
  STATE_DIR_TEST="/run/podman/routes"
  rm -rf "$STATE_DIR_TEST" 2>/dev/null || true

  # invoking cleanup will run the script which may create and/or remove STATE_DIR.
  OUT=$("$PROG" cleanup 2>&1 || true)

  # Allow a short grace period for cleanup to finish and remove the dir
  for i in $(seq 1 5); do
    if [[ ! -d "$STATE_DIR_TEST" ]]; then
      info "STATE_DIR absent after cleanup (acceptable): $STATE_DIR_TEST"
      return 0
    fi
    if [[ -z "$(find "$STATE_DIR_TEST" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
      info "STATE_DIR present but empty after cleanup; removing: $STATE_DIR_TEST"
      rmdir "$STATE_DIR_TEST" >/dev/null 2>&1 || true
      return 0
    fi
    sleep 1
  done

  # Final check after waiting
  if [[ ! -d "$STATE_DIR_TEST" ]]; then
    info "STATE_DIR absent after cleanup (acceptable): $STATE_DIR_TEST"
    return 0
  fi
  if [[ -z "$(find "$STATE_DIR_TEST" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
    info "STATE_DIR present but empty after cleanup; removing: $STATE_DIR_TEST"
    rmdir "$STATE_DIR_TEST" >/dev/null 2>&1 || true
    return 0
  fi

  fail "STATE_DIR present and not empty after cleanup: $STATE_DIR_TEST"
}

podman_cmd(){
  podman --root "$PODMAN_ROOT" --runroot "$PODMAN_RUNROOT" "$@"
}

# Return 0 if a container with the given name or id is running according to `podman ps` status
container_is_running(){
  local name="$1"
  local lines line id names status
  # Always use the configured podman_cmd (with --root/--runroot) to detect containers
  _scan_output(){
    mapfile -t lines < <(podman_cmd ps --format '{{.ID}}|{{.Names}}|{{.Status}}' 2>/dev/null || true)
    for line in "${lines[@]}"; do
      IFS='|' read -r id names status <<< "$line"
      # Match by name, exact id, or prefix (handle full vs short IDs)
      if [[ " $names " == *" $name "* ]] || [[ "$id" == "$name" ]] || [[ "$name" == "$id"* ]] || [[ "$id" == "$name"* ]]; then
        if echo "$status" | grep -qiE '(^| )[Uu]p|[Rr]unning'; then
          return 0
        fi
      fi
    done
    return 1
  }

  if _scan_output; then
    return 0
  fi
  return 1
}

# Return 0 if the pod has at least one running container
pod_has_running_container(){
  local podname="$1"
  ids=$(podman_cmd pod inspect --format '{{range .Containers}}{{.Id}} {{end}}' "$podname" 2>/dev/null || true)
  for id in $ids; do
    if container_is_running "$id"; then
      return 0
    fi
  done
  return 1
}

wait_for_container(){
  local name="$1"; local timeout=${2:-$TIMEOUT}
  local end=$((SECONDS+timeout))
  info "Waiting up to $timeout s for container/pod '$name' to be running"
  local last_check=0
  while [[ $SECONDS -lt $end ]]; do
    # If there's a systemd unit for this name and it's inactive, treat as stopped.
    if systemctl list-units --type=service --all | grep -q " ${name}.service"; then
      sstate=$(systemctl is-active "${name}.service" 2>/dev/null || echo "inactive")
      info "systemd ${name}.service state (stop-wait): $sstate"
      if [[ "$sstate" != "active" ]]; then
        info "systemd reports ${name}.service is not active; assuming stopped"
        return 0
      fi
    fi
    # Quick checks each loop: prefer detecting a container by name/ID first,
    # then check whether the given name is a pod that already has running containers.
    if container_is_running "$name"; then
      info "$name is running"
      return 0
    fi
    if podman_cmd pod inspect "$name" >/dev/null 2>&1; then
      if pod_has_running_container "$name"; then
        info "pod $name has running container(s)"
        return 0
      fi
    fi
    # if systemd service exists and is active, try a faster check
    if systemctl list-units --type=service --all | grep -q " ${name}.service"; then
      state=$(systemctl is-active "${name}.service" 2>/dev/null || echo "unknown")
      info "systemd ${name}.service state: $state"
      if [[ "$state" != "active" ]]; then
        fail "systemd ${name}.service is in state '$state' (expected active)"
      fi
      # service active — check podman immediately
      if podman_cmd pod inspect "$name" >/dev/null 2>&1; then
        if pod_has_running_container "$name"; then
          info "pod $name has running container(s)"
          return 0
        fi
      else
        if container_is_running "$name"; then
          info "$name is running"
          return 0
        fi
      fi
    fi

    # generic podman check every loop: if name is a pod, check containers in pod; otherwise check for container name
    if podman_cmd pod inspect "$name" >/dev/null 2>&1; then
      if pod_has_running_container "$name"; then
        info "pod $name has running container(s)"
        return 0
      fi
    else
      if container_is_running "$name"; then
        info "$name is running"
        return 0
      fi
    fi

    # every 10s print a short heartbeat
    if (( SECONDS - last_check >= 10 )); then
      remaining=$((end - SECONDS))
      info "still waiting for $name... (${remaining} seconds left)"
      last_check=$SECONDS
    fi
    sleep 5
  done
  return 1
}

wait_for_container_stopped(){
  local name="$1" timeout=${2:-$TIMEOUT} end=$((SECONDS+timeout))
  info "Waiting up to $timeout s for container/pod '$name' to stop"
  while [[ $SECONDS -lt $end ]]; do
    # If there's a systemd unit for this name and it's inactive, treat as stopped.
    if systemctl list-units --type=service --all | grep -q " ${name}.service"; then
      sstate=$(systemctl is-active "${name}.service" 2>/dev/null || echo "inactive")
      info "systemd ${name}.service state (stop-wait): $sstate"
      if [[ "$sstate" != "active" ]]; then
        info "systemd reports ${name}.service is not active; assuming stopped"
        return 0
      fi
    fi

    # Use `podman ps -a` to determine whether the container/pod entries exist
    mapfile -t lines < <(podman_cmd ps -a --format '{{.ID}}|{{.Names}}|{{.Status}}' 2>/dev/null || true)
    found=0
    for line in "${lines[@]}"; do
      IFS='|' read -r id names status <<< "$line"
      if [[ " $names " == *" $name "* ]] || [[ "$id" == "$name" ]] || [[ "$name" == "$id"* ]] || [[ "$id" == "$name"* ]]; then
        found=1
        # If status indicates running/up, then not stopped yet
        if echo "$status" | grep -qiE '(^| )[Uu]p|[Rr]unning'; then
          break
        else
          info "$name appears stopped (ps -a status: $status)"
          return 0
        fi
      fi
    done

    # If this is a pod and we didn't find matching ps entries by name,
    # inspect the pod to enumerate member containers and check their ps states.
    if [[ $found -eq 0 ]] && podman_cmd pod inspect "$name" >/dev/null 2>&1; then
      ids=$(podman_cmd pod inspect --format '{{range .Containers}}{{.Id}} {{end}}' "$name" 2>/dev/null || true)
      any_running=0
      for id in $ids; do
        # Look up status from ps -a lines first
        sline=$(printf "%s
" "${lines[@]}" | grep "^$id|" || true)
        st=$(echo "$sline" | awk -F'|' '{print $3}' || true)
        if [[ -z "$st" ]]; then
          st=$(podman_cmd inspect --format '{{.State.Status}}' "$id" 2>/dev/null || true)
        fi
        if echo "$st" | grep -qiE '(^| )[Uu]p|[Rr]unning'; then
          any_running=1
          break
        fi
      done
      if [[ $any_running -eq 0 ]]; then
        info "pod $name appears stopped (no running containers)"
        return 0
      fi
    fi

    sleep 1
  done
  return 1
}

get_container_ip(){
  local target="$1"
  local ip
  ip=$(podman_cmd inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$target" 2>/dev/null | awk '{print $1}' || true)
  if [[ -z "$ip" ]]; then
    # try pod infra
    infra=$(podman_cmd pod inspect --format '{{.InfraContainerID}}' "$target" 2>/dev/null || true)
    if [[ -n "$infra" && "$infra" != "<no value>" ]]; then
      ip=$(podman_cmd inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$infra" 2>/dev/null | awk '{print $1}' || true)
    fi
  fi
  echo "$ip"
}

find_wg_container_in_pod(){
  local podname="$1"
  # list container IDs in pod
  local ids
  ids=$(podman_cmd ps --pod "$podname" --format '{{.ID}}' 2>/dev/null || true)
  for id in $ids; do
    # try wg showconf
    ep=$(podman_cmd exec "$id" sh -c 'wg showconf 2>/dev/null | awk -F= "/Endpoint/ {gsub(/ /,"",$2); print $2; exit}"' 2>/dev/null || true)
    if [[ -n "$ep" ]]; then
      echo "$id"
      return 0
    fi
    # try /dev/shm/wg0.conf
    if podman_cmd exec "$id" -- sh -c '[ -f "/dev/shm/wg0.conf" ]' 2>/dev/null; then
      echo "$id"
      return 0
    fi
  done
  return 1
}

verify_rule_present(){
  local cip="$1"; local table="$2"
  ip rule show | grep -q "from $cip lookup $table"
}

verify_route_table_has_default(){
  local table="$1"
  ip route show table $table | grep -q "default"
}

verify_iptables_masq(){
  local cip="$1" iface="$2"
  iptables -t nat -C POSTROUTING -s ${cip}/32 -o "$iface" -j MASQUERADE >/dev/null 2>&1
}

# start/stop helpers
start_service(){
  info "Starting service '$SERVICE' (systemctl)"
  systemctl start $SERVICE || true
}

stop_service(){
  info "Stopping service '$SERVICE'"
  # Use blocking stop so systemd begins the shutdown synchronously.
  systemctl stop "$SERVICE" >/dev/null 2>&1 || true
  # Poll `is-active --quiet` and exit immediately when the unit is no longer active.
  local i prev_state=""
  for i in $(seq 1 30); do
    if systemctl is-active --quiet "$SERVICE" >/dev/null 2>&1; then
      state="active"
    else
      state=$(systemctl is-active "$SERVICE" 2>/dev/null || echo "inactive")
    fi
    if [[ "$state" != "$prev_state" ]]; then
      info "systemd $SERVICE state: $state"
      prev_state="$state"
    fi
    if [[ "$state" == "inactive" || "$state" == "failed" || "$state" == "unknown" ]]; then
      return 0
    fi
    sleep 1
  done
  info "Timed out waiting for $SERVICE to stop"
  return 1
}

run_cycle_target(){
  local iface="$1" target="$2"
  info "=== Test cycle on iface=$iface target=$target ==="
  # We'll run three sub-cycles: default, explicit -g, and --onlink (with -g).
  modes=("" "-g" "--onlink -g")
  for m in "${modes[@]}"; do
    # start service and wait for the container/pod
    start_service
    sleep 10
    if ! wait_for_container "$target" 30; then
      fail "Container $target did not start within timeout"
    fi

    # Debug: state after start
    debug_state "post-start" "$iface" $DEFAULT_TABLE ""

    # We'll let the tested script resolve pod -> infra container itself.
    # Invoke apply and then read the saved state file to obtain CIP and REMOTE_IP.

    # determine a gateway to use for -g tests (prefer iface-specific)
    GW=$(ip route get "$REMOTE_IP" oif "$iface" 2>/dev/null | awk '/via/ {for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}' | head -n1)
    if [[ -z "$GW" ]]; then
      GW=$(ip route show default 2>/dev/null | awk '/via/ {for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}' | head -n1)
    fi

    # For each mode, build extra args and run apply/verify/teardown
    if [[ "$m" == "" ]]; then
      extra=""
      mode_desc="default"
    elif [[ "$m" == "-g" ]]; then
      extra="-g $GW"
      mode_desc="-g"
    else
      extra="--onlink -g $GW"
      mode_desc="--onlink -g"
    fi

    info "Applying routing ($mode_desc) for $CIP via $iface (target: $target)"
    ROUTES_BEFORE=$(mktemp)
    ip route show table $DEFAULT_TABLE > "$ROUTES_BEFORE" 2>/dev/null || true

    # invoke apply (pass podman options via -o string)
    $PROG apply $extra -o "--root $PODMAN_ROOT --runroot $PODMAN_RUNROOT" $iface $target || fail "Applying routing failed (mode $mode_desc)"

    sleep 2
    # read state file saved by the script to get CIP and REMOTE_IP
    SF_PATH="/run/podman/routes/${target}.state"
    if [[ ! -f "$SF_PATH" ]]; then
      fail "state file not found after apply: $SF_PATH"
    fi
    CIP=$(awk -F= '/^CIP=/{print $2; exit}' "$SF_PATH" || true)
    REMOTE_IP=$(awk -F= '/^REMOTE_IP=/{print $2; exit}' "$SF_PATH" || true)
    if [[ -z "$CIP" ]]; then
      fail "Could not determine CIP from state file: $SF_PATH"
    fi
    if [[ -z "$REMOTE_IP" ]]; then
      fail "Could not determine REMOTE_IP from state file: $SF_PATH"
    fi
    debug_state "post-apply ($mode_desc)" "$iface" $DEFAULT_TABLE "$CIP"

    if ! verify_rule_present "$CIP" $DEFAULT_TABLE; then
      fail "ip rule from $CIP lookup $DEFAULT_TABLE not found (mode $mode_desc)"
    fi
    info "ip rule present ($mode_desc)"

    ROUTES_AFTER=$(mktemp)
    ip route show table $DEFAULT_TABLE > "$ROUTES_AFTER" 2>/dev/null || true
    ADDED_ROUTE=$(grep -F -x -v -f "$ROUTES_BEFORE" "$ROUTES_AFTER" | sed -n '1p' || true)
    rm -f "$ROUTES_BEFORE" "$ROUTES_AFTER"
    if [[ -z "$ADDED_ROUTE" ]]; then
      fail "Could not determine added route in table $DEFAULT_TABLE (mode $mode_desc)"
    fi
    info "route present in table ($mode_desc): $ADDED_ROUTE"

    if ! verify_iptables_masq "$CIP" "$iface"; then
      fail "iptables MASQUERADE rule missing for $CIP on $iface (mode $mode_desc)"
    fi
    info "iptables MASQUERADE present ($mode_desc)"

    # Teardown while the container/pod remains running (no --wait)
    info "Teardown routing while container remains running ($mode_desc)"
    $PROG teardown -o "--root $PODMAN_ROOT --runroot $PODMAN_RUNROOT" $target || fail "Delete routing failed (mode $mode_desc)"

    sleep 1
    debug_state "post-teardown ($mode_desc)" "$iface" $DEFAULT_TABLE "$CIP"
    if verify_rule_present "$CIP" $DEFAULT_TABLE; then
      fail "ip rule still present after deletion (mode $mode_desc)"
    fi
    if [[ -n "$ADDED_ROUTE" ]]; then
      if ip route show table $DEFAULT_TABLE | grep -F -x -q "$ADDED_ROUTE"; then
        fail "route still present after deletion (mode $mode_desc): $ADDED_ROUTE"
      fi
    fi
    if verify_iptables_masq "$CIP" "$iface"; then
      fail "iptables MASQUERADE still present after deletion (mode $mode_desc)"
    fi

    # ensure state file was removed from the configured state dir
    STATE_PREFIX=$(basename "$PROG")
    STATE_PREFIX=${STATE_PREFIX%.*}
    SF_PATH="/run/podman/routes/${STATE_PREFIX}_${target}.state"
    if [[ -f "$SF_PATH" ]]; then
      fail "state file still present after teardown: $SF_PATH"
    fi

    info "Sub-cycle complete for $mode_desc"
    # small pause before next sub-cycle
    sleep $SLEEP_BETWEEN
  done

  info "Cycle complete for $iface target=$target"

  # Test teardown with --wait: stop the service and call teardown --wait to ensure
  # the script blocks until the container/pod is stopped and then cleans up.
  info "Testing teardown with --wait: stopping $SERVICE and calling teardown --wait"
  # Ensure service is running and routing applied
  start_service
  sleep 5
  if ! wait_for_container "$target" 30; then
    fail "Container $target did not start before --wait test"
  fi

  # Apply routing for the test (use podman opts)
  $PROG apply -o "--root $PODMAN_ROOT --runroot $PODMAN_RUNROOT" $iface $target || fail "Applying routing for --wait test failed"
  sleep 1
  SF_PATH="/run/podman/routes/${target}.state"
  if [[ ! -f "$SF_PATH" ]]; then
    fail "state file not found for --wait test: $SF_PATH"
  fi
  CIP=$(awk -F= '/^CIP=/{print $2; exit}' "$SF_PATH" || true)
  REMOTE_IP=$(awk -F= '/^REMOTE_IP=/{print $2; exit}' "$SF_PATH" || true)
  if [[ -z "$CIP" ]]; then
    fail "Could not determine CIP from state file for --wait test: $SF_PATH"
  fi

  # Stop the service in background so teardown --wait has something to wait on
  stop_service &
  stop_pid=$!
  sleep 1

  # Call teardown with --wait; it should block until the container is stopped
  if ! $PROG teardown --wait -o "--root $PODMAN_ROOT --runroot $PODMAN_RUNROOT" $target; then
    fail "Teardown with --wait failed"
  fi
  # Ensure background stopper finished (best-effort)
  wait $stop_pid 2>/dev/null || true

  # Verify cleanup took place
  if [[ -f "$SF_PATH" ]]; then
    fail "state file still present after teardown --wait: $SF_PATH"
  fi
  if verify_rule_present "$CIP" $DEFAULT_TABLE; then
    fail "ip rule still present after teardown --wait"
  fi


  # Additional coverage: test using a custom table name via -t
  CUSTOM_TABLE="podman_test_tbl_$(date +%s)"
  info "Testing custom table name: $CUSTOM_TABLE"

  # Ensure fresh state in configured state dir
  rm -f "/run/podman/routes/${target}.state" 2>/dev/null || true

  # apply with explicit table
  $PROG apply -t "$CUSTOM_TABLE" -o "--root $PODMAN_ROOT --runroot $PODMAN_RUNROOT" $iface $target || fail "Applying routing with custom table failed"
  sleep 1

  # verify state file exists and contains TABLE and PODMAN_OPTS
  SF="/run/podman/routes/${target}.state"
  if [[ ! -f "$SF" ]]; then
    fail "state file not found after apply: $SF"
  fi
  if ! grep -q "TABLE=$CUSTOM_TABLE" "$SF"; then
    fail "state file missing TABLE entry or wrong value: $SF"
  fi
  if ! grep -q "PODMAN_OPTS=" "$SF"; then
    fail "state file missing PODMAN_OPTS entry: $SF"
  fi
  if ! grep -q "CONTAINER_ID=" "$SF"; then
    fail "state file missing CONTAINER_ID entry: $SF"
  fi

  # verify ip rule and route present using the custom table
  if ! verify_rule_present "$CIP" "$CUSTOM_TABLE"; then
    fail "ip rule from $CIP lookup $CUSTOM_TABLE not found"
  fi
  if ! ip route show table $CUSTOM_TABLE | grep -q "$REMOTE_IP"; then
    fail "route for $REMOTE_IP not present in table $CUSTOM_TABLE"
  fi

  # teardown and verify cleanup
  $PROG teardown -t "$CUSTOM_TABLE" -o "--root $PODMAN_ROOT --runroot $PODMAN_RUNROOT" $target || fail "Teardown failed for custom table"
  sleep 1
  if [[ -f "$SF" ]]; then
    fail "state file still present after teardown for custom table: $SF"
  fi

}

main(){
  require_root

  # verify state dir behavior before running container tests
  test_state_dir

  # run cycles for explicit container name first
  run_cycle_target "$IFACE" "$CONTAINER_NAME"
  for i in $(seq 2 $CYCLES); do
    info "Waiting $SLEEP_BETWEEN s before restart cycle $i (container)"
    sleep $SLEEP_BETWEEN
    stop_service
    sleep $SLEEP_BETWEEN
    start_service
    sleep $SLEEP_BETWEEN
    run_cycle_target "$IFACE" "$CONTAINER_NAME"
  done

  # Pod-based tests removed — script and tests now operate on containers only.

  info "All cycles completed on $IFACE"
  info "If you want to test on eth1, run: sudo $0 eth1 $CYCLES"
}

main "$@"
