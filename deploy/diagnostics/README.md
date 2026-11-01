# Diagnostics

Not installed by `deploy_all.sh`. Use these when a boot ends on a black screen or the
panel never leaves DPMS off.

- `tb-display-watch` + `tb-display-watch.service`: logs backlight, DPMS and compositor
  frame counters to `/run/tb-display-watch.log` for 30 minutes after boot. Enable with
  `install -m755 tb-display-watch /usr/local/sbin/ && install -m644
  tb-display-watch.service /etc/systemd/system/ && systemctl enable --now
  tb-display-watch`.
- `collect_device_inventory.sh`: read-only dump of packages, services and non-stock files
  (no secrets) — useful when filling in a support request.
- `dump_device_configs.sh`: prints the config files this port installs, so you can compare
  a working device against a broken one.
