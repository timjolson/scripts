#!/bin/bash
logtofile=false

source /usr/local/bin/scripts/functions.sh

# Script to combine via overlay source directories with an existing destination directory.
# Creates a temporary bind mount of the original destination, then mounts the overlay combined directory on top of the original destination.

[ $# -ge 3 ] || { log "Usage $0 <destination dir> <temporary bind dir> <branches str> <foreground bool> [<option1> <option2> ...]"; exit 2; }

dest="$1"
bind="$2"
branches="$3"
foreground="$4"
shift 4
options=("$@")

log "Overlaying \"$dest\" with \"$bind\" and \"$branches\"."
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

# make bind directory
[ -d "${bind}" ] || { log "Bind directory \"${bind}\" does not exist. Creating it."; mkdir -p "${bind}"; } || { log "Failed to create bind directory \"${bind}\"."; exit 1; }

# bind mount the original destination directory to the temprary bind directory
log "Bind mounting \"$dest\" to \"$bind\"."
mount --bind "${dest}" "${bind}" || { log "Failed to bind mount \"$dest\" to \"$bind\"."; exit 1; }

# use mergerfs to overlay the source and bind directories on top of the original destination directory
log "Mounting in-place overlay of \"$dest\"."

/usr/bin/mergerfs \
    $fg_flag \
    "${mergerfs_opts[@]}" \
    "$branches" \
    "$dest" || { log "Failed to mount overlay on \"$dest\"."; exit 1; }

# /usr/bin/mergerfs \
# 	# foreground?
#     -f \
# 	-o cache.files=partial \
#     # recommended with cache.files!=off
# 	-o dropcacheonclose=true \ 
#     # https://trapexit.github.io/mergerfs/latest/config/functions_categories_policies/#policy-descriptions
#     # =pfrd weighted random
# 	-o category.create=ff \ 
#     # for create operation
# 	-o minfreespace=20G \ 
# 	-o fsname=mergmediafs \
# 	-o moveonenospc=true \
#     # keep file on same filesystem when renaming
# 	-o ignorepponrename=true \
# 	-o func.getattr=newest \
#     # dietpi:dietpi
# 	-o uid=1000 \
# 	-o gid=1000 \
#     -o statfs-ignore=ro \
# 	"$branches" \
# 	"$dest"

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

exit 0

