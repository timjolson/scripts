#!/bin/bash

# Script to combine, via mergerfs overlay, branches into an existing destination directory.
# Creates a temporary bind mount of the original destination, then mounts the merged directory on top of the original destination.
#
# Usage: overlay-in-place.sh <destination dir> <branches str> <foreground bool> [<option1> <option2> ...]
# Examples: 
#    overlay-in-place.sh /mnt/overlay "/mnt/overlay:drive2"
#    overlay-in-place.sh /mnt/overlay "/mnt/overlay=NC:drive2" true
# 
# https://github.com/trapexit/mergerfs/releases/download/2.41.1/mergerfs_2.41.1.debian-bookworm_amd64.deb


log() {
        local message=""
        # Check if there is piped input
        if [ -p /dev/stdin ]; then
                # Read from stdin if there is any input
                read -r message || message=""  # Read from stdin, default to empty if read fails
        fi
        # If no piped input, check for the first argument
        if [[ -z "$message" && $# -gt 0 ]]; then
                message="$@"
        fi
        # If still no message
        if [[ -z "$message" ]]; then
                return
        fi
        # log to journal
        echo "$message"
}

[ $# -ge 2 ] || { log "Usage $0 <destination dir> <branches str> <foreground bool> [<option1> <option2> ...]"; exit 2; }


dest="$1"
dest="${dest%%/}" # remove trailing slash if present
branches="$2"

# Check if there's a third argument for foreground option
if [[ $# -ge 3 && "$3" != "true" && "$3" != "false" ]]; then
    # third arg is not a bool
    foreground=false
    shift 2
elif [[ $# -ge 3 ]]; then
    # third arg is a bool
    foreground="$3"
    shift 3
else
    # no third arg, default to false
    foreground=false
    shift 2
fi

# Remaining arguments are options for mergerfs
options=("$@")

# output a summary of the configuration
log "Overlaying \"$dest\" with \"$branches\"."
log "Options: ${options[*]}"

# combine options into an array of -o options for mergerfs
mergerfs_opts=()
for opt in "${options[@]}"; do
    mergerfs_opts+=("-o $opt")
done

# foreground flag for mergerfs
if [[ "$foreground" == "true" ]]; then
    fg_flag="-f"
else
    fg_flag=""
fi

# create temporary directories for bind mount and merged mount
temp_dir=$(mktemp -d .XXXXXXXXXXXX)
bind="$temp_dir/bind-$dest"
merged="$temp_dir/merged-$dest"

## Handle the destination being a branch in the branches string.
# Split branches into array by ':'.
IFS=':' read -r -a branches_array <<< "$branches"
for i in "${!branches_array[@]}"; do
    # Remove trailing slash if present, then split into branch_base and suffix by the first '=' character.
    branches_array[$i]="${branches_array[$i]%%/}"
    branch_base="${branches_array[$i]%%=*}"
    suffix="${branches_array[$i]#${branch_base}}"
    if [[ "$branch_base" == "$dest" ]]; then
        branches_array[$i]="$bind$suffix"
    fi
done
# Combine branches_array into a string delimited by ':'
branches_combined="$(IFS=:; echo "${branches_array[*]}")"
log "branches_combined = \"$branches_combined\""

# cleanup temporary directories and mounts on exit
cleanup() {
    fusermount -u "$dest" | log
    fusermount -u "$bind" | log
    fusermount -u "$merged" | log
    umount "$dest" | log
    umount "$bind" | log
    umount "$merged" | log
    rm -rdf "$temp_dir" | log
}
mergerfs_pid=""
trap 'cleanup $mergerfs_pid' SIGINT SIGTERM EXIT

read -p "Make bind and merged directories?..."
[ -d "$bind" ] || { log "Bind directory \"$bind\" does not exist. Creating it."; mkdir -p "$bind"; } || { log "Failed to create bind directory \"$bind\"."; exit 1; }
[ -d "$merged" ] || { log "Merged directory \"$merged\" does not exist. Creating it."; mkdir -p "$merged"; } || { log "Failed to create merged directory \"$merged\"."; exit 1; }

# bind mount the original destination directory to the temprary bind directory
read -p "Bind mount \"$dest\" to \"$bind\"?..."
mount --bind "${dest}" "${bind}" || { log "Failed to bind mount \"$dest\" to \"$bind\"."; exit 1; }
log "Make \"$bind\" private?..."
mount --make-private "${bind}" || { log "Failed to make \"$bind\" private."; exit 1; }

# use mergerfs to overlay the source and bind directories on top of the original destination directory
read -p "Mount the merge to \"$merged\"?..."
/usr/bin/mergerfs \
    $fg_flag \
    "${mergerfs_opts[@]}" \
    "${branches_combined}" \
    "${merged}" 2>&1 | log &
mergerfs_pid=$!

log "Mount overlay of \"$merged\" back to \"$dest\"?..."
mount --bind "${merged}" "${dest}" || { log "Failed to bind mount back to \"$dest\"."; exit 1; }
log "Mounted merge at \"$dest\"."

read -p "Press Enter to unmount and exit..."
cleanup "$mergerfs_pid"

