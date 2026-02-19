#!/bin/bash
logtofile=true
dryrun=false

source /usr/local/bin/scripts/functions.sh
# set -x
set +e

# get ip to check
query=$1
log "Checking '$1' against whitelist"

# get valid SSH logins
#~ SSHREF=$(journalctl -n 15 -bo -xeu ssh | grep -sP -o "Accepted password for .* from .* port .* ssh2")
SSHREF=$(journalctl --since "2 hours ago" -xeu ssh | grep -sP -o "Accepted password for .* from .* port .* ssh2")
return_value=$?
if [ $return_value -eq 0 ]; then
        # compare
        GREPMATCH=$(echo $SSHREF | grep "\s$query\s")
        return_value=$?
        #~ echo $GREPMATCH

        # matches, exit
        if [ $return_value -eq 0 ]; then
                log "Matched in ssh"
                #~ echo $GREPMATCH
                exit 0
        fi
fi

# compare to my WAN ip
MYIP=$(curl -s ipinfo.io/ip)
#~ echo $MYIP
GREPMATCH=$((echo $MYIP) | grep "^$query$")
return_value=$?
if [ $return_value -eq 0 ]; then
        # matches, exit
        if [ $return_value -eq 0 ]; then
                log "Matched in WAN"
                #~ echo $GREPMATCH
                exit 0
        fi
fi

# compare to my vpn WAN ip
MYVPNIP=$(/usr/sbin/ip netns exec vpnNS curl -s ipinfo.io/ip)
#~ echo $MYIP
GREPMATCH=$((echo $MYVPNIP) | grep "^$query$")
return_value=$?
if [ $return_value -eq 0 ]; then
        # matches, exit
        if [ $return_value -eq 0 ]; then
                log "Matched in vpn WAN"
                #~ echo $GREPMATCH
                exit 0
        fi
fi

# log "IP did NOT match"
# exit and return match or no match
exit 1

