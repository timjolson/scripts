#TRIP_POINT_0=50000
#TRIP_POINT_1=53000
#TRIP_POINT_2=56000
#TRIP_POINT_3=59000
#TRIP_POINT_4=61000
#TRIP_POINT_5=64000
#TRIP_POINT_6=66000

#FAN_0=20
#FAN_1=80
#FAN_2=120
#FAN_3=180
#FAN_4=220
#FAN_5=240
#FAN_6=250
 
#echo $TRIP_POINT_0 > /sys/devices/virtual/thermal/thermal_zone0/trip_point_0_temp
#echo $TRIP_POINT_0 > /sys/devices/virtual/thermal/thermal_zone1/trip_point_0_temp
#echo $TRIP_POINT_0 > /sys/devices/virtual/thermal/thermal_zone2/trip_point_0_temp
#echo $TRIP_POINT_0 > /sys/devices/virtual/thermal/thermal_zone3/trip_point_0_temp
 
#echo $TRIP_POINT_1 > /sys/devices/virtual/thermal/thermal_zone0/trip_point_1_temp
#echo $TRIP_POINT_1 > /sys/devices/virtual/thermal/thermal_zone1/trip_point_1_temp
#echo $TRIP_POINT_1 > /sys/devices/virtual/thermal/thermal_zone2/trip_point_1_temp
#echo $TRIP_POINT_1 > /sys/devices/virtual/thermal/thermal_zone3/trip_point_1_temp
 
#echo $TRIP_POINT_2 > /sys/devices/virtual/thermal/thermal_zone0/trip_point_2_temp
#echo $TRIP_POINT_2 > /sys/devices/virtual/thermal/thermal_zone1/trip_point_2_temp
#echo $TRIP_POINT_2 > /sys/devices/virtual/thermal/thermal_zone2/trip_point_2_temp
#echo $TRIP_POINT_2 > /sys/devices/virtual/thermal/thermal_zone3/trip_point_2_temp

#echo $TRIP_POINT_3 > /sys/devices/virtual/thermal/thermal_zone0/trip_point_3_temp
#echo $TRIP_POINT_3 > /sys/devices/virtual/thermal/thermal_zone1/trip_point_3_temp
#echo $TRIP_POINT_3 > /sys/devices/virtual/thermal/thermal_zone2/trip_point_3_temp
#echo $TRIP_POINT_3 > /sys/devices/virtual/thermal/thermal_zone3/trip_point_3_temp

#echo $TRIP_POINT_4 > /sys/devices/virtual/thermal/thermal_zone0/trip_point_4_temp
#echo $TRIP_POINT_4 > /sys/devices/virtual/thermal/thermal_zone1/trip_point_4_temp
#echo $TRIP_POINT_4 > /sys/devices/virtual/thermal/thermal_zone2/trip_point_4_temp
#echo $TRIP_POINT_4 > /sys/devices/virtual/thermal/thermal_zone3/trip_point_4_temp

#echo $TRIP_POINT_5 > /sys/devices/virtual/thermal/thermal_zone0/trip_point_5_temp
#echo $TRIP_POINT_5 > /sys/devices/virtual/thermal/thermal_zone1/trip_point_5_temp
#echo $TRIP_POINT_5 > /sys/devices/virtual/thermal/thermal_zone2/trip_point_5_temp
#echo $TRIP_POINT_5 > /sys/devices/virtual/thermal/thermal_zone3/trip_point_5_temp

#echo $TRIP_POINT_6 > /sys/devices/virtual/thermal/thermal_zone0/trip_point_6_temp
#echo $TRIP_POINT_6 > /sys/devices/virtual/thermal/thermal_zone1/trip_point_6_temp
#echo $TRIP_POINT_6 > /sys/devices/virtual/thermal/thermal_zone2/trip_point_6_temp
#echo $TRIP_POINT_6 > /sys/devices/virtual/thermal/thermal_zone3/trip_point_6_temp

######
cat /sys/devices/virtual/thermal/thermal_zone0/trip_point_0_temp
cat /sys/devices/virtual/thermal/thermal_zone1/trip_point_0_temp
#cat /sys/devices/virtual/thermal/thermal_zone2/trip_point_0_temp
#cat /sys/devices/virtual/thermal/thermal_zone3/trip_point_0_temp
 
cat /sys/devices/virtual/thermal/thermal_zone0/trip_point_1_temp
cat /sys/devices/virtual/thermal/thermal_zone1/trip_point_1_temp
#cat /sys/devices/virtual/thermal/thermal_zone2/trip_point_1_temp
#cat /sys/devices/virtual/thermal/thermal_zone3/trip_point_1_temp
 
cat /sys/devices/virtual/thermal/thermal_zone0/trip_point_2_temp
#cat /sys/devices/virtual/thermal/thermal_zone1/trip_point_2_temp
#cat /sys/devices/virtual/thermal/thermal_zone2/trip_point_2_temp
#cat /sys/devices/virtual/thermal/thermal_zone3/trip_point_2_temp

cat /sys/devices/virtual/thermal/thermal_zone0/trip_point_3_temp
#cat /sys/devices/virtual/thermal/thermal_zone1/trip_point_3_temp
#cat /sys/devices/virtual/thermal/thermal_zone2/trip_point_3_temp
#cat /sys/devices/virtual/thermal/thermal_zone3/trip_point_3_temp

cat /sys/devices/virtual/thermal/thermal_zone0/trip_point_4_temp
#cat /sys/devices/virtual/thermal/thermal_zone1/trip_point_4_temp
#cat /sys/devices/virtual/thermal/thermal_zone2/trip_point_4_temp
#cat /sys/devices/virtual/thermal/thermal_zone3/trip_point_4_temp

cat /sys/devices/virtual/thermal/thermal_zone0/trip_point_5_temp
#cat /sys/devices/virtual/thermal/thermal_zone1/trip_point_5_temp
#cat /sys/devices/virtual/thermal/thermal_zone2/trip_point_5_temp
#cat /sys/devices/virtual/thermal/thermal_zone3/trip_point_5_temp

#cat /sys/devices/virtual/thermal/thermal_zone0/trip_point_6_temp
#cat /sys/devices/virtual/thermal/thermal_zone1/trip_point_6_temp
#cat /sys/devices/virtual/thermal/thermal_zone2/trip_point_6_temp
#cat /sys/devices/virtual/thermal/thermal_zone3/trip_point_6_temp


#echo "0 $FAN_0 $FAN_1 $FAN_2 $FAN_3 $FAN_4 $FAN_5 $FAN_6" > /sys/devices/platform/pwm-fan/hwmon/hwmon0/fan_speed
