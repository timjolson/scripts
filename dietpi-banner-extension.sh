PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin
PATH="${PATH:+${PATH}:}/usr/local/bin:/usr/bin:/bin"

# Import DietPi-Globals --------------------------------------------------------------
. /boot/dietpi/func/dietpi-globals

COLOUR_RESET='\e[0m'
aCOLOUR=(

        '\e[38;5;154m'  # DietPi green  | Lines, bullets and separators
        '\e[1m'         # Bold white    | Main descriptions
        '\e[90m'        # Grey          | Credits
        '\e[91m'        # Red           | Update notifications
        '\e[1;32m'     # Green       | Good state
        '\e[1;33m'     # Yellow
        '\e[1;36m'     # Blue

)
GREEN_LINE=" ${aCOLOUR[0]}-----------------------------------------------------$COLOUR_RESET"
GREEN_BULLET=" ${aCOLOUR[0]}-$COLOUR_RESET"
GREEN_SEPARATOR="${aCOLOUR[0]}:$COLOUR_RESET"


IFACE="tun0"
VPN_CONNECTED=0
timeout=5

WAN_IP=$(ip netns exec vpnNS curl -sSfLm 0.1 'https://dietpi.com/geoip' 2>&1)
WAN_IP=$(ip netns exec vpnNS curl -sSfLm "$timeout" 'https://dietpi.com/geoip' 2>&1)

Check_Connected()
{
        [[ $(ip netns exec vpnNS ip r l dev "$IFACE" 2> /dev/null) ]] && VPN_CONNECTED=1 || VPN_CONNECTED=0
        return $(( ! $VPN_CONNECTED ))
}


Get_Connection_Info()
{
        RX='N/A'
        local rx=$(ip netns exec vpnNS cat "/sys/class/net/$IFACE/statistics/rx_bytes")
        [[ $rx =~ ^[0-9]+$ ]] && RX="$(printf "%.2f" "$(awk "BEGIN {print $rx / (1024^3)}")") GiB"
#        [[ $rx =~ ^[0-9]+$ ]] && RX="$(( $rx / 1024**3 )) GiB"
        TX='N/A'
        local tx=$(ip netns exec vpnNS cat "/sys/class/net/$IFACE/statistics/tx_bytes")
        [[ $tx =~ ^[0-9]+$ ]] && TX="$(printf "%.2f" "$(awk "BEGIN {print $tx / (1024^3)}")") GiB"
#        [[ $tx =~ ^[0-9]+$ ]] && TX="$(( $tx / 1024**3 )) GiB"
}


if Check_Connected
then
        Get_Connection_Info
        # echo -e "${aCOLOUR[4]}Connected ${COLOUR_RESET}- ${WAN_IP}${COLOUR_RESET}"
        echo -e "${WAN_IP}${COLOUR_RESET}"
        echo -e "$GREEN_BULLET ${aCOLOUR[1]}Data $GREEN_SEPARATOR TX = $TX - RX = $RX${COLOUR_RESET}"
else
        echo -e "${aCOLOUR[3]}Disconnected${COLOUR_RESET}"
fi


# check filesystem space

dir="/media"
name="Media"
str=$(df -h | grep -P "$dir\$" | awk '{print $3 " / " $2 " = " $5 }' )
echo -e "$GREEN_BULLET ${aCOLOUR[1]}$name $GREEN_SEPARATOR $str ${COLOUR_RESET}"

# dir="/mnt/syncmerg"
# name="Sync"
# str=$(df -h | grep -P "$dir" | awk '{print $3 " / " $2 " = " $5 }' )
# echo -e "$GREEN_BULLET ${aCOLOUR[1]}$name $GREEN_SEPARATOR $str ${COLOUR_RESET}"


dir="/mnt/nvme"
name="NVME"
str=$(df -h | grep -P "$dir" | awk '{print $3 " / " $2 " = " $5 }' )
echo -e "$GREEN_BULLET ${aCOLOUR[1]}$name $GREEN_SEPARATOR $str ${COLOUR_RESET}"

dir="/mnt/mediastore"
name="MediaStore"
str=$(df -h | grep -P "$dir" | awk '{print $3 " / " $2 " = " $5 }' )
echo -e "$GREEN_BULLET ${aCOLOUR[1]}$name $GREEN_SEPARATOR $str ${COLOUR_RESET}"


# check services for failures
FAILED_CNT=$(systemctl list-units | grep -i failed | wc -l)
if [[ FAILED_CNT -eq 0 ]]; then
	echo -e "$GREEN_BULLET ${aCOLOUR[1]}Services Check $GREEN_SEPARATOR ${COLOUR_RESET}No Services Failed${COLOUR_RESET}"
else
	echo -e "$GREEN_BULLET ${aCOLOUR[1]}Services Check $GREEN_SEPARATOR ${aCOLOUR[3]}$FAILED_CNT Service(s) Failed${COLOUR_RESET}"
fi

# check fail2ban ip count
COUNTIPS=$(iptables -L -n | grep "REJECT" | uniq -c | wc -l)
if [[ COUNTIPS -eq 0 ]]; then
	echo -e "$GREEN_BULLET ${aCOLOUR[1]}Fail2ban Check $GREEN_SEPARATOR ${aCOLOUR[3]}No IP(s) Banned${COLOUR_RESET}"
else
        if [[ COUNTIPS -gt 15 ]]; then
                echo -e "$GREEN_BULLET ${aCOLOUR[1]}Fail2ban Check $GREEN_SEPARATOR ${aCOLOUR[5]}$COUNTIPS IP(s) Banned${COLOUR_RESET}"
        else
                echo -e "$GREEN_BULLET ${aCOLOUR[1]}Fail2ban Check $GREEN_SEPARATOR ${COLOUR_RESET}$COUNTIPS IP(s) Banned${COLOUR_RESET}"
        fi
fi

