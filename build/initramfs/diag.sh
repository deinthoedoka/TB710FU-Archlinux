#!/bin/busybox sh
# diagnostic shell (USB Ethernet telnet), entered by /init when no root fs is usable.
# Nothing is written to any partition here.
echo; echo "===== TB710FU Arch Linux diagnostic (kShimC) ====="; uname -a; cat /proc/cmdline; free -m
echo "--- fb:"; cat /proc/fb; echo "--- udc:"; ls /sys/class/udc
echo "--- partitions:"
for b in /sys/class/block/sd*; do
  p=$(grep -m1 '^PARTNAME=' $b/uevent 2>/dev/null); [ -n "$p" ] && echo "  /dev/$(basename $b)  ${p#PARTNAME=}"
done
mount -t debugfs none /sys/kernel/debug 2>/dev/null
. /usb-net.sh
if usb_net_up TB710FU-diag; then
  usb_net_dhcp
  telnetd -l /bin/sh
  echo "USB Ethernet up on $NETIF: telnet 172.16.42.1 (UDC $UDC)"
  echo "Windows hosts land on RNDIS here. If the host got 169.254.x instead of a DHCP lease,"
  echo "set a static 172.16.42.2/255.255.255.0 on that adapter, then telnet 172.16.42.1."
else
  echo "no UDC -- deferred devices:"
  cat /sys/kernel/debug/devices_deferred 2>/dev/null | cut -c1-150
  echo "-- usb/dwc/phy/glink dmesg:"
  dmesg | grep -i -E "dwc3|usb|eusb|phy|glink|repeater|spmi" | tail -25 | cut -c1-150
fi
echo "auto reboot in 600 s (touch /tmp/stay to keep running)"
i=0
while [ $i -lt 120 ]; do sleep 5; i=$((i+1)); [ -f /tmp/stay ] && i=0; done
echo "rebooting"; sync; reboot -f
