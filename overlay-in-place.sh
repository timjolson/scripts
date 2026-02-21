#!/bin/bash
logtofile=false

source /usr/local/bin/scripts/functions.sh

# Script to combine, via overlay, source directories with an existing destination directory.
# Creates a temporary bind mount of the original destination, then mounts the overlay combined directory on top of the original destination.

[ $# -ge 3 ] || { log "Usage $0 <destination dir> <branches str> <foreground bool> [<option1> <option2> ...]"; exit 2; }

dest="$1"
dest="${dest%%/}" # remove trailing slash if present
branches="$2"
foreground="$3"
shift 3
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

temp_dir=$(mktemp -d .$dest-XXXXXXXXX)
# temp_file="$temp_dir/.overlay"
bind="$temp_dir/bind"
merged="$temp_dir/merged"
branches="$bind$branches"
log "branches = \"$branches\""

cleanup() {
    fusermount -u "$dest" || { log "Failed to fusermount -u \"$dest\"."; }
    umount "$dest" || { log "Failed to umount \"$dest\"."; }
    kill -SIGTERM "$1" || { log "Failed to kill mergerfs process with PID $1."; }
    umount "$bind" || { log "Failed to umount bind directory \"$bind\"."; }
    umount "$merged" || { log "Failed to umount merged directory \"$merged\"."; }
    rm -rdf "$temp_dir" || { log "Failed to remove temporary directory \"$temp_dir\"."; }
}
trap 'cleanup $mergerfs_pid' SIGINT SIGTERM EXIT

# make bind directory
read -p "Make bind directory?..."
[ -d "$bind" ] || { log "Bind directory \"$bind\" does not exist. Creating it."; mkdir -p "$bind"; } || { log "Failed to create bind directory \"$bind\"."; exit 1; }
read -p "Make merged directory?..."
[ -d "$merged" ] || { log "Merged directory \"$merged\" does not exist. Creating it."; mkdir -p "$merged"; } || { log "Failed to create merged directory \"$merged\"."; exit 1; }
log "Make \"$merged\" private?..."
# mount --make-private "$merged" || { log "Failed to make \"$merged\" private."; exit 1; }

# bind mount the original destination directory to the temprary bind directory
read -p "Bind mount \"$dest\" to \"$bind\"?..."
mount --bind "${dest}" "${bind}" || { log "Failed to bind mount \"$dest\" to \"$bind\"."; exit 1; }
log "Make \"$bind\" private?..."
mount --make-private "${bind}" || { log "Failed to make \"$bind\" private."; exit 1; }

# use mergerfs to overlay the source and bind directories on top of the original destination directory
read -p "Mount merge to \"$merged\"?..."
# read -p "Mount merge to \"$dest\"?..."


/usr/bin/mergerfs \
    $fg_flag \
    "${mergerfs_opts[@]}" \
    "${branches}" \
    "${merged}" &
mergerfs_pid=$!

log "Mount overlay of \"$merged\" back to \"$dest\"?..."
mount --bind "${merged}" "${dest}" || { log "Failed to bind mount back to \"$dest\"."; exit 1; }
log "Mounted merge at \"$dest\"."

read -p "Press Enter to unmount and exit..."
cleanup "$mergerfs_pid"


# https://github.com/trapexit/mergerfs/releases/download/2.41.1/mergerfs_2.41.1.debian-bookworm_amd64.deb
