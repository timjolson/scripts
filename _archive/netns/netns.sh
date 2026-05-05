#!/bin/bash
# This script manages Linux network namespaces: it can create (start) or delete (stop) a namespace.
# It also sets up or tears down the loopback interface and cleans up resources.

logtofile=false

# Source logging and utility functions
source "$(dirname "${BASH_SOURCE[0]}")/functions.sh"

# Check argument count (should be exactly 2: <start|stop> <namespace>)
[ $# -ne 3 ] || { log "Usage $0 <start|stop> namespace"; exit 2; }
cmd="$1"
# Validate command
if [[ ! "$cmd" =~ ^(start|stop)$ ]]; then
    log "Invalid command: $cmd. Use 'start' or 'stop'."
    exit 2
fi

# Get namespace name
namespace="$2"
[ -n "$namespace" ] || { log "Usage $0 <start|stop> namespace"; exit 2; }

# Ensure required commands are available
command -v /usr/sbin/ip >/dev/null 2>&1 || { log "ip command not found"; exit 127; }
command -v /usr/bin/env >/dev/null 2>&1 || { log "env command not found"; exit 127; }

if [ "$cmd" = "start" ]; then
    log "Starting network namespace '$namespace'"

    # Create new namespace (ignore error if it already exists)
    /usr/bin/env ip netns add $namespace 2>&1 || true
    # Bring up loopback interface inside the namespace
    /usr/bin/env ip netns exec $namespace ip link set lo up
    # Bind mount the namespace for easier access
    /usr/bin/env mount --bind /proc/self/ns/net /var/run/netns/$namespace
    log "Started network namespace '$namespace'"
elif [ "$cmd" = "stop" ]; then
    # Clean up namespace resources if they exist
    log "Stopping network namespace '$namespace'"
    # Bring down loopback interface
    /usr/bin/env ip netns exec $namespace ip link set lo down
    # Delete the namespace (try twice, ignore errors)
    /usr/bin/env ip netns delete $namespace >/dev/null 2>&1 || /usr/bin/env ip netns delete $namespace 2>&1 || { log "failed to delete namespace \"$namespace\""; }
    # Remove the bind mount (commented out, can be enabled if needed)
    # /usr/bin/env umount /var/run/netns/$namespace >/dev/null 2>&1 || { log "failed to umount \"/var/run/netns/$namespace\""; }
    # Remove namespace file
    rm -rdf /var/run/netns/$namespace

    log "Stopped network namespace '$namespace'"
else
    log "Invalid command: $cmd. Use 'start' or 'stop'."
    exit 2
fi

exit 0
