#!/bin/bash

# Pick one file from a wildcard pattern and update DEST to reference it.
# Depending on MODE, DEST becomes a symlink, a hardlink, or a copied file.
#
# Usage:
#   randomfile.sh "/path/to/files/*.conf" "/path/to/current.conf" [symlink|hardlink]
#
# Arguments:
#   SRC   Wildcard pattern that expands to one or more candidate files.
#   DEST  Path to replace. Its parent directory must already exist, and DEST
#         itself must not be a directory.
#   MODE  Optional. Defaults to symlink. Use hardlink to create a hard link,
#         with a normal file copy as fallback if the hard link cannot be made.
#
# Environment flags:
#   logtofile=true  Write messages through functions.sh to a log file.
#   dryrun=true     Print the chosen file without changing DEST.
#   debug=true      Print file count, selected index, and selected path.

logtofile=${logtofile:-false}
dryrun=${dryrun:-false}
debug=${debug:-false}

# Shared logging helpers and shell defaults.
source "$(dirname "${BASH_SOURCE[0]}")/functions.sh"

# Parse positional arguments and normalize the requested output mode.
if [ $# -lt 2 ] || [ $# -gt 3 ]; then
	log "Incorrect number of arguments ( $# instead of 2 or 3 ). Usage: $0 <src - wildcard file path> <dest - path to update> [symlink|hardlink]."
	exit 2
fi

SRC="${1}"
DEST="${2}"
MODE="${3:-symlink}"

case "$MODE" in
	symlink|hardlink)
		;;
	*)
		log "Invalid mode '$MODE'. Expected symlink or hardlink."
		exit 2
		;;
esac

# Resolve the wildcard into the candidate file set.
# Expand the wildcard into an array without word-splitting, so both the
# pattern and matched file paths can contain spaces.
mapfile -t CONNECTIONFILES < <(compgen -G "$SRC")

NUMCONNECTIONFILES=${#CONNECTIONFILES[@]}
[ "$debug" = true ] && log "NUMCONNECTIONFILES = $NUMCONNECTIONFILES"

[ "$NUMCONNECTIONFILES" -gt 0 ] || { log "No files matched $SRC"; exit 2; }

# Choose one candidate at random and verify that it is still present.
# Pick one matched file uniformly using Bash's RANDOM value.
SRCNUM=$((RANDOM % NUMCONNECTIONFILES))
[ "$debug" = true ] && log "SRCNUM = $SRCNUM"

SRCCONNECTIONFILE="${CONNECTIONFILES[$SRCNUM]}"
[ "$debug" = true ] && log "SRCCONNECTIONFILE = ${SRCCONNECTIONFILE}"

[ -f "${SRCCONNECTIONFILE}" ] || { log "File $SRCCONNECTIONFILE does not exist"; exit 2; }

# Validate the destination path before making any changes.
# DEST may already be a symlink or file; remove it before creating the new
# symlink, hardlink, or fallback copy.
test -n "${DEST}" || { log "Destination path is empty"; exit 2; }
test -d "$(dirname "${DEST}")" || { log "Destination directory for $DEST does not exist"; exit 2; }
[ -d "${DEST}" ] && { log "Destination path $DEST is a directory"; exit 2; }

# Allow callers to inspect the chosen file without touching DEST.
[ "$dryrun" = true ] && { log "Dry run: would create $MODE target from $SRCCONNECTIONFILE at $DEST"; exit 0; }

# Remove any existing destination so the replacement step starts cleanly.
rm -f "${DEST}" || { log "Failed to remove existing destination at $DEST"; exit 126; }

# Create the requested target type, falling back to a copy if hardlinking fails.
if [ "$MODE" = "symlink" ]; then
	ln -s "${SRCCONNECTIONFILE}" "${DEST}" || { log "Failed to create symlink at $DEST"; exit 126; }
	log "Using $SRCCONNECTIONFILE for $DEST via symlink"
	exit 0
fi

if ln "${SRCCONNECTIONFILE}" "${DEST}"; then
	log "Using $SRCCONNECTIONFILE for $DEST via hardlink"
	exit 0
fi

cp -f "${SRCCONNECTIONFILE}" "${DEST}" || { log "Failed to copy $SRCCONNECTIONFILE to $DEST after hardlink fallback"; exit 126; }
log "Using $SRCCONNECTIONFILE for $DEST via copy fallback"

exit 0
