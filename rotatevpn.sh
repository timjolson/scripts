#!/bin/bash
logtofile=true
dryrun=false

source /usr/local/bin/scripts/functions.sh

NUMARGS=2
if [ $# != $NUMARGS ]; then
	log "Incorrect number of arguments ( $# instead of $NUMARGS ). Usage: $0 <src - wildcard file path> <dest - where to link the rotated config>."
	exit 2
fi

SRC="${1}"
DEST="${2}"

NUMCONNECTIONFILES=($(ls $SRC | wc -l))
#log "NUMCONNECTIONFILES = $NUMCONNECTIONFILES"

SRCNUM=$(($RANDOM % NUMCONNECTIONFILES))
#log "SRCNUM = $SRCNUM"

SRCCONNECTIONFILE="${SRC/\*/${SRCNUM}}"
#log "SRCCONNECTIONFILE = ${SRCCONNECTIONFILE}"

[ ! -f ${SRCCONNECTIONFILE} ] && log "File $SRCCONNECTIONFILE does not exist" && exit 2;
#[ ! -f ${DEST} ] && log "File $DEST does not exist" && exit 2;

test -n "${DEST}" || (log "No access to $DEST" && exit 2;)
ln -s -f "${SRCCONNECTIONFILE}" "${DEST}" || (log "Failed to create link at $DEST" && exit 126;)
log "Using $SRCCONNECTIONFILE for $DEST"

exit 0
