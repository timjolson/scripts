#!/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin

set -o errexit
set -e
set -u

[[ ! -v debug ]] && debug=false 

if [[ ! -v logtofile ]]; then
	logtofile=false
	logdir="/dev/null"
else
	logdir="/var/log/$(basename ${0} | rev | cut -d'.' -f2- | rev).log"
fi


function log() {
        local message=""
        # Check if there is piped input
        if [ -p /dev/stdin ]; then
                # Read from stdin if there is any input
                read -r message || message=""  # Read from stdin, default to empty if read fails
        fi

        # If no piped input, check for the first argument
        if [[ -z "$message" && $# -gt 0 ]]; then
                #message="$*"
                message="$@"
                #message="$1"
        fi

        # If still no message
        if [[ -z "$message" ]]; then
                [[ "$debug" = true ]] && echo "Log message is blank. Called from line ${BASH_LINENO[0]}."
                return
        fi

        # log to journal
        echo "$message"

        if [ "$logtofile" = true ]; then
                # log to file with timestamp
                echo "$(date) : $message" >> "$logdir"
        fi
}

if [ "$logtofile" = true ]; then
	mkdir -p "$(dirname $logdir)" || { log "Error creating \"$(dirname $logdir)\"." && exit 1; }
	log "Logging to $logdir."
else
	log "File logging disabled. Logging to stdout only."
fi

# Function to parse named arguments dynamically. Usage:
# 
# Declare variables with default values
# declare -A DEFAULTS=(
#     ["arg1"]="default_arg1"
#     ["arg2"]="default_arg2"
#     ...
#     ["arg99"]="default_arg99"
# )
# 
# Call the function with the variable names and the main script's arguments
# parse_args DEFAULTS "$@"
# 
# The calling script's scope's variables have been set by the function.
# echo "Argument 1: $arg1"
# ...

# Default values
# declare -A DEFAULTS=(
#     ["src"]="default_src"
#     ["dest"]="default_dest"
#     ["exclude"]="default_exclude"
# )
parse_args() {
        local -n defaults_ref=$1  # Use nameref to refer to the passed associative array
        shift  # Shift to get to the actual arguments
    
        # Initialize variables with default values
        for key in "${!defaults_ref[@]}"; do
                [[ "$debug" = true ]] && log "defaults key : $key"
                eval "$key=\"${defaults_ref[$key]}\""
        done
    
        while [[ "$#" -gt 0 ]]; do
                case $1 in
                        --*)
                                key="${1:2}"  # Remove the leading '--'
                                if [[ -n "$key" ]]; then
                                        if [[ -z "${defaults_ref[$key]+x}" ]]; then
                                                log "Unknown parameter passed: $key"
                                                exit 2
                                        else
                                                eval "$key=\"$2\""
                                                [[ "$debug" = true ]] && log "assigning key:value pair $key: $2"
                                        fi
                                else
                                        log "Key is empty or unbound"
                                        exit 1
                                fi
                                shift
                                ;;
                        *) 
                                log "Invalid argument: $1"
                                exit 2
                                ;;
                esac
                shift
        done
}


