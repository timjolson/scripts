#!/bin/bash
logtofile=false
source "$(dirname "${BASH_SOURCE[0]}")/functions.sh"

# Check if at least one parameter is provided
if [ "$#" -lt 1 ]; then
  echo "Usage: $0 <service1> <service2> ..."
  exit 1
fi

# Loop through each parameter
for service in "$@"; do
  # Check if the service is enabled
  if systemctl is-enabled "$service" > /dev/null 2>&1; then
    log "Starting $service..."
    systemctl start "$service"
  else
    log "$service is not enabled and cannot be started."
  fi
done
