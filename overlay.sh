#!/bin/bash

# Script to combine branches into an in-place overlay, via mergerfs. Supports non-in-place overlays as well.
# For in-place overlays, creates temporary mounts of the destination, then mounts the merged directory on top of the destination.
#
# Note: this script forces "-f" so that it continues running for shutdown cleanup, and "flush-on-close=always" to help prevent data loss.
# Note: this is UNRELIABLE if "=" is in the path of any branch, as the script uses "=" to identify a specified write-mode
# assignment for each branch. TODO: improve the parsing logic to handle "=" in paths and recognize write-mode assignments more robustly.
# 
# Usage: overlay-in-place.sh <branches> <destinatino> <options formatted for mergerfs>
# Examples: 
#    overlay-in-place.sh "Video:Music" Documents
#    overlay-in-place.sh Pictures=NC:Video:Music "Pictures" -o fsname=in-place-overlay
#    overlay-in-place.sh Pictures=NC:"with space":Music Pictures
# 
# 
# https://github.com/trapexit/mergerfs/releases/download/2.41.1/mergerfs_2.41.1.debian-bookworm_amd64.deb


log() {
        local message=""
        # Check if there is piped input
        # Read from stdin, default to empty if read fails
        [ -p /dev/stdin ] && read -r message || message=""  
        # If no piped input, check for the first argument
        [[ -z "$message" && $# -gt 0 ]] && message="$@"
        # If there is a message to log, print it
        [[ ! -z "$message" ]] && echo "$message"
}

[ $# -ge 2 ] || { log "Usage $0 <branches> <destination> [<options for mergerfs>]"; exit 2; }

## Get parameters
# Incoming branches string, e.g. "Video:Music" or "Pictures=NC:Video:Music"
branches_in="$1"

# Resolve the real path of the destination and check if it is a directory.
dest="$2"
dest="${dest%%/}" # Remove trailing slash if any
real_dest=$(realpath "$dest") || { log "Failed to resolve real path of \"$dest\"."; exit 1; }
[[ ! -d "$real_dest" ]] && { log "Destination \"$dest\" does not exist or is not a directory."; exit 1; }
shift 2

# Get the remaining arguments for mergerfs, if any.
remaining_args=("$@")

## Prepare for in-place overlay handling.
# Initialize variables for in-place overlay handling
inplace=false
temp_dir=""
bind=""
merged=""

## Handle the target being a branch in the branches string.
# Split branches into array by ':'.
IFS=':' read -r -a branches_array <<< "$branches_in"
for i in "${!branches_array[@]}"; do
    # Remove trailing slash
    branches_array[$i]="${branches_array[$i]%%/}"
    # Split from the first '=' (write-mode)
    branch_base="${branches_array[$i]%%=*}"
    # Get the real path of the branch
    real_branch_base=$(realpath "$branch_base") || { log "Failed to resolve real path of branch \"$branch_base\"."; exit 1; }
    # Get the '=' (write-mode)
    suffix="${branches_array[$i]#${branch_base}}"

    # If the real path of the branch matches the real path of the destination, replace the branch with the bind mount 
    # and flag as an in-place overlay.
    if [[ "$real_branch_base" == "$real_dest" ]]; then
        if [[ -z "$temp_dir" ]]; then
            # Create temporary directories for bind mount and merged mount
            temp_dir=$(mktemp -d)
            bind="$temp_dir/bind-$dest"
            merged="$temp_dir/merged-$dest"
        fi
        branches_array[$i]="$bind$suffix"
        inplace=true
    fi
done

## Create branches string for mergerfs call
if [[ "$inplace" = true ]]; then
    # concatenate branches back into a string for mergerfs
    branches="$(IFS=:; echo "${branches_array[*]}")"
    branch_msg=" Branches resolved to \"$branches\"."
    mergerfs_path="$merged"
else
    # standard mergerfs mount
    branches="$branches_in"
    branch_msg=""
    mergerfs_path="$dest"
fi

# Log the configuration
log "Overlaying \"$dest\" with \"$branches_in\".$branch_msg"
[[ -z "$remaining_args" ]] || log "Options for mergerfs: ${remaining_args[*]}"

## Set up traps to ensure cleanup on exit or interruption, applies to the remainder of the script.
cleanup() {
    # Cleanup temporary directories and mounts on exit
    [[ -d "$mergerfs_path" ]] && $( umount "$mergerfs_path" || fusermount -u "$mergerfs_path" ) | log

    if [[ "$inplace" = true ]]; then
        # Unmount the bind mount and merged mount, and remove the temporary directory.
        [[ -d "$dest" ]] && $( umount "$dest" || fusermount -u "$dest") | log
        [[ ( ! -z "$bind" ) && -d "$bind" ]] && $( umount "$bind" || fusermount -u "$bind" ) | log
        [[ ( ! -z "$temp_dir" ) && -d "$temp_dir" ]] && rm -rdf "$temp_dir" | log
    fi
    exit $1
}
trap 'cleanup' SIGINT SIGTERM

## Prepare for in-place overlay handling.
if [[ "$inplace" = true ]]; then
    # Create the bind directory (as a layer of obfuscation to prevent mergerfs from treating the original destination as a branch).
    [ -d "$bind" ] || { mkdir -p "$bind"; } || { log "Failed to create bind directory \"$bind\"."; cleanup 1; }
    mount --bind "${dest}" "${bind}" || { log "Failed to bind mount \"$dest\" to \"$bind\"."; cleanup 1; }

    # Make the bind mount private to prevent propagation of mounts/unmounts to the original destination. This prevents
    # mergerfs from failing due to a branch being the destination.
    mount --make-private "${bind}" || { log "Failed to make \"$bind\" private."; cleanup 1; }

    # Create the merged directory for the mergerfs mount.
    [ -d "$merged" ] || { mkdir -p "$merged"; } || { log "Failed to create merged directory \"$merged\"."; cleanup 1; }
fi

# Do the mergerfs mount. mergerfs_path depends on whether this is an in-place overlay or not.
/usr/bin/mergerfs \
    -f \
    "${branches}" \
    "${mergerfs_path}" \
    -o flush-on-close=always \
    "${remaining_args[@]}" 2>&1 | log &
mergerfs_pid=$!

# If the overlay is in-place, mount the merged directory on top of the original destination.
if [[ "$inplace" = true ]]; then
    mount --bind "${merged}" "${dest}" || { log "Failed to bind mount back to \"$dest\"."; cleanup 1; }
fi

log "Mounted overlay at \"$dest\"."
wait $mergerfs_pid

cleanup 0
