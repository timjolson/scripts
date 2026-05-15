#!/bin/bash
logpath=/var/log/certbot-renew.log
echo "$(date) renewing certs DEPLOY-HOOK" >> $logpath

le_dir="/etc/letsencrypt/live"
dns_name="awyw.crabdance.com"
syncthing_dir="/mnt/dietpi_userdata/syncthing"
dietpi_dashboard_dir="/opt/dietpi-dashboard"
whitelistpath="/var/log/whitelist.log"

### stop running services
# echo "$(date) stopping nextcloud" >> $logpath
# sudo -u www-data php /var/www/nextcloud/occ maintenance:mode --on >> $logpath
echo "$(date) stopping syncthing" >> $logpath
systemctl stop syncthing >> $logpath
systemctl stop dietpi-dashboard-frontend >> $logpath
systemctl stop dietpi-dashboard-backend >> $logpath


### handle syncthing certs
# backup existing
echo "$(date) mkdir -p $syncthing_dir/bak" >> $logpath
mkdir -p $syncthing_dir/bak
echo "$(date) mv syncthing/*.pem $syncthing_dir/bak/" >> $logpath
mv $syncthing_dir/https-cert.pem $syncthing_dir/bak/https-cert.pem
mv $syncthing_dir/https-key.pem $syncthing_dir/bak/https-key.pem

# copy new cert
chown -R dietpi:dietpi $syncthing_dir
echo "$(date) cp fullchain.pem -> https-cert.pem" >> $logpath
cp -f $le_dir/$dns_name/fullchain.pem $syncthing_dir/https-cert.pem
echo "$(date) cp privkey.pem -> https-key.pem" >> $logpath
cp -f $le_dir/$dns_name/privkey.pem $syncthing_dir/https-key.pem

# set permissions
echo "$(date) chown and chmod $syncthing_dir" >> $logpath
chown syncthing:dietpi -R $syncthing_dir
chmod u=rwX,g=rwX,o=r $syncthing_dir


### handle dietpi-dashboard certs
# backup existing
echo "$(date) mkdir -p $dietpi_dashboard_dir/bak" >> $logpath
mkdir -p $dietpi_dashboard_dir/bak
echo "$(date) mv dietpi-dashboard/*.pem $dietpi_dashboard_dir/bak/" >> $logpath
mv $dietpi_dashboard_dir/privkey.pem $dietpi_dashboard_dir/bak/privkey.pem
mv $dietpi_dashboard_dir/cert.pem $dietpi_dashboard_dir/bak/cert.pem

# copy new cert
echo "$(date) cp fullchain.pem -> cert.pem" >> $logpath
cp -f $le_dir/$dns_name/fullchain.pem $dietpi_dashboard_dir/cert.pem
chown dietpi-dashboard-frontend:root $dietpi_dashboard_dir/cert.pem
chmod u=rwX,g=rwX,o=r $dietpi_dashboard_dir/cert.pem
echo "$(date) cp privkey.pem -> privkey.pem" >> $logpath
cp -f $le_dir/$dns_name/privkey.pem $dietpi_dashboard_dir/privkey.pem
chown dietpi-dashboard-frontend:root $dietpi_dashboard_dir/privkey.pem
chmod u=rwX,g=rwX,o=r $dietpi_dashboard_dir/privkey.pem


### put new WAN IP address into whitelist
MYIP=$(curl -s ipinfo.io/ip | grep -Eo '^([0-9]{1,3}\.){3}[0-9]{1,3}$')
echo "$(date) Logging WAN IP ($MYIP) to '$whitelistpath'" >> $logpath
echo "### WAN IP address. Updated from letsencrypt deployhook." > $whitelistpath
echo "$(date) $MYIP" >> $whitelistpath


### restart services
echo "$(date) restarting syncthing" >> $logpath
/usr/local/bin/scripts/start-if-enabled.sh syncthing >> $logpath
echo "$(date) restarting dietpi-dashboard" >> $logpath
/usr/local/bin/scripts/start-if-enabled.sh dietpi-dashboard-frontend >> $logpath
/usr/local/bin/scripts/start-if-enabled.sh dietpi-dashboard-backend >> $logpath
# echo "$(date) nextcloud restarting" >> $logpath
# sudo -u www-data php /var/www/nextcloud/occ maintenance:mode --off >> $logpath


# lighttpd has its own deployhook
# dietpi-services start lighttpd
# service lighttpd force-reload
