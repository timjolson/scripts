#!/bin/bash

wget https://github.com/Seagate/ToolBin/raw/refs/heads/master/SeaChest/PowerControl/v3.7.1/linux/SeaChest_PowerControl_linux_x86_64
chmod +x SeaChest_PowerControl*

./SeaChest_PowerControl* --scan

# ./SeaChest_PowerControl_linux_x86_64 -d /dev/sdc --EPCfeature disable
# ./SeaChest_PowerControl_linux_x86_64 -d /dev/sdc --EPCfeature enable
# ./SeaChest_PowerControl_linux_x86_64 -d /dev/sdc --idle_a disable
# ./SeaChest_PowerControl_linux_x86_64 -d /dev/sdc --idle_b disable

