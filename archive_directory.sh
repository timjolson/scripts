#!/bin/bash
logtofile=true
dryrun=false

source "$(dirname "${BASH_SOURCE[0]}")/functions.sh"

# Default values
declare -A DEFAULTS=(
    ["src"]=""
    ["dest"]=""
    ["exclude"]=""
    ["precmd"]=""
    ["postcmd"]=""
)

[ $# -ge 4 ] || { log "Usage $0 [--src <src>] [--dest <archive_file>] [--exclude <path_to_exclude_from_tar>] [--precmd <command to run before archiving>] [--postcmd <command to run after archiving>]"; exit 2; }
parse_args DEFAULTS "$@"

([[ -z "$src" ]] || [[ -z "$dest" ]]) && { log "Must provide src and dest"; exit 2; }

[ ! -d "$src" ] && { log "Directory \"$src\" does not exist"; exit 2; }
# [ ! -f "$dest" ] && { log "Destination \"$dest\" does not exist"; exit 2; }
[ ! -n "$dest" ] && { log "Cannot access \"$dest\""; exit 2; }

[ -n "$precmd" ] && { log "Running precmd \"$precmd\""; ${precmd}; }

log "Archiving ${src} to ${dest}"
tar --exclude="${exclude}" -cp "${src}" -f "${dest}"

[ -n "$postcmd" ] && { log "Running postcmd \"$postcmd\""; ${postcmd}; }

log "Done."

exit 0
