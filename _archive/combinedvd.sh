#!/bin/bash
logtofile=true
dryrun=false

source /usr/local/bin/scripts/functions.sh

# Combine dvd files using ffmpeg. Usage: combinedvd.sh dest.mpg src1.VOB src2.VOB ...
# Example: combinedvd.sh combined.mpg *.VOB

dest=$1
shift
src=("$@")

([[ -z "$src" ]] || [[ -z "$dest" ]]) && { log "Must provide destination file and source directory"; exit 2; }
[ ! -n "$dest" ] && { log "Cannot access \"$dest\""; exit 2; }

log "Making \"$dest\" from \"${src[@]}\""
# ffmpeg -i "concat:$(printf "%s|" *.VOB | sed 's/|$//')" -c copy "${dest}.mpg"
cmdstring="concat:$(IFS='|'; echo "${src[*]}")"
deststring="$dest"

log "Command string \"$cmdstring\""
log "Destination file \"$deststring\""

[[ $dryrun == false ]] && ffmpeg -i "$cmdstring" -c copy "${deststring}"

log "Done creating ${deststring}"

exit 0
