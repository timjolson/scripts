#!/bin/bash
logpath=/var/log/certbot-renew.log
echo "$(date) renewing certs DEPLOY-HOOK" >> $logpath

le_dir="/etc/letsencrypt/live"
dns_name="awyw.crabdance.com"
syncthing_dir="/mnt/dietpi_userdata/syncthing"
qbt_dir="/mnt/dietpi_userdata/downloads"
emby_dir="/mnt/dietpi_userdata/emby"
whitelistpath="/var/log/whitelist.log"

### stop running services
# echo "$(date) stopping nextcloud" >> $logpath
# sudo -u www-data php /var/www/nextcloud/occ maintenance:mode --on >> $logpath
echo "$(date) stopping syncthing" >> $logpath
systemctl stop syncthing >> $logpath
echo "$(date) stopping emby-server" >> $logpath
systemctl stop emby-server >> $logpath



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




## handle qbt certs
# backup existing
echo "$(date) mkdir -p $qbt_dir/bak" >> $logpath
mkdir -p $qbt_dir/bak
echo "$(date) mv /mnt/dietpi_userdata/downloads/*.pem $qbt_dir/bak/" >> $logpath
mv $qbt_dir/https-cert.pem $qbt_dir/bak/https-cert.pem
mv $qbt_dir/https-key.pem $qbt_dir/bak/https-key.pem

# copy new cert
echo "$(date) cp fullchain.pem -> https-cert.pem" >> $logpath
cp -f $le_dir/$dns_name/fullchain.pem $qbt_dir/https-cert.pem
echo "$(date) cp privkey.pem -> https-key.pem" >> $logpath
cp -f $le_dir/$dns_name/privkey.pem $qbt_dir/https-key.pem

# set permissions
echo "$(date) chown and chmod $qbt_dir" >> $logpath
chown www-data:www-data -R $qbt_dir
chmod u=rwX,g=rwX,o=r $qbt_dir




### handle emby cert
# backup existing
echo "$(date) mkdir -p $emby_dir/bak" >> $logpath
mkdir -p $emby_dir/bak
chown -R emby:dietpi $emby_dir/bak
echo "$(date) mv emby/*.pfx $emby_dir/bak/" >> $logpath
mv $emby_dir/*.pfx $emby_dir/bak/
echo "$(date) openssl convert to pkcs12" >> $logpath
# openssl pkcs12 -export -out $emby_dir/$dns_name.pfx -inkey $le_dir/$dns_name/privkey.pem -in $le_dir/$dns_name/cert.pem -certfile $le_dir/$dns_name/fullchain.pem -name $dns_name -passout pass:certpass
# openssl pkcs12 -export -out $emby_dir/$dns_name.pfx -inkey $le_dir/$dns_name/privkey.pem -in $le_dir/$dns_name/cert.pem -certfile $le_dir/$dns_name/chain.pem -certfile $le_dir/$dns_name/fullchain.pem -name $dns_name -passout pass:certpass
# openssl pkcs12 -export -out $emby_dir/$dns_name.pfx -inkey $le_dir/$dns_name/privkey.pem -in $le_dir/$dns_name/cert.pem -certfile $le_dir/$dns_name/chain.pem -certfile $le_dir/$dns_name/fullchain.pem -name $dns_name -passout pass:certpass
openssl pkcs12 -export -out $emby_dir/$dns_name.pfx -inkey $le_dir/$dns_name/privkey.pem -in $le_dir/$dns_name/cert.pem -certfile $le_dir/$dns_name/chain.pem -passout pass:certpass
echo "$(date) chown emby:dietpi" >> $logpath
chown emby:dietpi $emby_dir/$dns_name.pfx
chmod u=rwx,g+rwx,o=r $emby_dir/$dns_name.pfx

### put new WAN IP address into whitelist
MYIP=$(curl -s ipinfo.io/ip | grep -Eo '^([0-9]{1,3}\.){3}[0-9]{1,3}$')
echo "$(date) Logging WAN IP ($MYIP) to '$whitelistpath'" >> $logpath
echo "### WAN IP address. Updated from letsencrypt deployhook." > $whitelistpath
echo "$(date) $MYIP" >> $whitelistpath

### restart services
echo "$(date) restarting syncthing" >> $logpath
systemctl restart syncthing >> $logpath

# echo "$(date) nextcloud restarting" >> $logpath
# sudo -u www-data php /var/www/nextcloud/occ maintenance:mode --off >> $logpath

echo "$(date) emby-server restarting" >> $logpath
systemctl restart emby-server >> $logpath

# lighttpd has its own deployhook
# dietpi-services start lighttpd
# service lighttpd force-reload
