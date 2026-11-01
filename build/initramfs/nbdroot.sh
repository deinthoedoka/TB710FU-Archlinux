#!/bin/busybox sh
# TB710FU Arch: root = partition 2 of an NBD disk served by the host over the USB link
# (nbd_server.py on Windows, or `nbd-server` on Linux), port 10809.
#
# The client is /nbdclient (work/nbdclient.c), not busybox's nbd-client applet: that applet
# reads only 2 bytes of the 4-byte newstyle greeting flags, leaving 2 bytes in the receive
# queue. Everything after that is shifted - the export reply parses as a 1.5 TiB disk and the
# kernel rejects the first reply with "Wrong magic (0x6744)".
#
# export name "arch" is tried first, then "steamos" (the same kernel/initramfs is shared with
# the SteamOS payload, so an old image still boots).
# -b 512 kept: the image has a 512-byte-sector MBR, and busybox nbd-client defaults to 4096.
. /usb-net.sh
usb_net_up TB710FU-arch || { echo "nbdroot: no USB Ethernet link"; exit 1; }
usb_net_dhcp
echo "nbdroot: $NETIF up on 172.16.42.1, waiting for the host NBD server (172.16.42.x:10809)"

HOST=""
EXPORT=""
i=0
while [ $i -lt 180 ]; do
  # carrier stuck (seen on this board): rebind the UDC periodically
  if [ $((i % 20)) = 19 ] && [ "$(cat /sys/class/net/$NETIF/carrier 2>/dev/null)" != 1 ]; then
    echo "" > /sys/kernel/config/usb_gadget/g1/UDC; sleep 1
    echo "$UDC" > /sys/kernel/config/usb_gadget/g1/UDC; sleep 2
    ifconfig $NETIF 172.16.42.1 up
  fi
  # the host address comes from our own udhcpd (it may land on .2 .. .10, or keep an old lease)
  for h in 2 3 4 5 6 7 8 9 10; do
    nc -w 1 172.16.42.$h 10809 </dev/null 2>/dev/null | grep -q NBDMAGIC || continue
    for name in arch steamos; do
      echo "nbdroot: trying $name from 172.16.42.$h"
      rm -f /tmp/nbdclient.log
      /nbdclient 172.16.42.$h 10809 $name /dev/nbd0 512 >/tmp/nbdclient.log 2>&1 &
      n=0
      while [ $n -lt 15 ]; do
        sleep 1; n=$((n+1))
        grep -q READY /tmp/nbdclient.log && break
      done
      if grep -q READY /tmp/nbdclient.log; then
        HOST=172.16.42.$h
        EXPORT=$name
        break 3
      fi
      echo "nbdroot: $name from $h failed:"
      cat /tmp/nbdclient.log
    done
  done
  sleep 1; i=$((i+1))
done
[ -n "$HOST" ] || { echo "nbdroot: no NBD host answered in time"; exit 1; }
echo "nbdroot: $EXPORT disk from $HOST (after ${i}s)"

# the client asked the kernel for a partition scan, but be explicit about it
[ -b /dev/nbd0p2 ] || { sleep 1; blockdev --rereadpt /dev/nbd0 2>/dev/null; sleep 1; }
ls /dev/nbd0* 2>/dev/null
mkdir -p /newroot
mount -t ext4 -o rw,noatime /dev/nbd0p2 /newroot && [ -x /newroot/sbin/init ] || {
  echo "nbdroot: mount failed"; exit 1; }
echo "nbdroot: root on /dev/nbd0p2 (export $EXPORT) from $HOST"
exit 0
