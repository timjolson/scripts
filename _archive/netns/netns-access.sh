#!/bin/bash
# netns-access.sh: Manage a Linux network namespace, move an interface into it, and configure networking.

logtofile=false

# Source logging and utility functions
source "$(dirname "${BASH_SOURCE[0]}")/functions.sh"

# Default values for arguments (can be overridden by CLI)
declare -A DEFAULTS=(
    ["nameservers"]="76.76.2.0, 76.76.10.0"   # Default DNS servers for the namespace
    ["interface"]="eth0"                      # Default interface to move into the namespace
    ["ip_method"]="dhcp"                      # Default IP assignment method (dhcp or static)
    ["enable_forwarding"]=false                # Enable IPv4 forwarding by default?
    ["namespace"]="vpnNS"                     # Default namespace name
    ["hostip"]="10.9.8.99"                    # Default veth IP on the host side
    ["nsip"]="10.9.8.98"                      # Default veth IP on the namespace side
)

command=$1
# Require at least one argument after the command
[ $# -ge 2 ] || { log "Usage $0 <start|stop> [--namespace <ns name>] [--interface <interface name>] [--ip_method <dhcp|a static ip>] [--nameservers <nameservers>] [--enable_forwarding <true|false>]  [--hostip <system ip addr>] [--nsip <ns ip address>]"; exit 2; }
parse_args DEFAULTS "${@:2}"

# Ensure namespace is set
if [ -z "$namespace" ]; then
    log "Error: --namespace is required."
    exit 2
fi

# Ensure required commands are available
command -v /usr/sbin/ip >/dev/null 2>&1 || { log "ip command not found"; exit 127; }
command -v /usr/sbin/dhclient >/dev/null 2>&1 || { log "dhclient command not found"; exit 127; }

# --- START: Set up namespace and move interface ---
if [ "$command" = "start" ]; then
        log "Creating \"$namespace\" local network ..."

        # Validate required arguments for setup
        if [ -z "$hostip" ]; then
                log "Error: --hostip is required."
                exit 2
        fi
        if [ -z "$nsip" ]; then
                log "Error: --nsip is required."
                exit 2
        fi
        if [ -z "$interface" ]; then
                log "Error: --interface is required."
                exit 2
        fi
        if [ -z "$nameservers" ]; then
                log "Error: --nameservers is required."
                exit 2
        fi
        if [ -z "$enable_forwarding" ]; then
                log "Error: --enable_forwarding is required."
                exit 2
        fi
        if [ -z "$ip_method" ]; then
                log "Error: --ip_method is required."
                exit 2
        fi

        # --- Nameserver configuration ---
        log "Setting up nameservers for \"$interface\" \"$nameservers\" ..."
        mkdir -p "/etc/netns/$namespace"   # Namespace-specific resolv.conf dir
        touch "/etc/netns/$namespace/resolv.conf"

        ## nameservers are overridden in /etc/dhcp/dhclient.conf for eth0 only, as shown below
        #
        # interface "eth0" {
        #    supersede domain-name-servers 76.76.10.2, 10.10.76.2;
        # }

        # Prepare a new interface section for dhclient.conf to override DNS for this interface
        NEW_INTERFACE_SECTION="interface \"$interface\" { supersede domain-name-servers $nameservers; }"
        DHCLIENT_CONF="/etc/dhcp/dhclient.conf"
        BACKUP_DHCLIENT="${DHCLIENT_CONF}.bak"
        cp "$DHCLIENT_CONF" "$BACKUP_DHCLIENT" || { log "Failed to backup $DHCLIENT_CONF to $BACKUP_DHCLIENT"; exit 1; }
        temp_file=$(mktemp /tmp/$interface.dhclient.XXXXX.conf)

        log "Checking interface section in \"$DHCLIENT_CONF\""
        # If interface section exists, replace it; otherwise, append
        if grep -q "interface \"$interface\"" "$DHCLIENT_CONF"; then
                sed "/interface \"$interface\" {/,/}/d" "$DHCLIENT_CONF" > "$temp_file"
                echo -e "$NEW_INTERFACE_SECTION" >> "$temp_file"
                cat "$temp_file" > "$DHCLIENT_CONF"
                log "Updated interface section for \"$interface\" in $DHCLIENT_CONF."
                trap '[[ -f "$temp_file" ]] && rm "$temp_file"' EXIT
        else
                echo -e "\n$NEW_INTERFACE_SECTION" >> "$DHCLIENT_CONF"
                log "Added new interface section for \"$interface\" in $DHCLIENT_CONF."
        fi
        trap '[[ -f "$BACKUP_DHCLIENT" ]] && rm "$BACKUP_DHCLIENT"' EXIT

        log "Setting up network namespace \"$namespace\" ..."

        # Move the specified interface into the namespace
        /usr/sbin/ip link set "$interface" netns "$namespace" || { log "Failed to move interface \"$interface\" to namespace \"$namespace\""; exit 1; }

        # Bring up the interface inside the namespace
        /usr/sbin/ip netns exec "$namespace" /usr/sbin/ip link set dev "$interface" up || { log "Failed to bring up interface \"$interface\" in namespace \"$namespace\""; exit 1; }

        # Disable IPv6 on the interface inside the namespace
        /usr/sbin/ip netns exec "$namespace" /usr/sbin/sysctl -w net.ipv6.conf.$interface.disable_ipv6=1 || { log "Failed to disable IPv6 on \"$interface\""; exit 1; }

        # Enable or disable IPv4 forwarding globally
        if [ "$enable_forwarding" = true ]; then
                /usr/sbin/sysctl -w net.ipv4.ip_forward=1
                log "IPv4 forwarding enabled."
        else
                /usr/sbin/sysctl -w net.ipv4.ip_forward=0
                log "IPv4 forwarding disabled."
        fi

        # Assign IP address (static or DHCP) to the interface in the namespace
        if [[ "$ip_method" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                # Static IP assignment
                /usr/sbin/ip netns exec "$namespace" /usr/sbin/ip addr add "$ip_method" dev "$interface"
                log "Assigned static IP $ip_method to interface \"$interface\" in namespace \"$namespace\"."
        else
                # DHCP assignment
                if [ "$ip_method" = "dhcp" ]; then
                        log "Running dhclient on interface \"$interface\" in namespace \"$namespace\" ."
                        output=$(/usr/sbin/ip netns exec "$namespace" /usr/sbin/dhclient -4 "$interface" 2>&1)
                else
                        log "IP method '$ip_method' is not supported. Please use a valid IP address or 'dhcp'."
                        exit 2
            fi
        fi

        ## get IP addr after DHCP (works)
        # ExecStart=-sh -c "echo $(/usr/bin/env ip netns exec %i /usr/bin/env ip route | /usr/bin/env grep 'src' | /usr/bin/env awk '{print $NF}')/24"
        # ExecStart=-sh -c "echo 'nameserver' $(/usr/bin/env ip route | /usr/bin/env grep 'src' | /usr/bin/env awk '/src/ {print $NF}') > /etc/netns/%I/resolv.conf"

        ## use gateway from default namespace as DNS
        #/usr/sbin/ip route | /usr/bin/env grep 'default' | /usr/bin/env awk '/default/ {print $3}' | log

        ## set IP same as DHCP (does not work, Operation not permitted)
        # ExecStart=-/usr/bin/env ip netns exec %i ip addr add "$(/usr/bin/env ip netns exec %i /usr/bin/env ip route | /usr/bin/env grep 'src' | /usr/bin/env awk '{print $NF}')/24" dev eth0

        ## add route to secondary network interface
        # ETH1ADDR=/usr/sbin/ip -4 addr show eth1 | grep -oP '(?<=inet\s)\d+(\.\d+){3}'
        # GW=/usr/sbin/ip route | grep default | awk '{print $3}'
        # /usr/sbin/ip netns exec "$namespace" /usr/sbin/ip route add $ETH1ADDR/32 via $GW

        # 1. Create a veth pair to connect the default and target namespaces
        /usr/sbin/ip link add veth_def_$namespace type veth peer name veth_$namespace
        /usr/sbin/ip link set veth_$namespace netns $namespace
        log "Made \"veth_$namespace\" and moved into \"$namespace\""

        # 2. Assign IP to veth in default namespace
        /usr/sbin/ip addr add $hostip/32 dev veth_def_$namespace
        log "Assigned $hostip to \"veth_def_$namespace\""
        # 3. Assign IP to veth in netns
        /usr/sbin/ip netns exec "$namespace" /usr/sbin/ip addr add $nsip/32 dev veth_$namespace
        log "Assigned $nsip to \"veth_$namespace\""

        # 4. Bring up both ends of veth
        /usr/sbin/ip link set veth_def_$namespace up
        /usr/sbin/ip netns exec "$namespace" /usr/sbin/ip link set veth_$namespace up
        log "Activated both ends of veth for \"$namespace\""

        # 5. Add routes for communication between namespaces
        /usr/sbin/ip route add $nsip/32 dev veth_def_$namespace src $hostip
        /usr/sbin/ip netns exec "$namespace" /usr/sbin/ip route add $hostip/32 dev veth_$namespace src $nsip
        log "Added route in and out of \"$namespace\" on \"veth_$namespace\""

        log "... Finished starting \"$namespace\" local network."
        
elif [ "$command" = "stop" ]; then
        log "Stopping \"$namespace\" local network ..."
        
        # Check if the namespace exists
        if ! /usr/sbin/ip netns list | grep -qw "$namespace"; then
                log "Namespace $namespace does not exist."
                exit 1
        fi
        
        ipstring=$(/usr/bin/env ip netns exec $namespace /usr/bin/env ip route | grep -oP '\d+(\.\d+){3}( dev veth_.*)')
        if [ -z "$ipstring" ]; then
                log "No grep results in \"$namespace\" for local network connections"
                exit 1
        fi
        # log "ipstring: $ipstring"
        
        log "Retrieving ip(s)"
        hostip=$(echo $ipstring | grep -oP '^\d+(\.\d+){3}')
        hostipcidr=$(echo $hostip | grep -oP '\d+(\.\d+){2}' | sed 's/$/.0/')
        # log "host ip cidr $hostipcidr"
        nsip=$(echo $ipstring | grep -oP '\s\K\d+(\.\d+){3}')
        nsipcidr=$(echo $nsip | grep -oP '\d+(\.\d+){2}' | sed 's/$/.0/')
        # log "ns ip cidr $nsipcidr"
        log "Retrieved host ip $hostip and ns ip $nsip"
        
        # 5. Remove routes for veth pair
        log "Removing local route to \"$namespace\""
        (/usr/sbin/ip route del $nsip dev veth_def_$namespace src $hostip) || { log "Failed to delete local route to \"$namespace\""; exit 1; }
        log "Removing local route from \"$namespace\""
        (/usr/sbin/ip netns exec $namespace /usr/sbin/ip route del $hostip dev veth_$namespace src $nsip) || { log "Failed to delete local route from \"$namespace\""; exit 1; }

        # 4. Take down veth, not needed (handled by deletion)
        # 3. Un-assign IP, not needed
        # 2. Un-assign IP, not needed

        # 1. Delete virtual eth
        log "Deleting link \"veth_def_$namespace\""
        (/usr/sbin/ip link delete veth_def_$namespace) || { log "Failed to delete link for \"$namespace\""; exit 1; }

        log "Gathering interfaces in namespace: $namespace"

        # Check if the namespace exists
        if ! /usr/sbin/ip netns list | grep -qw "$namespace"; then
                log "Namespace $namespace does not exist."
        exit 1
        fi

        # Execute the command and capture any errors
        links=$( /usr/sbin/ip netns exec "$namespace" /usr/sbin/ip link show 2>&1 )
        if [ $? -ne 0 ]; then
                log "Error executing ip link command: $links"
                exit 1
        fi
        # log "Links: $links"

        # Use awk to filter interfaces that are UP and not loopback or virtual
        interfaces=$(echo "$links" | awk -F ': ' '/^[0-9]+:/{if ($2 !~ /lo|veth|br-|tap|docker|virbr/) print $2}')

        # Log the interfaces found and move them back to the default namespace
        log "Interfaces found: $interfaces"
        for interface in $interfaces; do
                # Move interface back to the default namespace
                /usr/sbin/ip netns exec "$namespace" /usr/sbin/ip link set "$interface" netns 1 || { log "Failed to move interface \"$interface\" to default namespace"; exit 1; }
                log "Moved interface \"$interface\" to the default namespace"
        done
        log "... Finished stopping \"$namespace\" local network."
fi

exit 0
