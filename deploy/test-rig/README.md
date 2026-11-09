# Tablet test rig — uinput injectors

Sources of the virtual input devices used to verify the r25/r26 builds without
physical fingers. The compiled aarch64 binaries live on the tablet at
`/root/tb_touch` and `/root/tb_key`.

- `tb_touch.c` — multitouch (ABS_MT) injector: `down/move/up/tap/sleep`
- `tb_key.c` — keyboard injector: `key NAME`, `combo ctrl+l`, `type TEXT`, `sleep MS`

Compile on the tablet (or cross):

```sh
cc -O2 -o tb_touch tb_touch.c
cc -O2 -o tb_key tb_key.c
```

Feed commands on stdin; coordinates are the 1600x1000 logical space.
