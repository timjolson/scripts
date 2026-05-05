#!/bin/bash
# This script forwards a TCP port from the host into a network namespace using socat.
# Usage: netns-port.sh namespace@port

logtofile=false

# Source logging and utility functions
source "$(dirname "${BASH_SOURCE[0]}")/functions.sh"

command=$1
# Check argument count (should be exactly 1: namespace@port)
[ $# -ne 2 ] || { log "Usage $0 namespace@port"; exit 2; }
parse_args DEFAULTS "${@:2}"

# Parse namespace and port from argument
INSTANCE="$1"
namespace="${INSTANCE%@*}"
port="${INSTANCE#*@}"

# Validate namespace
if [ -z "$namespace" ]; then
    log "Error: namespace is required."
    exit 2
fi
# Ensure namespace contains only allowed characters
if ! [[ "$namespace" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    log "Error: namespace must contain only alphanumeric characters, dashes, or underscores."
    exit 2
fi

# Wait for the namespace to exist (try up to 5 times)
i=0
while ((i++ < 5)); do
    if ! /usr/sbin/ip netns list | grep -qw "$namespace"; then
        log "Namespace $namespace does not exist."
        sleep 1;
    else
        break
    fi
done

# If namespace still doesn't exist, exit with error
if ((i > 5)); then
    log "Namespace $namespace does not exist after multiple checks."
    exit 1
fi

# Validate port
if [ -z "$port" ]; then
    log "Error: port is required."
    exit 2
fi
# Ensure port is a positive integer
if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -le 0 ]; then
    log "Error: port must be a positive integer."
    exit 2
fi

# Ensure socat is available
command -v /usr/bin/socat >/dev/null 2>&1 || { log "socat command not found"; exit 127; }

log "Starting port forwarding for namespace '$namespace' on port $port"

# Forward TCP port from host to the same port in the namespace using socat
/usr/bin/socat tcp-listen:"$port",fork exec:"ip netns exec $namespace socat STDIO \"tcp-connect:127.0.0.1:$port\"",nofork

log "Ended port forwarding for namespace '$namespace' on port $port"

exit 0
