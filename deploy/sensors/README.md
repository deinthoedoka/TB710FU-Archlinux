# Sensor stack (ALS / accelerometer)

The ADSP exposes sensors through FastRPC. Two pieces are needed:

1. **hexagonrpcd** — a userspace daemon that speaks the FastRPC ioctl protocol to
   `/dev/fastrpc-adsp` and serves the sensor PD. Source is in `third_party/hexagonrpc/`
   (upstream `linux-msm/hexagonrpc`, with the local method-36 addition used by this port).
   Build with `install_sensors.sh`; it needs `meson`, `ninja` and a C compiler.
2. **Sensor configuration** — the ADSP looks for `sns_reg.conf` / `sns_reg_config` and
   `sensors_list.txt` under `/usr/share/qcom/sm8650/LENOVO/tb710fu/sensors/`. The copies in
   `third_party/qcom-sensors/` come from this port's reference device. If auto-brightness
   sees no lux, copy the same files from your own device (`/vendor/etc/sensors/` over adb
   root). The `registry/` subdirectory (per-unit factory calibration) is **not** shipped —
   the DSP creates it at runtime.

After that, `iio-sensor-proxy` (installed by the desktop step) provides the ambient light
sensor on D-Bus, and `deploy/als/` consumes it.

Check:

    systemctl status hexagonrpcd-adsp-sensorspd
    monitor-sensor            # should list the light sensor and print lux

The kernel side needs `CONFIG_QCOM_FASTRPC` and the `fastrpc` node (both in the provided
kernel config/build).
