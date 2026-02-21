#!/bin/bash

# Script to combine, via mergerfs overlay, branches into an existing destination directory.
# Creates a temporary bind mount of the original destination, then mounts the merged directory on top of the original destination.
#
# Note: this is UNRELIABLE if "=" is in the path of any branch, as the script uses "=" to identify a specified write-mode
# assignment for each branch.
# 
# Usage: overlay-in-place.sh <destination dir> <branches str> <options formatted for mergerfs>
# Examples: 
#    overlay-in-place.sh /mnt/overlay "/mnt/overlay:drive2"
#    overlay-in-place.sh "Documents" "Video:Music"
#    overlay-in-place.sh "Pictures" "Pictures=NC:Video:Music" -o fsname=in-place-overlay
# 
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

[ $# -ge 2 ] || { log "Usage $0 <destination dir> <branches str> <options for mergerfs>"; exit 2; }


dest="$1"
dest="${dest%%/}" # remove trailing slash if present
branches_str="$2"
shift 2

remaining_args=("$@")

# output a summary of the configuration
log "Overlaying \"$dest\" with \"$branches_str\"."
log "Remaining mergerfs args: ${remaining_args[*]}"

# create temporary directories for bind mount and merged mount
temp_dir=$(mktemp -d .XXXXXXXXXXXX)
bind="$temp_dir/bind-$dest"
merged="$temp_dir/merged-$dest"

## Handle the destination being a branch in the branches string.
# Split branches into array by ':'.
IFS=':' read -r -a branches_array <<< "$branches_str"
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
branches="$(IFS=:; echo "${branches_array[*]}")"
log "branches = \"$branches\""

# cleanup temporary directories and mounts on exit
cleanup() {
    fusermount -u "$dest" | log
    fusermount -u "$merged" | log
    fusermount -u "$bind" | log
    umount "$dest" | log
    umount "$merged" | log
    umount "$bind" | log
    rm -rdf "$temp_dir" | log
}
trap 'cleanup' SIGINT SIGTERM EXIT

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
    "${branches}" \
    "${merged}" \
    "${remaining_args[@]}" 2>&1 | log &
mergerfs_pid=$!

log "Mount overlay of \"$merged\" back to \"$dest\"?..."
mount --bind "${merged}" "${dest}" || { log "Failed to bind mount back to \"$dest\"."; exit 1; }
log "Mounted merge at \"$dest\"."

read -p "Press Enter to unmount and exit..."
cleanup

exit 0
