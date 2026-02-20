#!/bin/bash
logtofile=false

source /usr/local/bin/scripts/functions.sh

# Script to combine, via overlay, source directories with an existing destination directory.
# Creates a temporary bind mount of the original destination, then mounts the overlay combined directory on top of the original destination.

[ $# -ge 3 ] || { log "Usage $0 <destination dir> <temporary bind dir> <branches str> <foreground bool> [<option1> <option2> ...]"; exit 2; }

dest="$1"
dest="${dest%%/}" # remove trailing slash if present
# bind="$2"
# bind="${bind%%/}" # remove trailing slash if present
branches="$2"
foreground="$3"
shift 3
options=("$@")

log "Overlaying \"$dest\" with \"$branches\"."
log "Options: ${options[*]}"

mergerfs_options=()
mergerfs_opts=()
for opt in "${extra_opts[@]}"; do
    mergerfs_opts+=("-o" "$opt")
done

if [[ "$foreground" == "true" ]]; then
    fg_flag="-f"
else
    fg_flag=""
fi

bind="tmp/binds/${dest##/}"
merged="tmp/merged/${dest##/}"
bak="tmp/orig/"


unmount() {
    mergerfs_pid = $1
    fusermount -u "$dest" || { log "Failed to unmount \"$dest\"."; }
    kill -SIGTERM "$mergerfs_pid" || { log "Failed to kill mergerfs process with PID $mergerfs_pid."; }
    umount "$bind" || { log "Failed to unmount bind directory \"$bind\"."; }
    umount "$merged" || { log "Failed to unmount merged directory \"$merged\"."; }
    rm -rdf "$bind" "$merged" || { log "Failed to remove temporary directories \"$bind\" and \"$merged\"."; }
}
trap 'unmount $mergerfs_pid' SIGINT SIGTERM

# make bind directory
read -p "Make bind directory?..."
[ -d "${bind}" ] || { log "Bind directory \"${bind}\" does not exist. Creating it."; mkdir -p "${bind}"; } || { log "Failed to create bind directory \"${bind}\"."; exit 1; }
read -p "Make merged directory?..."
[ -d "${merged}" ] || { log "Merged directory \"${merged}\" does not exist. Creating it."; mkdir -p "${merged}"; } || { log "Failed to create merged directory \"${merged}\"."; exit 1; }
read -p "Make backup directory?..."
[ -d "${bak}" ] || { log "Backup directory \"${bak}\" does not exist. Creating it."; mkdir -p "${bak}"; } || { log "Failed to create backup directory \"${bak}\"."; exit 1; }

# bind mount the original destination directory to the temprary bind directory
read -p "Bind mount \"$dest\" to \"$bind\"?..."
mount --bind "${dest}" "${bind}" || { log "Failed to bind mount \"$dest\" to \"$bind\"."; exit 1; }
log "Make \"$bind\" private?..."
mount --make-private "${bind}" || { log "Failed to make \"$bind\" private."; exit 1; }

# use mergerfs to overlay the source and bind directories on top of the original destination directory
read -p "Mount merge to \"$merged\"?..."

/usr/bin/mergerfs \
    $fg_flag \
    "${mergerfs_opts[@]}" \
    "$branches" \
    "$merged" 2>&1 &
mergerfs_pid=$!

log "Make backup \"$dest\" to \"$bak\"?..."
mv "${dest}" "${bak}" || { log "Failed to move original destination directory \"$dest\"."; exit 1; }
log "Remake \"$dest\"?..."
mkdir -p "${dest}" || { log "Failed to create new destination directory \"$dest\"."; exit 1; }
# log "Make \"$dest\" private?..."
# mount --make-private "${dest}" || { log "Failed to make \"$dest\" private."; exit 1; }
log "Mount overlay of \"$merged\" back to \"$dest\"?..."
mount --bind "${merged}" "${dest}" || { log "Failed to bind mount back to \"$dest\"."; }
log "Mounted merge at \"$dest\"."

read -p "Press Enter to unmount and exit..."
unmount $mergerfs_pid


# scheduling-priority (-10 default)
# branches-mount-timeout-fail (bool)
# branches-mount-timeout (seconds)
# proxy-ioprio=true (passthrough I/O priority from caller)
# flush-on-close=never|always|opened-for-write: Flush data cache on file close. Mostly for when writeback is enabled or merging network filesystems. (default: opened-for-write)
# statfs-ignore=none|ro|nc: 'ro' will cause statfs calculations to ignore available space for branches mounted or tagged as 'read-only' or 'no create'. 'nc' will ignore available space for branches tagged as 'no create'. (default: none)
# nofail
# config file?

# fstab with config file
# /etc/mergerfs/branches/media/* /media mergerfs config=/etc/mergerfs/config/media.ini

# [Service]
# Type=notify
# RemainAfterExit=yes
# 
# /bin/systemd-notify --ready

# https://github.com/trapexit/mergerfs/releases/download/2.41.1/mergerfs_2.41.1.debian-bookworm_amd64.deb
