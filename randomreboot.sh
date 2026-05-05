#!/bin/bash
logtofile=true
dryrun=false

# log file to read for previously scheduled reboot
LOG_FILE="/var/log/syslog"

source "$(dirname "${BASH_SOURCE[0]}")/functions.sh"

NUMARGS=2
if [ $# != $NUMARGS ]; then
	log "Incorrect number of arguments ( $# instead of $NUMARGS ). Usage: $0 <max days to delay> <max seconds to offset the reboot>."
	exit 2
fi

days=$1
seconds=$2


# Search for shutdown and reboot messages, extract the latest message's schedule
log_message=$(grep -E '(Reboot|Shutdown) scheduled for' "$LOG_FILE" | sort -r | head -n1)


schedule=false
# Extract the scheduled time using a regex
if [[ $log_message =~ (Reboot|Shutdown)\ scheduled\ for\ ([A-Za-z]{3}\ [0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}\ [A-Z]{3}) ]]; then
    scheduled_time="${BASH_REMATCH[2]}"

	# Convert the scheduled time to a timestamp
	scheduled_timestamp=$(date -d "$scheduled_time" +%s)
	log "scheduled" $scheduled_timestamp

	# Get the current time as a timestamp
	current_timestamp=$(date +%s)
	log "current" $current_timestamp

	# Calculate the upper limit for the scheduled time
	upper_limit=$((current_timestamp + 86400*$days + seconds))
	log "limit" $upper_limit

	# Check if the scheduled time is within the time window
	if (( scheduled_timestamp > current_timestamp && scheduled_timestamp <= upper_limit )); then
		log "A reboot is already scheduled within the target timeframe."
		schedule=false
		exit 0
	elif (( scheduled_timestamp > current_timestamp )); then
		log "A reboot is scheduled outside of the target timeframe. Scheduling a new reboot."
		schedule=true
	fi
else
        log "No scheduled time found in the log message."
        schedule=true
fi


# if [[ "$schedule" == false ]]; then
# 	exit 0
# fi

if [[ 0 -eq $days ]]
then
	DAYSOFFSET=0
else
	DAYSOFFSET=$(($RANDOM % ( days + 1 )))
fi
log "Days to offset = $DAYSOFFSET"


if [[ 0 -eq $seconds ]]
then
	OFFSET=0
else
	OFFSET=$(($RANDOM % seconds))
fi
log "Seconds to offset = $OFFSET"


REBOOTDELAY=$(((86400 * $DAYSOFFSET) + $OFFSET))
log "Reboot delay (sec) : $REBOOTDELAY"

REBOOTMINUTES=$((REBOOTDELAY / 60))
[[ "$dryrun" == false ]] && /usr/sbin/shutdown -r +$REBOOTMINUTES

message_adjust=""
if [[ "$dryrun" == true ]]; then
	message_adjust="<<Pretend>> "
fi
REBOOTDATE=$(date -d "+${REBOOTDELAY} seconds" +"%Y-%m-%d %H:%M:%S")
log "${message_adjust}Reboot scheduled for $(date -d "$REBOOTDATE" +'%a %Y-%m-%d %H:%M %Z'), use 'shutdown -c' to cancel."

exit 0
