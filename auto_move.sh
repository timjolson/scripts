#!/usr/bin/env bash
# rclone_auto_move.sh - Move files from src to dest using rclone when src usage is high.
#
# Single-run wrapper that executes exactly one `rclone move` per invocation when
# the `--src` usage exceeds `--trigger`. The script computes a transfer cap
# (based on destination free space, `--min-dest-space`, `--target`, and an
# optional user `--max-transfer`) and runs a single `rclone move` capped to that
# size. It preserves user-supplied rclone arguments and
# does not auto-inject rclone `--stats` or `--use-json-log` flags.
#
# Features:
#  - Single `rclone move` per execution (no internal batching).
#  - Supports `--trigger` / `--target` percentages.
#  - Supports `--min-dest-space`, `--max-transfer`, `--precmd`, `--postcmd`,
#    `--dry-run`, and `--debug`.
#  - Treats rclone exit codes 8 (`--max-transfer`) and 10 (`--max-duration`) as
#    partial success if transfer activity was observed.
#  - Prevents accidental same-FS local moves.
#
# Debugging:
#  - When `--debug` is supplied the script will save the raw rclone capture to
#    `/tmp/rclone_auto_move_rclone_output_<ts>.log` for inspection.
#  - For deterministic parsing of per-file events you can pass rclone
#    `--use-json-log --log-file /tmp/file` as rclone args (the script will not
#    auto-add these flags by default).
#
# Exit codes (summary):
#  - 0  success
#  - 2  invalid/missing args
#  - 28 destination ran out of space
#  - other: rclone exit codes are propagated except where remapped for
#    partial-success semantics (8,10 when activity observed)

set -u
set -o pipefail
# Do NOT set -e so we can run cleanup and postcmd reliably.

progname="$(basename "$0")"

# Defaults / options
src=""
dest=""
# by default, do a transfer
trigger="-50"
# by default, transfer all available files
target="-99"
# by default, don't require any minimum space on dest
min_dest_space="0"
precmd=""
postcmd=""
dryrun=false
rclone_extra_args=()
user_max_transfer=""
debug=false

ran_precmd=false
transfer_performed=false
ran_out_of_space=false
termination_requested=false
termination_signal=""
termination_exit_code=0
run_postcmd_on_termination=true

# Use stdbuf if available to force line-buffered output for rclone and tee.
if command -v stdbuf >/dev/null 2>&1; then
    stdbuf_prefix=(stdbuf -oL -eL)
else
    stdbuf_prefix=()
fi

log() {
    echo "$progname: $*"
}

usage() {
        cat <<'EOF'
Usage: rclone_auto_move.sh --src <src> --dest <dest> [--trigger <percent>] [--target <percent>] [--min-dest-space <size|%>] [--precmd '<cmd>'] [--postcmd '<cmd>'] [--debug] [rclone args]

Single-run wrapper: runs one `rclone move` when `--src` usage >= `--trigger`.

Options:
    --min-dest-space <size|%>   Minimum free space to keep on destination (size or percent).
    --max-transfer <size>       Optional cap for this run (rclone SizePrefix supported, e.g. 2G).
    --precmd '<cmd>'            Command to run before the transfer (runs only if transfer will occur).
    --postcmd '<cmd>'           Command to run after a successful transfer (runs only if transfer occurred).
    --debug                     Save raw rclone capture to /tmp for debugging.
    --dry-run                   Don't perform transfers (passed to rclone; precmd/postcmd skipped).
    --help                      Show this help and exit.

    Any non-script arguments are passed directly to `rclone move` (the script
    will always add `--max-transfer` based on internal caps but otherwise preserves
    user flags; the script does not add `--stats` or `--use-json-log` automatically).

Examples:
    rclone_auto_move.sh --src /mnt/src --dest /mnt/dest --trigger 90 --target 85 --min-dest-space 5G --metadata -v
    rclone_auto_move.sh --src /mnt/src --dest remote:bucket/path --trigger 90 --target 80 --max-transfer 2G --debug --use-json-log --log-file /tmp/rclone.json

Notes:
    - The script detects transfers by parsing rclone JSON logs or human-readable
        INFO/NOTICE lines. For deterministic JSON detection pass
        `--use-json-log --log-file <path>` in the rclone args (recommended when
        debugging).
    - SIGINT (interactive Ctrl-C) will skip `--postcmd`; SIGTERM/SIGHUP will run it.
    - Exit code 28 indicates destination ran out of space.
EOF
    exit 2
}

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --src) src="$2"; shift 2;;
        --dest) dest="$2"; shift 2;;
        --trigger) trigger="$2"; shift 2;;
        --target) target="$2"; shift 2;;
        --min-dest-space) min_dest_space="$2"; shift 2;;
        --max-transfer) user_max_transfer="$2"; shift 2;;
        --debug) debug=true; shift;;
        --precmd) precmd="$2"; shift 2;;
        --postcmd) postcmd="$2"; shift 2;;
        --dry-run|--dryrun) dryrun=true; shift;;
        --help) usage;;
        *) rclone_extra_args+=("$1"); shift;;
    esac
done


[ -z "$src" ] && { log "Missing --src"; usage; }
[ -z "$dest" ] && { log "Missing --dest"; usage; }

is_remote() {
    local p="$1"
    [[ "$p" == *:* && "${p:0:1}" != "/" ]]
}

validate_path() {
    local p="$1"
    if is_remote "$p"; then
        if ! rclone lsd "$p" --max-depth 1 >/dev/null 2>&1; then
            log "Remote path unreachable: $p"
            return 2
        fi
    else
        if [ ! -d "$p" ]; then
            log "Local path does not exist: $p"
            return 2
        fi
    fi
    return 0
}

if ! validate_path "$src"; then exit 2; fi
if ! validate_path "$dest"; then exit 2; fi

# Verify src and dest are not on same filesystem when both local
if ! is_remote "$src" && ! is_remote "$dest"; then
    src_dev=$(stat -c %d "$src" 2>/dev/null || echo "")
    dest_dev=$(stat -c %d "$dest" 2>/dev/null || echo "")
    if [[ -n "$src_dev" && -n "$dest_dev" && "$src_dev" == "$dest_dev" ]]; then
        log "Source and destination are on the same filesystem; refusing to run."
        exit 2
    fi
fi

get_dest_space_bytes() {
    local target="$1"
    if is_remote "$target"; then
        local about
        about=$(rclone about "$target" --json 2>/dev/null) || { echo "0 0"; return 0; }
        local compact
        compact=$(echo "$about" | tr -d '[:space:]')
        local free total
        free=$(echo "$compact" | sed -n 's/.*"free":\([0-9]\+\).*/\1/p')
        total=$(echo "$compact" | sed -n 's/.*"total":\([0-9]\+\).*/\1/p')
        [ -z "$free" ] && free=0
        [ -z "$total" ] && total=0
        printf "%s %s" "$free" "$total"
    else
        local avail size
        read size avail < <(df -B1 --output=size,avail "$target" | tail -n1)
        size="${size:-0}"
        avail="${avail:-0}"
        printf "%s %s" "$avail" "$size"
    fi
}

get_src_usage_percent() {
    local s="$1"
    if is_remote "$s"; then
        local about compact free total
        about=$(rclone about "$s" --json 2>/dev/null) || { echo 0; return; }
        compact=$(echo "$about" | tr -d '[:space:]')
        free=$(echo "$compact" | sed -n 's/.*"free":\([0-9]\+\).*/\1/p')
        total=$(echo "$compact" | sed -n 's/.*"total":\([0-9]\+\).*/\1/p')
        [ -z "$free" ] && free=0
        [ -z "$total" ] && total=0
        if [ "$total" -gt 0 ]; then
            awk -v t="$total" -v f="$free" 'BEGIN{printf("%d", ((t-f)*100)/t)}'
        else
            echo 0
        fi
    else
        df -B1 --output=size,avail "$s" | tail -n1 | awk '{ if ($1>0) printf "%d", (($1-$2)*100)/$1; else print 0 }'
    fi
}

parse_size_to_bytes() {
    local raw="$1"
    local total_bytes="${2:-0}"
    local up low

    # Normalize and strip spaces
    up=$(echo "$raw" | tr -d '[:space:]')
    low=$(echo "$up" | tr '[:upper:]' '[:lower:]')

    # Percent form (e.g. 10%)
    if [[ "$low" =~ ^([0-9]+(\.[0-9]+)?)%$ ]]; then
        local pct="${BASH_REMATCH[1]}"
        awk -v total="$total_bytes" -v p="$pct" 'BEGIN{printf("%.0f", total * p / 100)}'
        return 0
    fi

    # Accept common SI/IEC suffixes in a case-insensitive way
    if [[ "$low" =~ ^([0-9]+(\.[0-9]+)?)(b|k|kb|ki|kib|m|mb|mi|mib|g|gb|gi|gib|t|tb|ti|tib|p|pb|pi|pib|e|eb|ei|eib)?$ ]]; then
        local num="${BASH_REMATCH[1]}"
        local unit="${BASH_REMATCH[3]}"
        case "$unit" in
            ""|b) awk -v v="$num" 'BEGIN{printf("%.0f", v)}' ;;
            k|kb) awk -v v="$num" 'BEGIN{printf("%.0f", v * 1000)}' ;;
            ki|kib) awk -v v="$num" 'BEGIN{printf("%.0f", v * 1024)}' ;;
            m|mb) awk -v v="$num" 'BEGIN{printf("%.0f", v * 1000 * 1000)}' ;;
            mi|mib) awk -v v="$num" 'BEGIN{printf("%.0f", v * 1024 * 1024)}' ;;
            g|gb) awk -v v="$num" 'BEGIN{printf("%.0f", v * 1000 * 1000 * 1000)}' ;;
            gi|gib) awk -v v="$num" 'BEGIN{printf("%.0f", v * 1024 * 1024 * 1024)}' ;;
            t|tb) awk -v v="$num" 'BEGIN{printf("%.0f", v * 1000 * 1000 * 1000 * 1000)}' ;;
            ti|tib) awk -v v="$num" 'BEGIN{printf("%.0f", v * 1024 * 1024 * 1024 * 1024)}' ;;
            p|pb) awk -v v="$num" 'BEGIN{printf("%.0f", v * 1000 * 1000 * 1000 * 1000 * 1000)}' ;;
            pi|pib) awk -v v="$num" 'BEGIN{printf("%.0f", v * 1024 * 1024 * 1024 * 1024 * 1024)}' ;;
            e|eb) awk -v v="$num" 'BEGIN{printf("%.0f", v * 1000 * 1000 * 1000 * 1000 * 1000 * 1000)}' ;;
            ei|eib) awk -v v="$num" 'BEGIN{printf("%.0f", v * 1024 * 1024 * 1024 * 1024 * 1024 * 1024)}' ;;
            *) log "Unsupported unit in size: $raw"; return 2;;
        esac
        return 0
    fi

    log "Invalid size format: $raw"
    return 2

}

bytes_to_rclone_size() {
    local b="$1"
    # Use SI units to match rclone's SizePrefix (K=1000, M=1000^2, ...)
    if [ "$b" -lt 1000 ]; then printf "%dB" "$b"; return; fi
    local val=$(( b / 1000 ))
    if [ $val -lt 1000 ]; then printf "%dK" "$val"; return; fi
    val=$(( val / 1000 )); if [ $val -lt 1000 ]; then printf "%dM" "$val"; return; fi
    val=$(( val / 1000 )); if [ $val -lt 1000 ]; then printf "%dG" "$val"; return; fi
    val=$(( val / 1000 )); printf "%dT" "$val"
}

detect_transfer_activity() {
    # $1 = path to rclone captured output
    local out="$1"
    # If rclone emitted JSON logs with stats, detect totalTransfers > 0
    if grep -qE '"totalTransfers"\s*:\s*[0-9]+' "$out" >/dev/null 2>&1; then
        return 0
    fi
    # JSON object entries for per-file events usually include an "object" field
    if grep -qE '"object"\s*:' "$out" >/dev/null 2>&1; then
        return 0
    fi
    # Human-readable summary / per-file messages (several rclone formats)
    # Match the "Word:" forms (e.g. "Copied:")
    if grep -E 'Transferred:|Renamed:|Copied:|Moved:|Deleted:' "$out" >/dev/null 2>&1; then
        return 0
    fi
    # Match action words that appear after a path and separator, e.g. ": Copied (new)" or ": Deleted"
    if grep -Ei ':\s*(Copied|Moved|Renamed|Deleted|Removed|Transferred|Created|Updated)\b' "$out" >/dev/null 2>&1; then
        return 0
    fi
    # Match log-level prefixed lines like "NOTICE: ... Copied" or "INFO  : ...: Copied"
    if grep -Ei '(NOTICE|INFO)\s*[: ]+.*\b(Copied|Moved|Renamed|Deleted|Removed|Transferred|Created|Updated)\b' "$out" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

finalize_and_exit() {
    local exit_code=${1:-0}
    local post_status=0

    # Save tmp capture only in debug mode, then always clean up the temp file.
    if [ -n "${tmp_output:-}" ] && [ -f "$tmp_output" ]; then
        if [ "$debug" = true ]; then
            outsave="/tmp/rclone_auto_move_rclone_output_$(date +%s).log"
            cp -f "$tmp_output" "$outsave" 2>/dev/null || true
            log "Saved raw rclone output to $outsave"
        fi
        rm -f "$tmp_output" || true
    fi

    # Run postcmd only when a transfer actually occurred, postcmd is set,
    # not in dry-run, and termination policy allows it.
    if $transfer_performed && [ -n "$postcmd" ] && [ "$dryrun" = false ]; then
        if [[ "$termination_requested" = true && "$run_postcmd_on_termination" != true ]]; then
            log "Skipping postcmd after ${termination_signal}."
        else
            log "Running postcmd: $postcmd"
            if output=$(bash -c "$postcmd" 2>&1); then
                log "postcmd output: $output"
            else
                post_status=$?
                log "postcmd failed with exit code $post_status"
            fi
        fi
    fi

    if [[ "$ran_out_of_space" = true ]]; then
        log "Stopped processing due to insufficient destination space."
        exit_code=28
    fi

    if [[ "$termination_requested" = true ]]; then
        log "Exiting due to ${termination_signal} with code ${exit_code}."
    else
        log "Finished with code ${exit_code}."
    fi

    exit $exit_code
}

handle_signal() {
    termination_requested=true
    termination_signal="$1"
    case "$1" in
        SIGHUP) termination_exit_code=129; run_postcmd_on_termination=true;;
        SIGINT) termination_exit_code=130; run_postcmd_on_termination=false;;
        SIGTERM) termination_exit_code=143; run_postcmd_on_termination=true;;
        *) termination_exit_code=128; run_postcmd_on_termination=true;;
    esac
    exit $termination_exit_code
}

trap 'handle_signal SIGHUP' SIGHUP
trap 'handle_signal SIGINT' SIGINT
trap 'handle_signal SIGTERM' SIGTERM
trap 'finalize_and_exit $?' EXIT

log "Initial source: $src, destination: $dest, trigger: ${trigger}%, target: ${target}%, min-dest-space: $min_dest_space, dry-run: $dryrun"

if ! [[ "$trigger" =~ ^-?[0-9]+$ ]] || ! [[ "$target" =~ ^-?[0-9]+$ ]]; then
    log "Trigger and target must be integer percentages."
    exit 2
fi

current_usage=$(get_src_usage_percent "$src")
log "Initial source usage: ${current_usage}%." 

if [ "$current_usage" -lt "$trigger" ]; then
    log "Source usage ${current_usage}% is below trigger ${trigger}%. No transfer needed."
    exit 0
fi

# Single-run transfer (no batching)
read dest_avail dest_total < <(get_dest_space_bytes "$dest")
dest_avail=${dest_avail:-0}
dest_total=${dest_total:-0}

if ! min_dest_bytes=$(parse_size_to_bytes "$min_dest_space" "$dest_total"); then
    log "Failed parsing --min-dest-space value: $min_dest_space"
    exit 2
fi

transferrable=$(( dest_avail - min_dest_bytes ))
if [ "$transferrable" -le 0 ]; then
    log "Insufficient destination space: available $dest_avail bytes, required minimum $min_dest_bytes bytes."
    ran_out_of_space=true
else
    # Determine source total/used bytes
    if is_remote "$src"; then
        about=$(rclone about "$src" --json 2>/dev/null) || { src_total=0; src_free=0; }
        compact=$(echo "$about" | tr -d '[:space:]')
        src_free=$(echo "$compact" | sed -n 's/.*"free":\([0-9]\+\).*/\1/p')
        src_total=$(echo "$compact" | sed -n 's/.*"total":\([0-9]\+\).*/\1/p')
        src_free=${src_free:-0}
        src_total=${src_total:-0}
    else
        read src_total src_free < <(df -B1 --output=size,avail "$src" | tail -n1)
        src_total=${src_total:-0}
        src_free=${src_free:-0}
    fi


    # Compute bytes needed to reduce source usage down to the target percentage
    needed_bytes=0
    if [ "$target" -ge 0 ] && [ "$current_usage" -gt "$target" ] && [ "$src_total" -gt 0 ]; then
        needed_bytes=$(( (current_usage - target) * src_total / 100 ))
    else
        # If target is negative (unset), treat needed_bytes as unlimited for target purposes
        needed_bytes=$transferrable
    fi

    # Initial cap: destination transferrable space
    cap=$transferrable

    # Cap by what is needed to reach the target
    if [ "$needed_bytes" -gt 0 ] && [ "$needed_bytes" -lt "$cap" ]; then
        cap=$needed_bytes
    fi

    # Parse user-specified --max-transfer (if any) and cap by it
    user_max_bytes=""
    if [ -n "${user_max_transfer:-}" ]; then
        user_max_bytes=$(parse_size_to_bytes "$user_max_transfer" "$dest_total") || user_max_bytes=""
        if [ -n "$user_max_bytes" ]; then
            if [ "$user_max_bytes" -lt "$cap" ]; then
                cap="$user_max_bytes"
            fi
        else
            log "Warning: unable to parse user --max-transfer: $user_max_transfer; ignoring cap."
        fi
    fi

    if [ "$cap" -le 0 ]; then
        log "Calculated transfer cap is zero; nothing to transfer."
    else
        batch_bytes="$cap"
        batch_size_str=$(bytes_to_rclone_size "$batch_bytes")
        log "Transfer caps: dest_avail=$dest_avail min_dest=$min_dest_bytes transferrable=$transferrable needed_for_target=$needed_bytes user_max=${user_max_transfer:-unset} final_max_transfer=$batch_size_str"

        if [ "$ran_precmd" = false ] && [ -n "$precmd" ] && [ "$dryrun" = false ]; then
            log "Running precmd: $precmd"
            if output=$(bash -c "$precmd" 2>&1); then
                log "precmd output: $output"
            else
                rc=$?
                log "precmd failed with exit code $rc, aborting."
                exit $rc
            fi
            ran_precmd=true
        fi

        # Build rclone argument list and include --dry-run in the args array
        rclone_args=(--max-transfer "$batch_size_str")
        if [ "$dryrun" = true ]; then
            # Avoid duplicating --dry-run if user passed it in trailing rclone args
            found=false
            for _a in "${rclone_extra_args[@]}"; do
                if [[ "$_a" == "--dry-run" ]]; then found=true; break; fi
            done
            if [ "$found" = false ]; then
                rclone_args+=("--dry-run")
            fi
        fi
        if [ "${#rclone_extra_args[@]}" -gt 0 ]; then
            rclone_args+=("${rclone_extra_args[@]}")
        fi
        rclone_cmd=(rclone move "$src" "$dest" "${rclone_args[@]}")

        log "Running: ${rclone_cmd[*]}"
        tmp_output="$(mktemp)" || tmp_output="/tmp/${progname}.$$"

        if [ ${#stdbuf_prefix[@]} -gt 0 ]; then
            "${stdbuf_prefix[@]}" "${rclone_cmd[@]}" 2>&1 | stdbuf -oL tee "$tmp_output"
        else
            "${rclone_cmd[@]}" 2>&1 | tee "$tmp_output"
        fi
        rc=${PIPESTATUS[0]}

        # Detect transfer activity from captured output (supports JSON logs and human-readable)
        if detect_transfer_activity "$tmp_output"; then
            transfer_performed=true
        fi

        if [ $rc -ne 0 ]; then
            if grep -Ei "no[[:space:]]space|disk[[:space:]]quota|insufficient[[:space:]]space|not[[:space:]]enough[[:space:]]space" "$tmp_output" >/dev/null 2>&1; then
                ran_out_of_space=true
                log "Detected destination ran out of space during transfer."
            fi

            case $rc in
                8)
                    if [ "$transfer_performed" = true ]; then
                        log "rclone reported --max-transfer reached (exit code 8) but transfer activity detected; treating as partial success."
                        # continue
                    else
                        log "rclone ended with exit code 8 (max-transfer reached) and no transfers observed."
                        exit $rc
                    fi
                    ;;
                10)
                    if [ "$transfer_performed" = true ]; then
                        log "rclone reported --max-duration reached (exit code 10) but transfer activity detected; treating as partial success."
                    else
                        log "rclone ended with exit code 10 (max-duration reached) and no transfers observed."
                        exit $rc
                    fi
                    ;;
                9)
                    log "rclone ended with exit code 9 (no files transferred with --error-on-no-transfer)."
                    exit $rc
                    ;;
                *)
                    log "rclone ended with exit code $rc."
                    exit $rc
                    ;;
            esac
        else
            if [ "$transfer_performed" = true ]; then
                log "Transfer finished successfully (rc=0)."
            else
                log "No transfer activity detected in rclone output; nothing moved."
            fi
        fi

        current_usage=$(get_src_usage_percent "$src")
        log "Updated source usage: ${current_usage}%." 

        if [ "$dryrun" = true ]; then
            log "Dry-run mode: completing after one simulated transfer."
        fi
    fi
fi

exit_code=0
[ "$ran_out_of_space" = true ] && exit_code=28

finalize_and_exit $exit_code
