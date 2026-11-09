#!/usr/bin/env python3
"""TB710FU 环境光自动亮度守护（GNOME 51，用户会话服务）。

设计目标和 KDE 版一致：
  * 读数先在对数域做低通，抑制传感器噪声；
  * 用对数 lux 曲线把光照映射到亮度百分比；
  * 目标值本身再做一次指数逼近，让任何幅度变化都是「匀速观感」的小步，
    不会出现一步跳过去的那种突兀过渡；
  * 手动拨亮度时把这个光照下的偏好学下来，之后按曲线 + 偏移输出。

GNOME 侧的执行器和上游一致：调用 gnome-shell 的
org.gnome.Shell.Brightness.SetAutoBrightnessTarget()，由 shell 自己写背光。
shell 的语义是 target = clamp(auto_target + scale - 0.5)，其中 scale 是
「用户亮度」。所以这里不直接下发绝对亮度，而是做闭环：每次读取真实背光，
把 auto_target 往「曲线值 - 实测值」的方向推一点，直到实测等于曲线值。
这样无论 shell 的 scale 怎么变，收敛点都是我们的曲线值。
"""

import json
import math
import os
import signal
import sys
import time

import gi

gi.require_version('Gio', '2.0')
gi.require_version('GLib', '2.0')

from gi.repository import Gio, GLib

SENSOR_NAME = 'net.hadess.SensorProxy'
SENSOR_PATH = '/net/hadess/SensorProxy'
SENSOR_IFACE = 'net.hadess.SensorProxy'

SHELL_NAME = 'org.gnome.Shell.Brightness'
SHELL_PATH = '/org/gnome/Shell/Brightness'
SHELL_IFACE = 'org.gnome.Shell.Brightness'

POWER_SCHEMA = 'org.gnome.settings-daemon.plugins.power'
BACKLIGHT = '/sys/class/backlight/sy7758-backlight'
PROFILE_PATH = os.path.expanduser('~/.config/tb-als-profile.json')

# 曲线锚点：(log10(lux), 亮度比例 0..1)，按对数光照线性插值。
# 0.05 lx 以下给 4%，室内 100 lx 左右 33%，阳光直射 4 万 lx 给满。
CURVE = (
    (-1.30, 0.04),
    (0.00, 0.06),
    (0.50, 0.09),
    (1.00, 0.14),
    (1.50, 0.21),
    (2.00, 0.32),
    (2.50, 0.45),
    (3.00, 0.62),
    (3.50, 0.78),
    (4.00, 0.92),
    (4.60, 1.00),
)

TICK_MS = 200                  # 控制周期
SENSOR_POLL_S = 0.4            # 传感器读取周期
LUX_TAU_S = 1.2                # 对数域 EMA 时间常数
RAMP_TAU_S = 0.55              # 目标值指数逼近时间常数
TARGET_DEADBAND = 0.010        # 目标变化小于 1% 不动（防抖）
LOOP_GAIN = 0.35               # 闭环增益（每次朝曲线值靠近的比例）
LOOP_DEADBAND = 0.004          # 实测与目标差小于 0.4% 就不动
IDLE_PAUSE_MS = 20000          # 空闲超过 20s 暂停（熄屏/调暗期间不抢亮度）

# 手动学习：与 tb-als KDE 版一致，14 个锚点，覆盖 -1.5..5.0 log10 lux。
PROFILE_X0 = -1.5
PROFILE_STEP = 0.5
PROFILE_N = 14
PROFILE_MAX_OFFSET = 0.70


def log10(x):
    return math.log10(max(x, 1e-3))


def curve(lux):
    value = log10(max(lux, 0.05))
    if value <= CURVE[0][0]:
        return CURVE[0][1]
    for (x0, y0), (x1, y1) in zip(CURVE, CURVE[1:]):
        if value <= x1:
            return y0 + (y1 - y0) * (value - x0) / (x1 - x0)
    return CURVE[-1][1]


def profile_default():
    return {'version': 2, 'offsets': [0.0] * PROFILE_N, 'updated': 0}


def profile_pos(lux):
    value = min(max(log10(max(lux, 0.05)), PROFILE_X0),
                PROFILE_X0 + PROFILE_STEP * (PROFILE_N - 1))
    return (value - PROFILE_X0) / PROFILE_STEP


def interp_offsets(offsets, pos):
    index = min(int(pos), PROFILE_N - 2)
    frac = pos - index
    return offsets[index] * (1.0 - frac) + offsets[index + 1] * frac


def load_profile():
    profile = profile_default()
    try:
        with open(PROFILE_PATH) as handle:
            data = json.load(handle)
        offsets = data.get('offsets')
        if isinstance(offsets, list) and len(offsets) == PROFILE_N:
            profile['offsets'] = [
                max(-PROFILE_MAX_OFFSET, min(PROFILE_MAX_OFFSET, float(v)))
                for v in offsets
            ]
            profile['updated'] = int(data.get('updated', 0))
    except (OSError, ValueError, TypeError):
        pass
    return profile


def save_profile(profile):
    profile['updated'] = int(time.time())
    try:
        tmp = PROFILE_PATH + '.tmp'
        with open(tmp, 'w') as handle:
            json.dump(profile, handle)
        os.replace(tmp, PROFILE_PATH)
    except OSError as error:
        print('tb-als: 保存亮度学习数据失败: %s' % error, flush=True)


def learn_profile(profile, lux, value):
    """把「这个光照下用户想要 value」写进锚点，插值后正好命中用户设定。"""
    pos = profile_pos(lux)
    delta = value - curve(lux)
    index = min(int(pos), PROFILE_N - 2)
    frac = pos - index
    offsets = list(profile['offsets'])

    for j in range(max(0, index - 2), min(PROFILE_N, index + 4)):
        distance = abs(j - pos)
        if distance < 0.75:
            rate = 0.55
        elif distance < 1.75:
            rate = 0.30
        elif distance < 2.5:
            rate = 0.12
        else:
            continue
        offsets[j] += (delta - offsets[j]) * rate

    residual = delta - interp_offsets(offsets, pos)
    denom = (1.0 - frac) ** 2 + frac ** 2
    if denom > 0.01:
        offsets[index] += residual * (1.0 - frac) / denom
        offsets[index + 1] += residual * frac / denom

    profile['offsets'] = [
        max(-PROFILE_MAX_OFFSET, min(PROFILE_MAX_OFFSET, item)) for item in offsets
    ]


def target_value(lux, profile):
    value = curve(lux) + interp_offsets(profile['offsets'], profile_pos(lux))
    return min(1.0, max(0.0, value))


def read_int(path):
    try:
        with open(path) as handle:
            return int(handle.read().strip())
    except (OSError, ValueError):
        return None


class Daemon:
    def __init__(self):
        self.running = True
        self.profile = load_profile()
        self.backlight = os.path.join(BACKLIGHT, 'brightness')
        self.maximum = read_int(os.path.join(BACKLIGHT, 'max_brightness')) or 4080

        self.sensor = Gio.DBusProxy.new_for_bus_sync(
            Gio.BusType.SYSTEM, Gio.DBusProxyFlags.NONE, None,
            SENSOR_NAME, SENSOR_PATH, SENSOR_IFACE, None)
        self.shell = Gio.DBusProxy.new_for_bus_sync(
            Gio.BusType.SESSION, Gio.DBusProxyFlags.NONE, None,
            SHELL_NAME, SHELL_PATH, SHELL_IFACE, None)
        self.idle = Gio.DBusProxy.new_for_bus_sync(
            Gio.BusType.SESSION, Gio.DBusProxyFlags.NONE, None,
            'org.gnome.Mutter.IdleMonitor', '/org/gnome/Mutter/IdleMonitor/Core',
            'org.gnome.Mutter.IdleMonitor', None)

        self.settings = Gio.Settings.new(POWER_SCHEMA)
        self.settings.connect('changed::ambient-enabled', self.on_enabled_changed)
        self.shell.connect('g-signal', self.on_shell_signal)

        self.enabled = self.settings.get_boolean('ambient-enabled')
        self.lux_ema = None
        self.last_sensor = 0.0
        self.ramped = None
        self.auto_target = 0.5
        self.last_set = 0.0
        self.user_value = None      # 检测到手动调整后的待学习值
        self.user_since = 0.0
        self.last_tick = time.monotonic()
        self.paused = False
        self.manual_until = 0.0
        print('tb-als: starting (gnome), enabled=%s max=%d'
              % (self.enabled, self.maximum), flush=True)

    # ---- helpers -----------------------------------------------------
    def read_brightness(self):
        value = read_int(self.backlight)
        return value

    def actual(self):
        value = self.read_brightness()
        if value is None:
            return None
        return max(0.0, min(1.0, value / float(self.maximum)))

    def read_lux(self):
        try:
            value = self.sensor.get_cached_property('LightLevel')
            if value is not None:
                lux = value.unpack()
                if isinstance(lux, (int, float)) and lux > 0:
                    return float(lux)
        except Exception:
            pass
        return None

    def idle_ms(self):
        try:
            result = self.idle.call_sync('GetIdletime', None,
                                         Gio.DBusCallFlags.NONE, 500, None)
            return int(result.unpack()[0])
        except Exception:
            return 0

    def set_auto_target(self, value):
        self.auto_target = max(0.0, min(1.0, value))
        try:
            self.shell.call_sync('SetAutoBrightnessTarget',
                                 GLib.Variant('(d)', (self.auto_target,)),
                                 Gio.DBusCallFlags.NONE, 500, None)
            return True
        except Exception as error:
            print('tb-als: 设置自动亮度目标失败: %s' % error, flush=True)
            return False

    # ---- events ------------------------------------------------------
    def on_enabled_changed(self, settings, key):
        self.enabled = settings.get_boolean(key)
        print('tb-als: ambient-enabled=%s' % self.enabled, flush=True)
        if not self.enabled:
            # 交还给用户 scale：-1 是 shell 的「自动亮度关闭」哨兵。
            try:
                self.shell.call_sync('SetAutoBrightnessTarget',
                                     GLib.Variant('(d)', (-1.0,)),
                                     Gio.DBusCallFlags.NONE, 500, None)
            except Exception:
                pass
            self.ramped = None
        else:
            self.ramped = self.actual()

    def on_shell_signal(self, proxy, sender, signal, params):
        if signal != 'BrightnessChanged':
            return
        actual = self.actual()
        if actual is None:
            return
        # 用户拨了亮度：先记下来，稳定 0.7s 后再学习，避免拖动过程中反复写。
        self.user_value = actual
        self.user_since = time.monotonic()

    # ---- main loop ---------------------------------------------------
    def tick(self):
        now = time.monotonic()
        dt = max(0.001, min(1.0, now - self.last_tick))
        self.last_tick = now

        if not self.running:
            return False

        if not self.enabled:
            self.ramped = None
            return True

        if now - self.last_sensor >= SENSOR_POLL_S:
            self.last_sensor = now
            lux = self.read_lux()
            if lux is not None:
                value = log10(lux)
                if self.lux_ema is None:
                    self.lux_ema = value
                else:
                    alpha = 1.0 - math.exp(-SENSOR_POLL_S / LUX_TAU_S)
                    self.lux_ema += alpha * (value - self.lux_ema)

        if self.lux_ema is None:
            return True

        lux = 10.0 ** self.lux_ema
        actual = self.actual()
        if actual is None:
            return True

        # 用户手动调整：稳定 0.7s 后学习，然后按学习值继续。
        if self.user_value is not None and now - self.user_since >= 0.7:
            learned = self.user_value
            self.user_value = None
            learn_profile(self.profile, lux, learned)
            save_profile(self.profile)
            print('tb-als: 学习 %.1f lx -> %.1f%%（偏移 %+.1f%%）'
                  % (lux, learned * 100.0,
                     interp_offsets(self.profile['offsets'],
                                    profile_pos(lux)) * 100.0), flush=True)
            self.ramped = learned

        if self.user_value is not None:
            return True

        desired = target_value(lux, self.profile)
        if self.ramped is None:
            self.ramped = actual

        # 目标值指数逼近：任何一步都是不超过 15% 剩余差的小步。
        step = (desired - self.ramped) * (1.0 - math.exp(-dt / RAMP_TAU_S))
        if abs(desired - self.ramped) <= TARGET_DEADBAND:
            step = 0.0
        self.ramped += step

        # 空闲/熄屏调暗期间不抢亮度。
        if self.idle_ms() > IDLE_PAUSE_MS:
            return True

        error = self.ramped - actual
        if abs(error) < LOOP_DEADBAND:
            return True

        self.set_auto_target(self.auto_target + error * LOOP_GAIN)
        return True

    def stop(self, *_args):
        self.running = False
        if self.enabled:
            try:
                self.shell.call_sync('SetAutoBrightnessTarget',
                                     GLib.Variant('(d)', (-1.0,)),
                                     Gio.DBusCallFlags.NONE, 500, None)
            except Exception:
                pass
        print('tb-als: stopped', flush=True)


def main():
    if '--simulate' in sys.argv[1:]:
        profile = load_profile()
        for lux in (0.1, 1, 5, 10, 30, 100, 200, 500, 1000, 5000, 20000, 50000):
            print('%9.1f lx -> %5.1f%%' % (lux, target_value(lux, profile) * 100))
        return 0

    daemon = Daemon()
    signal.signal(signal.SIGTERM, daemon.stop)
    signal.signal(signal.SIGINT, daemon.stop)
    GLib.timeout_add(TICK_MS, daemon.tick)
    loop = GLib.MainLoop()
    try:
        loop.run()
    finally:
        daemon.stop()
    return 0


if __name__ == '__main__':
    sys.exit(main())
