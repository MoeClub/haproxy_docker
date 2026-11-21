#!/bin/sh
set -e

hapVer="${1:-3.4.8}"
dnsVer="${2:-2.93}"

apk add --no-cache wget tzdata iproute2 openssl iptables iptables-legacy
cp -rf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime

sh /mnt/update.sh "${hapVer}" "${dnsVer}"

mkdir -p /etc/haproxy /var/run
[ -f /mnt/haproxy.cfg ]        && cp -rf /mnt/haproxy.cfg /etc/haproxy/haproxy.cfg
[ -f /mnt/haproxy-tproxy.cfg ] && cp -rf /mnt/haproxy-tproxy.cfg /etc/haproxy/haproxy-tproxy.cfg
[ -f /mnt/haproxy.map ]        && cp -rf /mnt/haproxy.map /etc/haproxy/haproxy.map
[ -f /mnt/dnsmasq.conf ]       && cp -rf /mnt/dnsmasq.conf /etc/haproxy/dnsmasq.conf
[ -f /mnt/run.sh ]             && cp -rf /mnt/run.sh /run.sh

chmod -R 755 /etc/haproxy /run.sh

haproxy -c -f /etc/haproxy/haproxy.cfg
haproxy -c -f /etc/haproxy/haproxy-tproxy.cfg
dnsmasq --test -C /etc/haproxy/dnsmasq.conf

find /var -type f -delete
echo > "${HOME}/.ash_history"
