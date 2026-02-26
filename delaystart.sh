#!/bin/bash

# Check if at least one argument is provided
if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <delay_int_seconds> <wait_for_service_name> [<retry_delay_int_seconds {5 sec}>] [<retry_attempts (-1 is infinite) {3 attempts}>]"
    exit 1
fi

# Assign the first argument to DELAY and the second to WAITSERVICE if provided
DELAY="$1"
# Validate that DELAY is a non-negative integer
if [[ $DELAY =~ ^[0-9]+$ ]]; then
    DELAY=$DELAY
else
    echo "Error: <delay_in_seconds> must be a non-negative integer."
    exit 1
fi

WAITSERVICE="$2"
RETRYDELAY=${3:-5} # Default retry delay is 5 seconds if not provided
if [[ $RETRYDELAY =~ ^[0-9]+$ ]] && [ $RETRYDELAY != "0" ]; then
    RETRYDELAY=$RETRYDELAY
else
    echo "Error: <retry_delay_in_seconds> must be a positive integer."
    exit 1
fi

RETRYATTEMPTS=${4:-3} # Default to 3 retries if not provided
if [[ $RETRYATTEMPTS =~ ^[0-9]+$ ]] || [ $RETRYATTEMPTS -eq -1 ]; then
    RETRYATTEMPTS=$RETRYATTEMPTS
else
    echo "Error: <retry_attempts> must be a non-negative integer or -1 for infinite retries."
    exit 1
fi

command -v systemctl >/dev/null 2>&1 || { echo >&2 "This script requires systemctl but it's not installed. Aborting."; exit 1; }

while true; do
    # Get the current timestamp
    current_time=$(date +%s)

    # Check if the service is active
    if systemctl is-active --quiet "$WAITSERVICE"; then
        # If the service is active, get its uptime
        service_uptime=$(systemctl show -p ActiveEnterTimestamp "$WAITSERVICE" | sed "s/ActiveEnterTimestamp=//" | xargs -I {} date -d "{}" +%s)

        # Calculate the time since the service was started
        time_since_started=$((current_time - service_uptime))

        # Calculate sleep duration based on the service uptime
        sleep_duration=$((DELAY - time_since_started))

        # Sleep until the time_since_started should be acceptable, then check again
        if [ "$sleep_duration" -gt 0 ]; then
            echo "Waiting $sleep_duration seconds before checking again."
            sleep "$sleep_duration"
        # The service has been running for at least the specified delay
        elif [ "$sleep_duration" -le 0 ]; then
            # Display information about the service
            echo "Service '$WAITSERVICE' started $time_since_started seconds ago."
            exit 0
        fi
        break
    else
    # required service is not active, check again after a delay
        if [ $RETRYATTEMPTS -gt 0 ] || [ $RETRYATTEMPTS -eq -1 ]; then
            echo "Service '$WAITSERVICE' is not running. Checking again after $RETRYDELAY seconds..."
            if [ $RETRYATTEMPTS -ne -1 ]; then
                RETRYATTEMPTS=$((RETRYATTEMPTS - 1))
            fi
            sleep $RETRYDELAY
        else
            # If the service is still not active, exit
            echo "Service '$WAITSERVICE' is still not running after waiting. Exiting."
            exit 1
        fi
    fi
done # finish while loop

# this script should never reach this point, but if it does, exit with an error code
exit 2
