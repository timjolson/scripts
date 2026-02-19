#!/bin/bash

# Check if at least one argument is provided
if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <delay_in_seconds> [<service_name>]"
    exit 1
fi

# Assign the first argument to DELAY and the second to WAITSERVICE if provided
DELAY=$1
WAITSERVICE=$2

# Get the current timestamp
current_time=$(date +%s)

# If a service name is provided, get its uptime
if [ -n "$WAITSERVICE" ]; then
    checked_once=false
    
    while true; do
        # Check if the service is active
        if systemctl is-active --quiet "$WAITSERVICE"; then
                # If the service is active, get its uptime
                service_uptime=$(systemctl show -p ActiveEnterTimestamp "$WAITSERVICE" | sed "s/ActiveEnterTimestamp=//" | xargs -I {} date -d "{}" +%s)

                # Calculate the time since the service was started
                time_since_started=$((current_time - service_uptime))
    
                # Calculate sleep duration based on the service uptime
                sleep_duration=$((DELAY - time_since_started))

                # Display information about the service
                echo "Service '$WAITSERVICE' started $time_since_started seconds ago at $(date -d "@$service_uptime")"
                break
        else
                if [ "$checked_once" = false ]; then
                        # Wait for 5 seconds on the first check
                        echo "Service '$WAITSERVICE' is not running. Checking again after a 5 second delay..."
                        sleep 5
                        checked_once=true
                else
                        # If the service is still not active, exit
                        echo "Service '$WAITSERVICE' is still not running after waiting. Exiting."
                        exit 1
                fi
        fi
    done # finish while loop
else
    # No service name provided, sleep for the specified delay
    sleep_duration=$DELAY
fi

# Ensure we don't sleep for a negative duration
if [ "$sleep_duration" -gt 0 ]; then
    echo "Waiting $sleep_duration seconds before starting."
    sleep "$sleep_duration"
fi
