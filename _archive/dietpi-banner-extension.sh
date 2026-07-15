# Import DietPi-Globals --------------------------------------------------------------
. /boot/dietpi/func/dietpi-globals

# dietpi-banner-extension.sh
# Purpose: show a compact system banner with network, disk and health information.

###
### Checking filesystem space
###
# The filesystem space section inspects mounted filesystems (via `df`) and only
# prints entries for filesystems (mounts) that match the supplied
# patterns. If a provided pattern does not match any mounted filesystem,
# no filesystem line will be printed for that pattern.
# 
# Accepts multiple glob/pattern arguments. Patterns may be provided as:
#
#  - Plain shell globs (case-style):
#      /mnt/*    matches any single-level mount under /mnt
#      /mnt/nvme matches the literal mountpoint '/mnt/nvme'
#    These are matched using a shell "case" pattern against the mount path.
#
#  - Regular expressions (ERE): prefix the pattern with 're:' to supply an
#    extended regular expression which will be matched against the full
#    mountpoint path. Example: `re:^/mnt/.{1,10}$` to match mounts whose
#    final component is 1–10 characters long.
#
#  Notes:
#  - Quote patterns when passing them on the command line to avoid shell
#    expansion, e.g. '/mnt/*' or 're:^/mnt/.{1,10}$'.
#  - Use regex patterns when you need advanced matching.
#

COLOUR_RESET='\e[0m'
aCOLOUR=(

        '\e[38;5;154m'	# DietPi green	| Lines, bullets and separators
        '\e[1m'		# Bold white	| Main descriptions
        '\e[90m'	# Grey		| Subdued text
        '\e[91m'	# Red		| Update notifications
        '\e[1;32m'      # Green         | Good state
        '\e[1;33m'      # Yellow        | Warning state
        '\e[1;36m'      # Blue          | Dynamic match
)
GREEN_LINE=" ${aCOLOUR[0]}─────────────────────────────────────────────────────$COLOUR_RESET"
GREEN_BULLET=" ${aCOLOUR[0]}-$COLOUR_RESET"
GREEN_SEPARATOR="${aCOLOUR[0]}:$COLOUR_RESET"

print_header() {
echo -e "\r$GREEN_LINE
 ${aCOLOUR[1]}$1 $GREEN_SEPARATOR"
}

print_state() {
        local subtitle="$1"
        local state="$2"
        printf "%s%s %-16s %s %s\n" \
                "$GREEN_BULLET" "${aCOLOUR[6]}" "$subtitle" "$GREEN_SEPARATOR" "$state"
}

## Curl timeout for public IP check (seconds)
timeout=2

###
### Netns WAN status and traffic check
###
interfaces=(
        "eth0"  # Main wired interface
        "eth1" # Main wireless interface
        "lan0" # Main wireless interface
        "lan1" # Secondary wireless interface
        "wlan0" # Main wireless interface
        "wlan1" # Secondary wireless interface
        "tun0"  # Common VPN interface
        "tun1"  # Another common VPN interface
        "wg0"   # Common WireGuard interface
        "wg1"   # Another common WireGuard interface
        "vpn0"  # Another common VPN interface
        "vpn1"  # Another common VPN interface
)
DATA_USAGE(){
        local netns="$1"
        # Use an array prefix so we can run commands either in a netns
        # (ip netns exec <ns> ...) or the default namespace.
        local -a ip_cmd_prefix=()
        if [[ -n "$netns" ]]; then
                ip_cmd_prefix=(ip netns exec "$netns")
        fi

        # TODO: get the full `ip link show` then process it through a case statement that matches the interfaces array. This will be much faster than running `ip link show` for each interface.
        for IFACE in "${interfaces[@]}"; do
                if "${ip_cmd_prefix[@]}" ip link show "$IFACE" > /dev/null 2>&1; then
                        local RX="N/A" TX="N/A" rx tx ip_addr ip_addr_cidr

                        if "${ip_cmd_prefix[@]}" test -r "/sys/class/net/$IFACE/statistics/rx_bytes"; then
                                rx=$("${ip_cmd_prefix[@]}" cat "/sys/class/net/$IFACE/statistics/rx_bytes" 2>/dev/null || :)
                                [[ $rx =~ ^[0-9]+$ ]] && RX="$(awk -v v="$rx" 'BEGIN{printf "%.2f", v/(1024^3)}') GiB"
                        fi

                        if "${ip_cmd_prefix[@]}" test -r "/sys/class/net/$IFACE/statistics/tx_bytes"; then
                                tx=$("${ip_cmd_prefix[@]}" cat "/sys/class/net/$IFACE/statistics/tx_bytes" 2>/dev/null || :)
                                [[ $tx =~ ^[0-9]+$ ]] && TX="$(awk -v v="$tx" 'BEGIN{printf "%.2f", v/(1024^3)}') GiB"
                        fi

                        ip_addr=" - No IP - "
                        ip_addr_cidr=$("${ip_cmd_prefix[@]}" ip -o -4 addr show dev "$IFACE" scope global 2>/dev/null | awk '{print $4}' | head -n1)
                        [[ -n "$ip_addr_cidr" ]] && ip_addr=${ip_addr_cidr%%/*}

                        if [[ "$RX" != "N/A" || "$TX" != "N/A" ]]; then
                                printf "%s %s%-20s %s%s  TX= %12s  RX= %12s%s\n" \
                                        "$GREEN_BULLET" "${aCOLOUR[2]}" "$ip_addr ($IFACE)" "$GREEN_SEPARATOR" "${aCOLOUR[2]}" "$TX" "$RX" "$COLOUR_RESET"
                        fi
                fi
        done
}

# Truncate a string in the middle to a maximum length, inserting "..."
truncate_mid() {
        local s="$1"; local max="$2"
        local len=${#s}
        if (( len <= max )); then
                printf '%s' "$s"
                return
        fi
        if (( max <= 3 )); then
                printf '%.*s' "$max" "$s"
                return
        fi
        local keep=$((max - 3))
        local pre=$(((keep + 1) / 2))
        local suf=$((keep / 2))
        local start=$((len - suf))
        printf '%s...%s' "${s:0:pre}" "${s:start}"
}

# IP address detection (IPv4)
IP_re='([0-9]{1,3}\.){3}[0-9]{1,3}'
# Common error substrings to detect timeouts / DNS failures (lowercase for case-insensitive check)
err_re='timed out|timeout|resolve|could not resolve|name or service not known'

# Function to get public IP, optionally within a network namespace
get_public_ip() {
        local ns="$1"
        if [[ -n "$ns" ]]; then
                ip netns exec "$ns" curl -sSfLm $timeout 'https://dietpi.com/geoip' 2>&1
        else
                curl -sSfLm $timeout 'https://dietpi.com/geoip' 2>&1
        fi
}

mapfile -t namespaces < <(ip netns ls | awk 'NF>1 { print $1 }')
# Prepend an empty entry so the default (root) namespace can be handled in the loop
namespaces=( "" "${namespaces[@]}" )
# if [[ ${#namespaces[@]} -gt 0 ]]; then
        print_header "Network Traffic by Namespace"
        for ns in "${namespaces[@]}"; do
                raw_ns="${ns:-default}"
                display_ns="$(truncate_mid "$raw_ns" 30)"

                # Get public IP
                IP=$(get_public_ip "$ns")

                if [[ $IP =~ $IP_re ]]; then
                        # # If an IP is detected, extract just the IP portion (use BASH_REMATCH[0])
                        # IP="${BASH_REMATCH[0]}"
                        
                        # Valid IP detected, keep as-is and print with namespace
                        printf " %s%s [%s]%s\n" \
                                "${aCOLOUR[6]}" "$IP" "$display_ns" "$COLOUR_RESET"
                        DATA_USAGE "$ns"

                elif [[ -z $IP ]]; then
                        # If the IP is empty, it likely means the namespace is disconnected or has no internet access. Print status message.
                        printf "%s %s %s %s%s%s\n" \
                                "${aCOLOUR[3]}" "Disconnected" "$GREEN_SEPARATOR" "${aCOLOUR[1]}" "$display_ns" "$COLOUR_RESET"
                        DATA_USAGE "$ns"
                else
                        if [[ $IP =~ $err_re ]]; then
                                # Treat known curl/network error messages as timeout/DNS failures
                                IP="Timeout/DNS Failure"
                        fi

                        # If the IP contains an unknown or error message, print it with the namespace
                        printf " %s%s [%s]%s\n" \
                                "${aCOLOUR[3]}" "$IP" "$display_ns" "$COLOUR_RESET"
                        DATA_USAGE "$ns"
                fi
                
        done
# fi


print_header "Used Disk Space"

# If no arguments are provided, default to "/mnt/*".
if (( $# > 0 )); then
        SPACE_BASE_PATTERNS=("$@")
else
        SPACE_BASE_PATTERNS=("/mnt/*")
fi


# TODO: is there a more efficient reader than df (stat?)
# Use df's output to parse numeric fields (kB units) for mounts matching the supplied patterns
length=0
results=()
while read -r size_kb used_kb avail_kb mnt_rest; do
        matched=0
        basename=
        for pattern in "${SPACE_BASE_PATTERNS[@]}"; do
                # If the user supplies a pattern prefixed with 're:' treat it as regex
                if [[ "$pattern" == re:* ]]; then
                        re="${pattern#re:}"
                        if [[ $mnt_rest =~ $re ]]; then
                                matched=1
                                basename=$(basename "$mnt_rest")
                                break
                        fi
                else
                # Otherwise, treat it as a shell glob pattern and match using "case"
                        case "$mnt_rest" in
                                $pattern)
                                        matched=1
                                        basename=$(basename "$mnt_rest")
                                        break
                                        ;;
                        esac
                fi
        done
        if (( matched )); then
                len=${#basename}
                if (( len > length )); then
                        length=$len
                fi
                results+=("$size_kb|$used_kb|$avail_kb|$mnt_rest|$basename")
        fi
done < <(df -k --output=size,used,avail,target | tail -n +2)

# Print results with aligned columns, converting kB to GB and calculating percentage used
for entry in "${results[@]}"; do
        IFS='|' read -r size_kb used_kb avail_kb mnt_rest name <<< "$entry"
        # name=$(basename "$entry")
        # Do all math in kB, convert to GB for display and round to 1 decimal
        if [[ "$size_kb" =~ ^[0-9]+$ ]]; then
                size_gb=$(awk "BEGIN {printf \"%.1f \", $size_kb/1024/1024}")
        else
                size_gb="N/A"
        fi
        if [[ "$used_kb" =~ ^[0-9]+$ ]]; then
                used_gb=$(awk "BEGIN {printf \"%.1f \", $used_kb/1024/1024}")
        else
                used_gb="N/A"
        fi
        if [[ "$avail_kb" =~ ^[0-9]+$ ]]; then
                avail_gb=$(awk "BEGIN {printf \"%.1f \", $avail_kb/1024/1024}")
        else
                avail_gb="N/A"
        fi
        if [[ "$size_kb" =~ ^[0-9]+$ && $size_kb -gt 0 ]]; then
                perc=$(awk "BEGIN {printf \"%.1f%%\", ($used_kb/($used_kb+$avail_kb))*100}")
        else
                perc="N/A"
        fi
        # Print aligned columns: {basename} : {used} of {size} ({percent used})
        printf "%s %s%-${length}s  %s%s %8sGiB of %8sGiB (%6s)%s\n" \
                "$GREEN_BULLET" "${aCOLOUR[6]}" "$name" "$GREEN_SEPARATOR" "${aCOLOUR[2]}" "$used_gb" "$size_gb" "$perc" "$COLOUR_RESET"
done


###
### Check systemd health
###
print_header "Health Checks"

###
### Check systemd services for failures
### 
# Use systemctl's exit status to check for failed units more robustly.
FAILED_CNT=$(systemctl --failed --no-legend --no-pager | wc -l 2>/dev/null || true)
if [[ -z "$FAILED_CNT" || "$FAILED_CNT" -eq 0 ]]; then
        state="${aCOLOUR[2]}No Services Failed${COLOUR_RESET}"
else
        state="${aCOLOUR[3]}$FAILED_CNT Service(s) Failed${COLOUR_RESET}"
fi
print_state "Systemd Status" "$state"

###
### Check fail2ban IP count
###
# Count unique banned IPs via iptables/nftables compatibility. Try iptables first,
# fall back to nft if available.
COUNTIPS=0
if command -v iptables >/dev/null 2>&1; then
        COUNTIPS=$(iptables -L -n 2>/dev/null | awk '/REJECT/ {print $0}' | uniq -c | wc -l)
elif command -v nft >/dev/null 2>&1; then
        COUNTIPS=$(nft list ruleset 2>/dev/null | awk '/reject/ {print $0}' | uniq -c | wc -l)
fi
if [[ $COUNTIPS -eq 0 ]]; then
        state="${aCOLOUR[3]}No IP(s) Banned${COLOUR_RESET}"
else
        if [[ COUNTIPS -gt 20 ]]; then
                # RED
                state="${aCOLOUR[5]}$COUNTIPS IP(s) Banned${COLOUR_RESET}"
        else
                # generic color
                state="${aCOLOUR[2]}$COUNTIPS IP(s) Banned${COLOUR_RESET}"
        fi
fi
print_state "Fail2ban Status" "$state"
