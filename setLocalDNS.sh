#!/bin/bash
##
# kylecui: In Ubuntu, systemd.resolve is charge of DNS resolution 
# and it uses /run/systemd/resolve/stub-resolv.conf as the DNS configuration file which is linked to /etc/resolv.conf.
# So what we need to do includes:
# 1. modify /etc/systemd/resolved.conf to set the DNS servers.
# 2. backup /etc/resolv.conf (disconnect the link from /run/systemd/resolve/stub-resolv.conf) and link /run/systemd/resolve/resolv.conf to /etc/resolv.conf.
# 3. restart systemd-resolved service.
##

if ! [ $(id -u) = 0 ]; then
   echo "The script need to be run as root." >&2
   exit 1
fi
echo "DNS=10.96.0.10 8.8.8.8 114.114.114.114" >> /etc/systemd/resolved.conf
resolv_conf_bak="/etc/resolv.conf.bak"
if [ -e "${resolv_conf_bak}" ]; then
  rm -f "${resolv_conf_bak}"
fi
mv /etc/resolv.conf /etc/resolv.conf.bak
ln -s /run/systemd/resolve/resolv.conf /etc/
systemctl restart systemd-resolved
