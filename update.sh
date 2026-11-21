#!/bin/sh
set -e

hVer="${1:-0}"
dVer="${2:-0}"
EndPoint="${ENDPOINT:-https://github.com/MoeClub/Note/raw/refs/heads/master/AnyConnect/build}"

case "$(uname -m)" in
  aarch64|arm64) arch="aarch64" ;;
  x86_64|amd64)  arch="x86_64" ;;
  *)             arch="" ;;
esac
[ -n "${arch}" ] || exit 1

trapFile=""
cleanup() {
  [ -z "${trapFile}" ] || rm -rf ${trapFile}
}
trap cleanup EXIT

if [ "${hVer}" != "0" ]; then
  hapName="haproxy_${arch}_v${hVer}.tar.gz"
  if [ -f "/mnt/${hapName}" ]; then
    hapFile="/mnt/${hapName}"
  elif [ -f "./${hapName}" ]; then
    hapFile="./${hapName}"
  else
    hapFile="./${hapName}"
    trapFile="${trapFile} ${hapFile}"
    wget --no-check-certificate -qO "${hapFile}" "${EndPoint}/${hapName}"
  fi

  rm -rf /usr/sbin/haproxy
  tar --overwrite -xzvf "${hapFile}" -C /
  haproxy -v
fi

if [ "${dVer}" != "0" ]; then
  dnsName="dnsmasq_${arch}_v${dVer}.tar.gz"
  if [ -f "/mnt/${dnsName}" ]; then
    dnsFile="/mnt/${dnsName}"
  elif [ -f "./${dnsName}" ]; then
    dnsFile="./${dnsName}"
  else
    dnsFile="./${dnsName}"
    trapFile="${trapFile} ${dnsFile}"
    wget --no-check-certificate -qO "${dnsFile}" "${EndPoint}/${dnsName}"
  fi

  rm -rf /usr/sbin/dnsmasq
  rm -rf /usr/share/man/man8/dnsmasq.8
  tar --overwrite -xzvf "${dnsFile}" -C /
  dnsmasq -v
fi
