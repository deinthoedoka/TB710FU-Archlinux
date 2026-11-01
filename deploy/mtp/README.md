# MTP over the USB cable (uMTP-Responder + FunctionFS)

Plugging the tablet into a PC exposes `/home/alarm` as an MTP device (r/w as the
`alarm` user). The MTP function rides in the **same USB gadget** as the NCM
network (configfs can't be changed while the UDC is bound, so `tb-usb-ncm` adds
`ffs.mtp` before binding; on stock-v1.0 installs `install_mtp.sh` patches it in).

```bash
./deploy_mtp.sh <tablet-ip> /path/to/uMTP-Responder.tar.gz   # builds umtprd on the tablet
```

Source: <https://github.com/viveris/uMTP-Responder> (plain `make`, no extra deps).

Files installed: `/usr/local/bin/umtprd`, `/usr/local/sbin/tb-mtp-gadget` (gadget
prep before UDC bind), `/etc/umtprd/umtprd.conf`, `tb-mtp.service`.

## Notes

- `loop_on_disconnect 0x1`: unplug/replug keeps working without a daemon restart
  (the value is parsed as **hex**, `1` alone is not enough).
- Windows shows the device name from `product` in the conf; Explorer caches the
  old name per device instance — replug (or reboot the PC) refreshes it.
- Battery percentage is reported to the PC from the `battery` supply.
