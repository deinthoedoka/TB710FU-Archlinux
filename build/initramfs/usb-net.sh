#!/bin/busybox sh
# TB710FU Arch initramfs: bring up a USB device-mode Ethernet link and wait for a host.
# Sourced by /init (NBD root) and /diag.sh (telnet). Sets $NETIF to the interface name.
#
# NCM first (Linux/macOS hosts bind it natively). Windows has no NCM class driver, so if
# NCM gets no carrier we rebind the gadget as RNDIS, which Windows does drive. Everything
# here must survive switch_root: the Arch rootfs keeps the iface unmanaged by NetworkManager
# (etc/NetworkManager/conf.d/90-tb710fu-usb0.conf) and runs its own gadget service later.
G=/sys/kernel/config/usb_gadget/g1
NETIF=""

udc_wait() {
  n=0; while [ $n -lt 30 ] && [ -z "$(ls /sys/class/udc 2>/dev/null)" ]; do sleep 1; n=$((n+1)); done
  # dual-role USB: pmic-glink/UCSI is a rootfs module, so force the device role here
  for r in /sys/class/usb_role/*/role; do [ -e "$r" ] && echo device > "$r" 2>/dev/null; done
  UDC=$(ls /sys/class/udc 2>/dev/null | head -1)
  echo "usb-net: udc after ${n}s: $UDC"
}

# $1 = function name (ncm.usb0 | rndis.usb0), $2 = config name, $3 = product string
gadget_try() {
  echo "" > $G/UDC 2>/dev/null; sleep 1
  rm -f $G/configs/c.1/* 2>/dev/null
  mkdir -p $G/strings/0x409 $G/configs/c.1/strings/0x409
  echo 0x1d6b > $G/idVendor; echo 0x0104 > $G/idProduct
  echo "$3" > $G/strings/0x409/product; echo tb710fu > $G/strings/0x409/serialnumber
  mkdir -p $G/functions/$1
  echo "$2" > $G/configs/c.1/strings/0x409/configuration
  ln -s $G/functions/$1 $G/configs/c.1/ 2>/dev/null
  echo $UDC > $G/UDC 2>/dev/null || return 1
  sleep 2
  return 0
}

# RNDIS needs the interface name the kernel picks (rndis0), which appears only after UDC bind
find_rndis() {
  n=0; while [ $n -lt 15 ]; do
    for i in /sys/class/net/*; do case "$(basename $i)" in rndis[0-9]*) echo "$(basename $i)"; return 0;; esac; done
    sleep 1; n=$((n+1))
  done
  return 1
}

# $1 = product string. Leaves $NETIF set, iface at 172.16.42.1 with a DHCP range for the host.
usb_net_up() {
  mount -t configfs none /sys/kernel/config 2>/dev/null
  udc_wait
  [ -n "$UDC" ] || return 1

  if gadget_try ncm.usb0 ncm "$1-ncm"; then
    if ifconfig usb0 172.16.42.1 netmask 255.255.255.0 up 2>/dev/null; then
      NETIF=usb0
      # carrier stuck is a known DWC3/NCM failure here: give it a couple of tries before RNDIS
      i=0; while [ $i -lt 3 ]; do
        [ "$(cat /sys/class/net/usb0/carrier 2>/dev/null)" = 1 ] && break
        echo "" > $G/UDC; sleep 1; echo $UDC > $G/UDC; sleep 2
        ifconfig usb0 172.16.42.1 up 2>/dev/null; i=$((i+1))
      done
      [ "$(cat /sys/class/net/usb0/carrier 2>/dev/null)" = 1 ] && return 0
      echo "usb-net: NCM has no carrier (Windows has no NCM driver) -> retrying as RNDIS"
    fi
  fi

  if gadget_try rndis.usb0 rndis "$1-rndis"; then
    NETIF=$(find_rndis)
    [ -n "$NETIF" ] || { echo "usb-net: no rndis interface"; NETIF=""; return 1; }
    ifconfig $NETIF 172.16.42.1 netmask 255.255.255.0 up 2>/dev/null
    return 0
  fi
  NETIF=""; return 1
}

# DHCP so the host gets 172.16.42.2-.10 automatically. Windows does run DHCP on RNDIS;
# if the host ends up on 169.254.x instead, set a static 172.16.42.2 on it manually.
usb_net_dhcp() {
  [ -n "$NETIF" ] || return 1
  mkdir -p /run/udhcpd
  printf 'start 172.16.42.2\nend 172.16.42.10\ninterface %s\noption subnet 255.255.255.0\noption router 172.16.42.1\nlease_file /run/udhcpd/leases\n' "$NETIF" > /run/udhcpd/conf
  touch /run/udhcpd/leases
  udhcpd /run/udhcpd/conf 2>/dev/null
}
