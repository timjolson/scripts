#!/bin/bash
# inspired by https://stackoverflow.com/a/20225541

# Get the machine Architecture
Architecture=$(uname -m)
case "$Architecture" in
    x86)       Architecture="x86";;
    ia64)      Architecture="ia64";;
    i?86)      Architecture="x86";;
    amd64)     Architecture="amd64";;
    x86_64)    Architecture="x86_64";;
    sparc64)   Architecture="sparc64";;
    armv7l)    Architecture="armhf";;
    * ) echo "Your Architecture '$Architecture' -> ITS NOT SUPPORTED."; exit 1;;
esac

if [ $Architecture = "x86_64" ]
then Architecture="amd64"
fi

mkdir -p "./$Architecture"

mkdir -p "./$Architecture/packages_linux/partial"
packsdir=`cd "./$Architecture/packages_linux"; pwd`
chown $SUDO_USER $packsdir

mkdir -p "./$Architecture/dl_packages"
dlpacksdir=`cd "./$Architecture/dl_packages"; pwd`
chown $SUDO_USER $dlpacksdir

mkdir -p "./$Architecture/var-lib-snapd-snaps"
snap_package_dir=`cd "./$Architecture/var-lib-snapd-snaps"; pwd`
snapdir=/var/lib/snapd/snaps

chown $SUDO_USER -R "./$Architecture"

APT () {
    echo "Using local repository: '$packsdir'"
    apt-get -o dir::cache::archives=$packsdir $*
}

if [ $# -eq 0 ]
then # no args

while true
do
PS3='Cmd : '
options=("Clean" "Update" "Snap" "Gnome" "Kernel Upgrade" "Upgrade" "Update Grub" "Brave" "Firefox" "Plex" "Emby Theater" "Windscribe" "Git" "Python" "PyQt" "PyCharm" "FreeCAD" "Redis" "Wine" "Lutris" "Warframe in lutris" "Fusion360 in lutris" "MegaSync" "VirtualBox" "LibreOffice" "7zip" "Putty" "Syncthing" "ROS" "VLC" "Pithos" "OpenShot" "AnBox" "XnView" "FLIRC" "Hotspot" "Setup EasyTether" "Activate EasyTether" "Finish")
select opt in "${options[@]}"
do
    echo "#################"
    case $opt in
        "Clean")
            APT remove --purge thunderbird* rhythmbox* gnome-mahjongg* gnome-mines* aisleriot* remmina* gnome-sudoku* seahorse* libreoffice-*
            snap remove thunderbird
            break
            ;;
        "Update")
            # echo "If running live, replace 'restricted' with 'universe' except for 'Focal Fossa'"
            # gedit /etc/apt/sources.list | nano /etc/apt/sources.list
            APT update
            break
            ;;
        "Snap")
            APT install "snapd"
            dpkg -i $packsdir/snapd*.deb
            
            snap ack $snap_package_dir/bare_*.assert
            snap install $snap_package_dir/bare_*.snap
            
            snap ack $snap_package_dir/core*.assert
            snap install $snap_package_dir/core*.snap
            
            snap ack $snap_package_dir/snapd_*.assert
            snap install $snap_package_dir/snapd_*.snap
            
            snap ack $snap_package_dir/snap-store_*.assert
            snap install $snap_package_dir/snap-store_*.snap
            
            break
            ;;
        "Gnome")
            APT install "gnome-tweaks"
            gsettings set org.gnome.shell.extensions.dash-to-dock click-action 'minimize'
            echo "enabled=false" > /home/$SUDO_USER/.config/user-dirs.conf
            cp files/user-dirs.dirs /home/$SUDO_USER/.config/
            chown $SUDO_USER /home/$SUDO_USER/.config/user-dirs.dirs
            #rm /home/$SUDO_USER/.config/gtk-3.0/bookmarks

            cp files/nautilus/explore__admin /home/$SUDO_USER/.local/share/nautilus/scripts/
            cp files/nautilus/terminal /home/$SUDO_USER/.local/share/nautilus/scripts/
            chown $SUDO_USER /home/$SUDO_USER/.local/share/nautilus/scripts/*
            chmod +x /home/$SUDO_USER/.local/share/nautilus/scripts/*
            nautilus /home/$SUDO_USER/.local/share/nautilus/scripts

            snap ack $snap_package_dir/gnome-system-monitor*.assert
            snap ack $snap_package_dir/gnome-characters*.assert
            snap ack $snap_package_dir/gnome-calculator*.assert
            snap ack $snap_package_dir/gnome-calendar*.assert
            snap ack $snap_package_dir/gnome-logs*.assert
            snap ack $snap_package_dir/gtk2-common*.assert

            snap install $snap_package_dir/gnome-system-monitor*.snap 
            snap install $snap_package_dir/gnome-characters*.snap 
            snap install $snap_package_dir/gnome-calculator*.snap 
            snap install $snap_package_dir/gnome-logs*.snap 
            snap install $snap_package_dir/gnome-calendar*.snap 
            snap install $snap_package_dir/gtk2-common-themes*.snap

            break
            ;;
        "Kernel Upgrade")
            bash $Architecture/kernel/ubuntu-mainline-kernel.sh -i
            echo "Make sure to REBOOT"

            break
            ;;
        "Upgrade")
            APT upgrade
            APT dist-upgrade
            break
            ;;
        "Update Grub")
            sed -i -e 's/GRUB_DEFAULT=.*/GRUB_DEFAULT=saved\nGRUB_SAVEDEFAULT=true/g' /etc/default/grub
            sed -i -e 's/GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/g' /etc/default/grub
            #sed -i -e 's/GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash acpi_backlight=vendor"/g' /etc/default/grub
            sed -i -e 's/GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"/g' /etc/default/grub
            update-grub
            break
            ;;
        "Brave")
            APT install apt-transport-https curl

            curl -fsSLo /usr/share/keyrings/brave-browser-archive-keyring.gpg https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg
            curl -fsSLo /etc/apt/sources.list.d/brave-browser-release.sources https://brave-browser-apt-release.s3.brave.com/brave-browser.sources

            # echo "deb [signed-by=/usr/share/keyrings/brave-browser-archive-keyring.gpg arch=amd64] https://brave-browser-apt-release.s3.brave.com/ stable main"|sudo tee /etc/apt/sources.list.d/brave-browser-release.list

            APT update
            APT install brave-browser
            break
            ;;
        "Firefox")
            snap ack $snap_package_dir/firefox*.assert
            snap install $snap_package_dir/firefox*.snap
            break
            ;;
        "Plex")
            snap ack $snap_package_dir/plex*.assert
            snap install $snap_package_dir/plex*.snap
            break
            ;;
        "Emby Theater")
            if [ $Architecture = "amd64" ]
            then
		APT install "cec-utils libasound2 libatomic1 libc6 libegl1 libgcc-s1 libpulse0 libstdc++6 libxdamage1 libnss3 libatk1.0-0 libatk-bridge2.0-0 librust-gdk-pixbuf-sys-dev libgtk-3-0 libxss1"
            else
		APT install "cec-utils libasound2 libatomic1 libc6 libegl1 libgcc-s1 libpulse0 libstdc++6"
            fi
            APT install $dlpacksdir/emby-theater*.deb
            break
            ;;
        "Windscribe")
            if [ $Architecture = "armhf" ]
            then
                APT install $dlpacksdir/windscribe-cli*$Architecture.deb
            else
                APT install resolvconf net-tools libxcb-cursor0
                dpkg -i $dlpacksdir/windscribe*$Architecture.deb
            fi
            break
            ;;
        "Git")
            APT install "git"
            echo "github email:  username@users.noreply.github.com"
            break
            ;;
        "Python")
            APT install "copyq screen scite python3.10 python3-setuptools python3-pip jupyter"
            bash python_pkgs -i -d -p "numpy scipy ipython tqdm sympy pytest six skills pbkdf2 rsa lxml bs4 protobuf requests pillow"
            APT install "python3-opencv"

            cp files/nautilus/scite /home/$SUDO_USER/.local/share/nautilus/scripts/
            chown $SUDO_USER /home/$SUDO_USER/.local/share/nautilus/scripts/*
            chmod +x /home/$SUDO_USER/.local/share/nautilus/scripts/*

            cp files/.SciTEUser.properties /home/$SUDO_USER/
            chown $SUDO_USER /home/$SUDO_USER/.SciTEUser.properties
            break
            ;;
        "PyQt")
            # APT install "python3-pyqt5 pyqt5-dev-tools qttools5-dev-tools"
            # APT install "python3-pyqt5.qtopengl python3-pyqtgraph"
            # tar -xf
            # cd, ./configure
            # make install
            bash python_pkgs -i -d -p "PyQt5==5.14 PyQt5-stubs==5.15.2.0 pytest-qt pyopengl pyqtgraph==0.11rc0"
            
            ##echo "alias designer='qtchooser -qt=5 -run-tool=designer'" > /home/$SUDO_USER/.bash_aliases
            
            break
            ;;
        "PyCharm")
            snap ack $snap_package_dir/pycharm-community*.assert
            snap install $snap_package_dir/pycharm-community*.snap --classic
            break
            ;;
        "FreeCAD")
            APT install freecad
        
            ##git clone https://github.com/realthunder/FreeCAD.git $dlpacksdir/freecad-source
            #cd $dlpacksdir/freecad-source
            #git pull
            #cd ../
            ##APT install "cmake cmake-gui libboost-date-time-dev libboost-dev libboost-filesystem-dev libboost-graph-dev libboost-iostreams-dev libboost-program-options-dev libboost-python-dev libboost-regex-dev libboost-serialization-dev libboost-thread-dev libcoin-dev libeigen3-dev libgts-bin libgts-dev libkdtree++-dev libmedc-dev libocct-data-exchange-dev libocct-ocaf-dev libocct-visualization-dev libopencv-dev libproj-dev libpyside2-dev libqt5opengl5-dev libqt5svg5-dev libqt5webkit5-dev libqt5x11extras5-dev libqt5xmlpatterns5-dev libshiboken2-dev libspnav-dev libvtk7-dev libx11-dev libxerces-c-dev libzipios++-dev occt-draw pyside2-tools python3-dev python3-matplotlib python3-pivy python3-ply python3-pyside2.qtcore python3-pyside2.qtgui python3-pyside2.qtsvg python3-pyside2.qtwidgets python3-pyside2uic qtbase5-dev qttools5-dev swig"
            #APT install "cmake libboost-date-time-dev libboost-dev libboost-filesystem-dev libboost-graph-dev libboost-iostreams-dev libboost-program-options-dev libboost-python-dev libboost-regex-dev libboost-serialization-dev libboost-thread-dev libcoin-dev libeigen3-dev libgts-bin libgts-dev libkdtree++-dev libmedc-dev libocct-data-exchange-dev libocct-ocaf-dev libocct-visualization-dev libopencv-dev libproj-dev libpyside2-dev libqt5opengl5-dev libqt5svg5-dev libqt5webkit5-dev libqt5x11extras5-dev libqt5xmlpatterns5-dev libshiboken2-dev libspnav-dev libvtk7-dev libx11-dev libxerces-c-dev libzipios++-dev occt-draw pyside2-tools python3-dev python3-matplotlib python3-pivy python3-ply python3-pyside2.qtcore python3-pyside2.qtgui python3-pyside2.qtsvg python3-pyside2.qtwidgets qtbase5-dev qttools5-dev swig"
            #mkdir -p $dlpacksdir/freecad-build
            #cd $dlpacksdir/freecad-build
            ##cmake -DBUILD_QT5=ON -S $dlpacksdir/freecad-source -B $dlpacksdir/freecad-build
            #cmake -DBUILD_QT5=ON -DPYTHON_EXECUTABLE=/usr/bin/python3.8 -DPYTHON_INCLUDE_DIR=/usr/include/python3.8 -DPYTHON_LIBRARY=/usr/lib/x86_64-linux-gnu/libpython3.8.so -DPYTHON_PACKAGES_PATH=/usr/lib/python3.8/dist-packages/ -DPYTHON_EXECUTABLE=/usr/bin/python3.8 -S $dlpacksdir/freecad-source -B $dlpacksdir/freecad-build
            #make -j$(nproc --ignore=2)
            #cd $packsdir/../..
            
            ##TODO: qt designer plugin
            ##https://wiki.freecadweb.org/Compile_on_Linux
            ##/usr/lib/x86_64-linux-gnu/qt5/bin/qmake ../freecad-source/src/Tools/plugins/widget/plugin.pro
            ##make --include-dir=../freecad-source/src/Tools/plugins/widget/

            break
            ;;
        "Redis")
            APT install "redis-server"
            python_pkgs -i -d -p "redis hiredis"
            break
            ;;
        "Wine")
            # if [ ! -f files/winehq.key ]
            # then
            wget -nc https://dl.winehq.org/wine-builds/winehq.key -O files/winehq.key
            # fi
            apt-key add files/winehq.key
            dpkg --add-architecture i386
            add-apt-repository ppa:cybermax-dexter/sdl2-backport
            apt-add-repository 'deb https://dl.winehq.org/wine-builds/ubuntu/ bionic main'
            
            APT update
            #APT install wine-stable
            #APT install wine-stable-amd64 wine-stable-i386 wine-stable
            APT install --install-recommends winehq-stable
            APT install "winetricks"
            break
            ;;
        "Lutris")
            apt-add-repository ppa:lutris-team/lutris
            APT update
            APT install lutris
            
            APT install libgl1-mesa-glx:i386 libgl1-mesa-dri:i386
            APT install mesa-vulkan-drivers mesa-vulkan-drivers:i386
            break
            ;;
        "Warframe in lutris")
            add-apt-repository ppa:kisak/kisak-mesa
            #add-apt-repository ppa:graphics-drivers/ppa
            dpkg --add-architecture i386 
            APT update
            APT upgrade
            #APT install nvidia-driver-440 libnvidia-gl-440 libnvidia-gl-440:i386
            APT install libgl1-mesa-glx:i386 libgl1-mesa-dri:i386
            #APT install libvulkan1 libvulkan1:i386
            APT install mesa-vulkan-drivers mesa-vulkan-drivers:i386
        
            wget -nc https://lutris.net/api/installers/warframe-standalone?format=json -O files/warframe-standalone.json
            su -c "lutris --install files/warframe*.json" $SUDO_USER
            break
            ;;
        "Fusion360 in lutris")
            wget -nc https://lutris.net/api/installers/autodesk-fusion-360-autodesk-client?format=json -O files/autodesk-fusion-360-autodesk-client.json
            su -c "lutris --install files/autodesk*.json" $SUDO_USER
            break
            ;;
        "MegaSync")
            if [ $Architecture = "armhf" ]
            then
                APT install $dlpacksdir/megacmd*$Architecture.deb
            else
                APT install $dlpacksdir/megasync*$Architecture.deb
            fi
            break
            ;;
        "VirtualBox")
            wget -q https://www.virtualbox.org/download/oracle_vbox.asc -O- | sudo apt-key add -
            wget -q https://www.virtualbox.org/download/oracle_vbox_2016.asc -O- | sudo apt-key add -
            sudo add-apt-repository "deb [arch=amd64] http://download.virtualbox.org/virtualbox/debian $(lsb_release -cs) contrib"
            
            APT update
            APT install -f virtualbox-7.0
            
            echo "\n****\nTo allow shared folder access in VM, 'sudo adduser $USER vboxsf'\n****\n"
            break
            ;;
        "LibreOffice")
            snap ack $snap_package_dir/libreoffice*.assert
            snap install $snap_package_dir/libreoffice*.snap
            break
            ;;
        "7zip")
            #APT install "p7zip-full"
            APT install "xarchiver rar unrar"
            snap ack $snap_package_dir/p7zip*.assert
            snap install $snap_package_dir/p7zip*.snap
            break
            ;;
        "Putty")
            APT install putty sshfs
            break
            ;;
        "Syncthing")
            APT install syncthing
            break
            ;;
        "ROS")
            # set locale
            locale-gen en_US en_US.UTF-8
            update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
            export LANG=en_US.UTF-8

            # add keys for updates
            APT install curl gnupg2 lsb-release
            APT install lsb-release
            
            sudo curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key  -o /usr/share/keyrings/ros-archive-keyring.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros2/ubuntu $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/ros2.list > /dev/null
            
            APT update
            #APT install ros-foxy-ros-base
            APT install ros-foxy-desktop
            APT install ros-foxy-rqt*
            APT install ros-foxy-ros2bag ros-foxy-rosbag2


            ## curl -s https://raw.githubusercontent.com/ros/rosdistro/master/ros.asc files/ros.asc
            ## cat files/ros.asc | sudo apt-key add -
            #sudo sh -c 'echo "deb [arch=$(dpkg --print-architecture)] http://packages.ros.org/ros2/ubuntu $(lsb_release -cs) main" > /etc/apt/sources.list.d/ros2-latest.list'
            #apt-key adv --keyserver 'hkp://keyserver.ubuntu.com:80' --recv-key C1CF6E31E6BADE8868B172B4F42ED6FBAB17C654
            #apt-key del 421C365BD9FF1F717815A3895523BAEEB01FA116

            ## for full desktop
            #APT install ros-foxy-desktop
            #APT install ros-foxy-rqt*
            #APT install ros-foxy-ros2bag ros-foxy-rosbag2

            ## for SBC
            ##APT install ros-foxy-ros-base
            ##bash python_pkgs -i -d -p wiringpi

            bash python_pkgs -d -i -p "argcomplete pyserial"
            
            echo "\n****\nRemember to 'source /opt/ros/foxy/setup.bash' in the terminal (consider adding to /home/$USER/.bashrc)\n****\n"
            #echo "source /opt/ros/foxy/setup.bash" >> /home/$SUDO_USER/.bashrc
            
            break
            ;;
        "VLC")
            if [ $Architecture = "armhf" ]
            then
                APT install vlc
            else
                snap ack $snap_package_dir/vlc*.assert
                snap install $snap_package_dir/vlc*.snap
            fi
            break
            ;;
        "Pithos")
            APT install pithos
            break
            ;;
        "OpenShot")
            add-apt-repository ppa:openshot.developers/ppa
            APT update
            APT install openshot-qt
            break
            ;;
        "AnBox")
            #add-apt-repository ppa:morphis/anbox-support
            #APT install "linux-headers-generic anbox-modules-dkms"
            #modprobe ashmem_linux
            #modprobe binder_linux
            #APT install "android-tools-adb"
            APT install $packsdir/android-tools-adb*.deb

            #snap download --beta anbox
            snap ack $snap_package_dir/anbox*.assert
            snap install --devmode --beta $snap_package_dir/anbox*.snap
            
            #snap set anbox rootfs-overlay.enable=true
            #snap restart anbox.container-manager
            #chown -R 100000:100000 /var/snap/anbox/common/rootfs-overlay
            
            snap set anbox bridge.address=192.168.250.1
            snap set anbox bridge.netmask=255.255.255.0
            snap set anbox bridge.network=192.168.250.1/24
            #snap set anbox bridge.nat.enable=true
            snap set anbox container.network.address=192.168.250.2
            snap set anbox container.network.gateway=192.168.250.1
            snap set anbox container.network.dns=8.8.8.8
            
            break
            ;;
        "XnView")
            add-apt-repository multiverse
            APT update
            APT install ubuntu-restricted-extras libfuse2

            # APT install libgdk-pixbuf2.0-0 libvdpau* vainfo libva2
            APT install libgdk-pixbuf* libvdpau1 vainfo libva2 libva1

            #dpkg -i $dlpacksdir/XnV*
            APT install "$dlpacksdir/XnView*.deb"
            break
            ;;
        "FLIRC")
            #echo "deb http://apt.flirc.tv/arch/x64 binary/" >> "/etc/apt/sources.list"
            #APT_SOURCE_PATH="/etc/apt/sources.list.d/flirc_fury.list"
            #echo "deb [trusted=yes] https://apt.fury.io/flirc/ /" > ${APT_SOURCE_PATH}
            
            APT update
            APT install libhidapi-hidraw0 libqt5core5a libqt5network5 libqt5xml5 libqt5xmlpatterns5 #qt5-qtbase libhid qt5-qtsvg hidapi
            #APT install flirc
            break
            ;;
        "Hotspot")
            echo "SSID:"
            read ssid
            echo "Key:"
            read key
            #nmcli connection modify $ssid 802-11-wireless-security.key-mgmt wpa-psk 802-11-wireless-security.psk $key
            cp files/Hotspot /etc/NetworkManager/system-connections/
            chown $SUDO_USER /etc/NetworkManager/system-connections/Hotspot
            sed -i -e 's/ssid=.*/ssid=$ssid/g' /etc/NetworkManager/system-connections/Hotspot
            sed -i -e 's/psk=.*/psk=$key/g' /etc/NetworkManager/system-connections/Hotspot
            systemctl restart NetworkManager
            #https://www.linuxuprising.com/2018/09/how-to-create-wi-fi-hotspot-in-ubuntu.html
            echo "To use: in wifi settings, select 'Connect to Hidden Network' and choose $ssid"
            break
            ;;
        "Setup EasyTether")
            #APT install "libbluetooth3 libc6 libssl1.1"
            dpkg -i easytether/easytether*_$Architecture.deb
            systemctl disable systemd-networkd
            systemctl enable systemd-networkd
            systemctl start systemd-networkd
            
            cp easytether/easytether.desktop /home/$SUDO_USER/Desktop/
            chown $SUDO_USER /home/$SUDO_USER/Desktop/easytether.desktop
            break
            ;;
        "Activate EasyTether")
            easytether-usb | easytether-bluetooth 64:09:AC:B5:22:D9
            break
            ;;
        "Finish")
            timedatectl set-local-rtc 1 --adjust-system-clock
            #timedatectl set-local-rtc 0 --adjust-system-clock
            break
            ;;
        *) echo Quit; exit 0;;
    esac
done
done

else # args provided at terminal
    APT $*
fi
