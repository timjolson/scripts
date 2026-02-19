#!/usr/bin/env bash

#for i in /sys/class/thermal/thermal_zone[0-9]/temp /sys/class/hwmon/hwmon[0-9]/
#do
#	[[ -e $i ]] && echo "$i : $(<$i)"
#done


#watch -n 0.1 "head -n 1 /sys/devices/virtual/thermal/cooling_device0/cur_state; cat /sys/devices/virtual/thermal/thermal_zone[0-4]/temp;"
watch -n 0.1 "head -n 1 /sys/devices/virtual/thermal/cooling_device0/cur_state; cat /sys/devices/virtual/thermal/thermal_zone*/temp;"
