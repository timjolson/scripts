#!/bin/bash
logtofile=true
dryrun=false

source /usr/local/bin/scripts/functions.sh

# Combine mkv files using ffmpeg. Usage: combinemkv.sh dest.mkv src1.mkv src2.mkv ...
# Example: combinemkv.sh combined.mkv part*.mkv

dest=$1
shift
src=("$@")

([[ -z "$src" ]] || [[ -z "$dest" ]]) || { log "Must provide src and dest"; exit 2; }
[ ! -n "$dest" ] && { log "Cannot access \"$dest\""; exit 2; }
log "Combining \"${src[@]}\" to \"$dest\""
# sourcestring="concat:$(IFS='|'; echo "${src[*]}")"

# Create a temporary file to hold the list of input files
temp_file=$(mktemp)

# Write the input files to the temporary file
for file in "${src[@]}"; do
        abs_path=$(realpath "$file")
        echo "file '$abs_path'" >> "$temp_file"
done

cmdstring="-f concat -safe 0 -i \"$temp_file\" -map 0 -c copy  \"$dest\""

# log "Source string \"$sourcestring\""
log "Temp file \"$temp_file\" contains:"
log "$(cat $temp_file)"
log "Destination file \"$dest\""
log "Command string \"$cmdstring\""

# [[ $dryrun == false ]] && ffmpeg -i "$sourcestring" $cmdstring -c:v copy -c:s copy "${dest}"
[[ $dryrun == false ]] && eval ffmpeg $cmdstring

# Clean up the temporary file
rm -f "$temp_file"

log "Done creating ${dest}"

exit 0
