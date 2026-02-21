#!/bin/bash

# Script to combine, via mergerfs overlay, branches into an existing destination directory.
# Creates a temporary bind mount of the original destination, then mounts the merged directory on top of the original destination.
logtofile=false

source "$(dirname "${BASH_SOURCE[0]}")/functions.sh"

[ $# -ge 2 ] || { log "Usage $0 <destination dir> <branches str> <foreground bool> [<option1> <option2> ...]"; exit 2; }


dest="$1"
dest="${dest%%/}" # remove trailing slash if present
branches="$2"

if [[ $# -ge 3 ]]; then
    foreground="$3"
    shift 3
else
    foreground=false
    shift 2
fi
options=("$@")

log "Overlaying \"$dest\" with \"$branches\"."
log "Options: ${options[*]}"

mergerfs_opts=()
for opt in "${options[@]}"; do
    mergerfs_opts+=("-o $opt")
done

if [[ "$foreground" == "true" ]]; then
    fg_flag="-f"
else
    fg_flag=""
fi

temp_dir=$(mktemp -d .XXXXXXXXXXXX)
bind="$temp_dir/bind-$dest"
merged="$temp_dir/merged-$dest"

# Split branches into array by ':' and strip trailing slashes from each element
IFS=':' read -r -a branches_array <<< "$branches"
# Strip trailing slashes from each element right after splitting
for i in "${!branches_array[@]}"; do
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

cleanup() {
    fusermount -u "$dest" || { log "Failed to fusermount -u \"$dest\"."; }
    umount "$dest" || { log "Failed to umount \"$dest\"."; }
    if [ -n "$1" ]; then
        kill -SIGTERM "$1" || { log "Failed to kill mergerfs process with PID $1."; }
    fi
    umount "$bind" || { log "Failed to umount bind directory \"$bind\"."; }
    umount "$merged" || { log "Failed to umount merged directory \"$merged\"."; }
    rm -rdf "$temp_dir" || { log "Failed to remove temporary directory \"$temp_dir\"."; }
}
mergerfs_pid=""
trap 'cleanup $mergerfs_pid' SIGINT SIGTERM EXIT

read -p "Make bind and merged directories?..."
[ -d "$bind" ] || { log "Bind directory \"$bind\" does not exist. Creating it."; mkdir -p "$bind"; } || { log "Failed to create bind directory \"$bind\"."; exit 1; }
[ -d "$merged" ] || { log "Merged directory \"$merged\" does not exist. Creating it."; mkdir -p "$merged"; } || { log "Failed to create merged directory \"$merged\"."; exit 1; }
# log "Make \"$merged\" private?..."
# mount --make-private "$merged" || { log "Failed to make \"$merged\" private."; exit 1; }

# bind mount the original destination directory to the temprary bind directory
read -p "Bind mount \"$dest\" to \"$bind\"?..."
mount --bind "${dest}" "${bind}" || { log "Failed to bind mount \"$dest\" to \"$bind\"."; exit 1; }
log "Make \"$bind\" private?..."
mount --make-private "${bind}" || { log "Failed to make \"$bind\" private."; exit 1; }

# use mergerfs to overlay the source and bind directories on top of the original destination directory
read -p "Mount the merge to \"$merged\"?..."
# read -p "Mount merge to \"$dest\"?..."


/usr/bin/mergerfs \
    $fg_flag \
    "${mergerfs_opts[@]}" \
    "${branches_combined}" \
    "${merged}" &
mergerfs_pid=$!

# log "Make \"$merged\" private?..."
# mount --make-private "${merged}" || { log "Failed to make \"$merged\" private."; exit 1; }

log "Mount overlay of \"$merged\" back to \"$dest\"?..."
mount --bind "${merged}" "${dest}" || { log "Failed to bind mount back to \"$dest\"."; exit 1; }
log "Mounted merge at \"$dest\"."

read -p "Press Enter to unmount and exit..."
cleanup "$mergerfs_pid"


# https://github.com/trapexit/mergerfs/releases/download/2.41.1/mergerfs_2.41.1.debian-bookworm_amd64.deb

