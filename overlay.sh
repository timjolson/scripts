#!/bin/bash

# Script to combine branches into an in-place overlay, via mergerfs. Supports non-in-place overlays as well.
# For in-place overlays, creates temporary mounts of the destination, then mounts the merged directory on top of the destination.
#
# Note: this script forces "-f" so that it continues running for shutdown cleanup, and "flush-on-close=always" to help prevent data loss.
# Note: the script detects "=RW", "=RO", or "=NC" suffixes for branches to support write-mode assignments. Branch paths that end with 
# any of these suffixes in their name will not be processed correctly. mergerfs would have this problem, as well.
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

# Use dynamic lookup for mergerfs binary
mergerfs_bin=$(command -v mergerfs) || { log "mergerfs not found in PATH."; exit 1; }

[ $# -ge 2 ] || { log "Usage $0 <branches> <destination> [<options for mergerfs>]"; exit 2; }

## Get parameters
# Incoming branches string, e.g. "Video:Music" or "Pictures=NC:Video:Music"
branches_in="$1"

# Resolve the real path of the destination and check if it is a directory.
dest="$2"
dest="${dest%%/}" # Remove trailing slash if any
real_dest=$(realpath "$dest") || { log "Failed to resolve real path of \"$dest\"."; exit 1; }
[[ -d "$real_dest" || ! -e "$real_dest" ]] || { log "Destination \"$dest\" exists and is not a directory."; exit 1; }
shift 2

# Get the remaining arguments for mergerfs, if any.
remaining_args=("$@")

## Prepare for in-place overlay handling.
# Initialize variables for in-place overlay handling
inplace=false
temp_dir=""
bind=""
merged=""
made_dest=false

## Handle the target being a branch in the branches string.
# Save the original IFS value
original_ifs="$IFS"

# Split branches into array by ':'
IFS=':' read -r -a branches_array <<< "$branches_in"

# Restore the original IFS value
IFS="$original_ifs"

for i in "${!branches_array[@]}"; do
    # Detect only a trailing write-mode token (=NC, =RO, =RW) at the end of the branch
    branch_entry="${branches_array[$i]}"
    suffix=""
    if [[ "$branch_entry" =~ ^(.*)(=NC|=RO|=RW)$ ]]; then
        branch_base="${BASH_REMATCH[1]}"
        suffix="${BASH_REMATCH[2]}"
    else
        branch_base="$branch_entry"
    fi
    # Get the real path of the branch
    real_branch_base=$(realpath "$branch_base") || { log "Failed to resolve real path of branch \"$branch_base\"."; exit 1; }

    # If the real path of the branch matches the real path of the destination, replace the branch with the bind mount 
    # and flag as an in-place overlay.
    if [[ "$real_branch_base" == "$real_dest" ]]; then
        if [[ -z "$temp_dir" ]]; then
            # Create temporary directories for bind mount and merged mount
            temp_dir=$(mktemp -d) || { log "Failed to create temporary directory."; exit 1; }
            # Derive a safe base name from the destination while preserving parent path components
            tmp_base="${real_dest#/}"
            tmp_base="${tmp_base//\//_}"
            safe_base=$(printf '%s' "$tmp_base" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')
            bind="$temp_dir/bind-$safe_base"
            merged="$temp_dir/merged-$safe_base"
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
if [[ ${#remaining_args[@]} -gt 0 ]]; then
    log "Options for mergerfs: ${remaining_args[*]}"
fi

## Set up traps to ensure cleanup on exit or interruption, applies to the remainder of the script.
cleanup() {
    # # Function to cleanup temporary directories and mounts on exit

    # status of last command before trap was triggered
    trap_status=$?
    # SIGINT = 2, SIGTERM = 15, SIGHUP = 1
    # SIGKILL = 9, SIGSTOP = 19 (cannot be caught or ignored)

    # if the function was called and not triggered, use the provided exit code argument or default to 0
    if [[ $trap_status -ne 0 ]]; then
        exit_code=$trap_status
    else
        exit_code=${1:-0}
    fi
    
    # # mergerfs_path should never be mounted at this point
    # [[ -d "$mergerfs_path" ]] && ( umount "$mergerfs_path" || fusermount -u "$mergerfs_path" ) | log

    if [[ "$inplace" = true ]]; then
        # Unmount the bind mount and merged mount, and remove the temporary directory.

        # If the destination mount was umounted, we get a SIGHUP (1). In that case, we do not need to umount the destination again.
        if [[ $trap_status -ne 1 ]] && [[ $trap_status -ne 0 ]]; then
            [[ -d "$dest" ]] && ( umount "$dest" || fusermount -u "$dest") | log
        fi

        # Always unmount the bind and remove the temporary directory if they exist
        [[ ( ! -z "$bind" ) && -d "$bind" ]] && ( umount "$bind" || fusermount -u "$bind" ) | log
        [[ ( ! -z "$temp_dir" ) && -d "$temp_dir" ]] && rm -rdf "$temp_dir" | log
    fi

    # if we created the destination directory and it's empty, remove it
    if [[ "$made_dest" = true ]] && [[ -d "$real_dest" ]] && [ -z "$(ls -A "$real_dest")" ] && [[ "$real_dest" != "/" ]]; then
        rm -rdf "$real_dest" | log
    fi

    if [[ "$#" -gt 0 ]]; then
		exit $exit_code
	fi
	exit 0
}

# capture failures and clean up before exiting
trap 'cleanup' SIGINT SIGTERM


# if the destination does not exist, create it and flag for cleanup
if [[ ! -d "$real_dest" ]]; then
    mkdir -p -- "$real_dest" || { log "Failed to create destination directory \"$real_dest\"."; cleanup 1; }
    made_dest=true
fi

## Prepare for in-place overlay handling.
if [[ "$inplace" = true ]]; then
    # Create the bind directory (as a layer of obfuscation to prevent mergerfs from treating the original destination as a branch).
    [ -d "$bind" ] || { mkdir -p -- "$bind"; } || { log "Failed to create bind directory \"$bind\"."; cleanup 1; }
    mount --bind "${dest}" "${bind}" || { log "Failed to bind mount \"$dest\" to \"$bind\"."; cleanup 1; }

    # Make the bind mount private to prevent propagation of mounts/unmounts to the original destination. This prevents
    # mergerfs from failing due to a branch being the destination.
    mount --make-private "${bind}" || { log "Failed to make \"$bind\" private."; cleanup 1; }

    # Create the merged directory for the mergerfs mount.
    [ -d "$merged" ] || { mkdir -p -- "$merged"; } || { log "Failed to create merged directory \"$merged\"."; cleanup 1; }
fi


# Do the mergerfs mount. mergerfs_path depends on whether this is an in-place overlay or not.
$mergerfs_bin \
    -f \
    "$branches" \
    "$mergerfs_path" \
    -o flush-on-close=always \
    "${remaining_args[@]}" 2>&1 | log &
mergerfs_pid=$!

# Give mergerfs a short moment to start and verify it's running before binding merged back.
sleep 0.02
if ! kill -0 "$mergerfs_pid" 2>/dev/null; then
    log "mergerfs failed to start (pid $mergerfs_pid)";
    cleanup 1
fi

# If the overlay is in-place, mount the merged directory on top of the original destination.
if [[ "$inplace" = true ]]; then
    mount --bind "${merged}" "${dest}" || { log "Failed to bind mount back to \"$dest\"."; cleanup 1; }

    # clean up merged directory, it is no longer needed
    umount "${merged}" || { log "Failed to unmount temporary merged directory \"$merged\"."; cleanup 1; }
    rm -rdf "$merged" || { log "Failed to remove temporary merged directory \"$merged\"."; cleanup 1; }
fi

log "Mounted overlay at \"$dest\"."

# export variables for the cleanup subshell that will be disowned
export -f cleanup
export mergerfs_pid
export real_dest
export dest
export bind
export temp_dir
export made_dest
export inplace
export mergerfs_path
export -f log

(
    ## TODO: offload the cleanup to another script so that we can name the disowned process
    # Wait for the mergerfs process to exit, and then trigger cleanup. This ensures that the cleanup function 
    # runs after mergerfs has fully unmounted, which is important for in-place overlays to prevent trying to 
    # unmount the destination before mergerfs has released it.
    exec -a "overlay $dest" 
    bash -c '
    echo "overlay $dest" > /proc/self/comm
    while kill -0 "$mergerfs_pid" 2>/dev/null; do
        sleep 0.5
    done
    cleanup' "Overlay $dest"
) & disown

# disown $mergerfs_pid
# wait $mergerfs_pid

