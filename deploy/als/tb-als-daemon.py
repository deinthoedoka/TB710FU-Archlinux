#!/usr/bin/env python3
"""环境光自动亮度守护（KDE Plasma）。

两种模式：
  默认         桌面会话：通过 PowerDevil 的 BrightnessControl 调亮度。
  --greeter    登录界面：greeter 没有 PowerDevil，直接写 backlight sysfs。

PowerDevil 的亮度标度是 0..10000，硬件背光有 4080 级，细调完全够用；
这里不再量化到 5%，而是用 0.5%～2% 的小步逐帧过渡，做到无级渐变。
"""

import json
import math
import os
import signal
import subprocess
import sys
import time

SENSOR_DEST = "net.hadess.SensorProxy"
SENSOR_PATH = "/net/hadess/SensorProxy"
SENSOR_IFACE = "net.hadess.SensorProxy"

PD_DEST = "org.kde.Solid.PowerManagement"
PD_PATH = "/org/kde/Solid/PowerManagement/Actions/BrightnessControl"
PD_IFACE = "org.kde.Solid.PowerManagement.Actions.BrightnessControl"

BACKLIGHT_DIR = "/sys/class/backlight/sy7758-backlight"
GREETER_UID = 958
ENABLED_FLAG = "/home/alarm/.config/tb-als-enabled"

# 曲线锚点：(log10(lux), 亮度 0..10000)，按对数光照线性插值。
CURVE = (
    (-1.30, 500),
    (0.00, 700),
    (0.50, 1000),
    (1.00, 1500),
    (1.50, 2200),
    (2.00, 3300),
    (2.50, 4700),
    (3.00, 6500),
    (3.50, 8000),
    (4.00, 9300),
    (4.60, 10000),
)

EMA_ALPHA = 0.4
SENSOR_INTERVAL = 0.5
TICK = 0.1

# 桌面模式：每 100 ms 最多走 2%，最小 0.5%；差值小于 0.4% 不动。
PD_RAMP_MAX = 200
PD_RAMP_MIN = 50
PD_DEADBAND = 40
PD_REASSERT_DELAY = 3.0

# 手动调整检测与学习曲线
PROFILE_PATH = "/home/alarm/.config/tb-als-profile.json"
PROFILE_X0 = -1.5
PROFILE_STEP = 0.5
PROFILE_N = 14                  # -1.5 .. 5.0（log10 lux）
PROFILE_MAX_OFFSET = 7000.0     # 最多把曲线抬/压低 70%
PD_POLL_INTERVAL = 0.5          # 读取 PowerDevil 当前亮度的间隔
PD_MANUAL_DELTA = 120           # 与守护进程写入值差这么多才算手动
LEARN_WARMUP = 8.0              # 启动后先不学习，避开 KWin 恢复亮度的窗口
LEARN_SETTLE = 0.6              # 手动值稳定这么久才学习
LEARN_STABLE = 40               # 稳定判定阈值
DIM_IDLE_THRESHOLD = 15         # 空闲超过这么久就认为亮度变化是自动调暗，不学习

# 登录界面模式：同样按背光的 4080 级换算，每 100 ms 最多走 2%。
RAW_RAMP_MAX = 80
RAW_RAMP_MIN = 20
RAW_DEADBAND = 12
RAW_EXTERNAL_DELTA = 8
RAW_EXTERNAL_WAIT = 0.8
GREETER_CHECK_INTERVAL = 1.0

running = True


def _stop(signum, frame):
    global running
    running = False


def busctl(args, timeout=3.0):
    try:
        return subprocess.run(
            ["busctl", *args],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None


def read_lux():
    """返回当前环境光（lux），传感器不可用时返回 None。"""
    result = busctl([
        "--system", "get-property", SENSOR_DEST, SENSOR_PATH,
        SENSOR_IFACE, "LightLevel",
    ])
    if result is None or result.returncode != 0:
        return None
    parts = result.stdout.split()
    if len(parts) < 2:
        return None
    try:
        lux = float(parts[1])
    except ValueError:
        return None
    if not math.isfinite(lux) or lux < 0:
        return None
    return lux


def curve(lux):
    """把 lux 映射到 0..10000 的亮度。"""
    value = math.log10(max(lux, 0.05))
    if value <= CURVE[0][0]:
        return float(CURVE[0][1])
    for (x0, y0), (x1, y1) in zip(CURVE, CURVE[1:]):
        if value <= x1:
            return y0 + (y1 - y0) * (value - x0) / (x1 - x0)
    return float(CURVE[-1][1])


def target_value(lux, maximum, profile):
    """基础曲线 + 学到的偏移，换算到目标标度（10000 或背光级数）。"""
    value = curve(lux) + profile_offset(profile, lux)
    value = max(1.0, min(10000.0, value))
    if maximum == 10000:
        return int(round(value))
    return max(1, min(maximum, int(round(value * maximum / 10000.0))))


def _profile_default():
    return {"version": 1, "offsets": [0.0] * PROFILE_N, "updated": 0}


def load_profile():
    profile = _profile_default()
    try:
        with open(PROFILE_PATH) as handle:
            data = json.load(handle)
        offsets = data.get("offsets")
        if isinstance(offsets, list) and len(offsets) == PROFILE_N:
            profile["offsets"] = [
                max(-PROFILE_MAX_OFFSET, min(PROFILE_MAX_OFFSET, float(value)))
                for value in offsets
            ]
            profile["updated"] = int(data.get("updated", 0))
    except (OSError, ValueError, TypeError):
        pass
    return profile


def save_profile(profile):
    profile["updated"] = int(time.time())
    try:
        directory = os.path.dirname(PROFILE_PATH)
        if directory:
            os.makedirs(directory, exist_ok=True)
        tmp = PROFILE_PATH + ".tmp"
        with open(tmp, "w") as handle:
            json.dump(profile, handle, ensure_ascii=False)
        os.replace(tmp, PROFILE_PATH)
        if os.geteuid() == 0:
            try:
                os.chown(PROFILE_PATH, 1000, 1000)
            except OSError:
                pass
    except OSError as error:
        print("tb-als: 保存亮度学习数据失败: %s" % error, flush=True)


def _profile_pos(lux):
    value = math.log10(max(lux, 0.05))
    value = min(max(value, PROFILE_X0), PROFILE_X0 + PROFILE_STEP * (PROFILE_N - 1))
    return (value - PROFILE_X0) / PROFILE_STEP


def _interp_offsets(offsets, pos):
    index = min(int(pos), PROFILE_N - 2)
    frac = pos - index
    return offsets[index] * (1.0 - frac) + offsets[index + 1] * frac


def profile_offset(profile, lux):
    return _interp_offsets(profile["offsets"], _profile_pos(lux))


def learn_profile(profile, lux, value):
    """把这个光照下用户想要的亮度写进锚点；插值后正好命中用户设定值。"""
    pos = _profile_pos(lux)
    delta = value - curve(lux)
    index = min(int(pos), PROFILE_N - 2)
    frac = pos - index
    offsets = list(profile["offsets"])

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

    # 插值补偿：保证 learn 之后 curve(lux)+offset == 用户设定值。
    residual = delta - _interp_offsets(offsets, pos)
    denom = (1.0 - frac) ** 2 + frac ** 2
    if denom > 0.01:
        offsets[index] += residual * (1.0 - frac) / denom
        offsets[index + 1] += residual * frac / denom

    profile["offsets"] = [
        max(-PROFILE_MAX_OFFSET, min(PROFILE_MAX_OFFSET, item)) for item in offsets
    ]


def read_int(path):
    try:
        with open(path) as handle:
            return int(handle.read().strip())
    except (OSError, ValueError):
        return None


def write_raw(value):
    try:
        with open(os.path.join(BACKLIGHT_DIR, "brightness"), "w") as handle:
            handle.write(str(int(value)))
        return True
    except OSError as error:
        print("tb-als: 写背光失败: %s" % error, flush=True)
        return False


def greeter_active():
    """plasmalogin 用户的 kwin_wayland 在跑 = 登录界面在场。"""
    try:
        entries = os.listdir("/proc")
    except OSError:
        return False
    for entry in entries:
        if not entry.isdigit():
            continue
        try:
            if os.stat("/proc/" + entry).st_uid != GREETER_UID:
                continue
            with open("/proc/" + entry + "/comm") as handle:
                if handle.read().strip() == "kwin_wayland":
                    return True
        except OSError:
            continue
    return False


def greeter_enabled():
    """桌面上的“自动亮度”开关状态，关掉时登录界面也保持原亮度。"""
    try:
        with open(ENABLED_FLAG) as handle:
            return handle.read().strip().lower() not in ("0", "false", "off", "no")
    except OSError:
        return True


def pd_available():
    result = busctl(["--user", "call", PD_DEST, PD_PATH, PD_IFACE, "brightnessMax"])
    return result is not None and result.returncode == 0


def pd_get_brightness():
    result = busctl(["--user", "call", PD_DEST, PD_PATH, PD_IFACE, "brightness"])
    if result is None or result.returncode != 0:
        return None
    parts = result.stdout.split()
    try:
        return int(parts[1])
    except (IndexError, ValueError):
        return None


def pd_set(value):
    result = busctl([
        "--user", "call", PD_DEST, PD_PATH, PD_IFACE,
        "setBrightnessSilent", "i", str(int(value)),
    ])
    if result is None or result.returncode != 0:
        result = busctl([
            "--user", "call", PD_DEST, PD_PATH, PD_IFACE,
            "setBrightness", "i", str(int(value)),
        ])
    return result is not None and result.returncode == 0


def session_idle_seconds():
    """会话空闲秒数；拿不到就返回 None（不影响自动亮度）。"""
    result = busctl([
        "--user", "call", "org.kde.screensaver", "/ScreenSaver",
        "org.freedesktop.ScreenSaver", "GetSessionIdleTime",
    ])
    if result is None or result.returncode != 0:
        return None
    parts = result.stdout.split()
    try:
        return int(parts[1])
    except (IndexError, ValueError):
        return None


def status_path(greeter):
    if greeter:
        return "/run/tb-als-greeter.status"
    runtime = os.environ.get("XDG_RUNTIME_DIR", "/run/user/%d" % os.getuid())
    return os.path.join(runtime, "tb-als.status")


def write_status(path, lux, target, applied, offset=0.0):
    try:
        tmp = path + ".tmp"
        with open(tmp, "w") as handle:
            handle.write(
                "lux=%.1f\ntarget=%d\nbrightness=%d\noffset=%.1f\nupdated=%d\n"
                % (lux if lux is not None else -1.0, target, applied, offset,
                   int(time.time()))
            )
        os.replace(tmp, path)
    except OSError:
        pass


def simulate():
    profile = load_profile()
    for lux in (0.0, 0.5, 1, 5, 10, 30, 100, 136, 300, 1000, 10000, 30000):
        print(
            "%8.1f lx -> %5.1f%% (raw %4.0f)  learned %5.1f%%"
            % (lux, curve(lux) / 100.0, curve(lux),
               target_value(lux, 10000, profile) / 100.0)
        )


def run_powerdevil():
    profile = load_profile()
    ema = None
    target = None
    applied = None
    need_fresh = True
    pd_ok = False
    sensor_failures = 0
    next_sensor = 0.0
    next_poll = 0.0
    reassert_at = None
    last_logged = None
    last_status = 0.0
    last_step = 0
    manual = None
    dim_saved = None
    dim_hold = False
    next_idle_check = 0.0
    started = time.monotonic()

    print("tb-als: starting (powerdevil)", flush=True)

    while running:
        now = time.monotonic()

        if not pd_ok:
            if not pd_available():
                time.sleep(1.0)
                continue
            pd_ok = True
            need_fresh = True
            started = now

        if now >= next_sensor:
            next_sensor = now + SENSOR_INTERVAL
            lux = read_lux()
            if lux is None:
                sensor_failures += 1
                if sensor_failures == 1:
                    print("tb-als: 环境光传感器暂不可用，等待", flush=True)
            else:
                if sensor_failures:
                    print("tb-als: 环境光传感器已可用", flush=True)
                    sensor_failures = 0
                    ema = None
                    need_fresh = True
                if ema is None:
                    ema = lux
                else:
                    ema += EMA_ALPHA * (lux - ema)
                target = target_value(ema, 10000, profile)

        if target is None:
            time.sleep(TICK)
            continue

        if applied is None:
            current = pd_get_brightness()
            applied = current if current is not None else target
        if need_fresh:
            # 从当前亮度开始渐变，而不是保留上次的高亮度不动。
            need_fresh = False
            reassert_at = now + PD_REASSERT_DELAY
            last_logged = applied
            print(
                "tb-als: 初始光照 %.1f lx，从 %d%% 过渡到 %d%%"
                % (ema, applied / 100.0, target / 100.0),
                flush=True,
            )

        # 手动调整：用户按亮度键/拖滑块后，把当前光照下的偏好学进曲线，
        # 而不是过一会儿又拉回曲线值。
        if ema is not None and now >= next_poll:
            next_poll = now + PD_POLL_INTERVAL
            current = pd_get_brightness()
            if current is not None:
                if dim_hold:
                    # PowerDevil 空闲自动调暗：不学习，也不和它抢亮度。
                    if now >= next_idle_check:
                        next_idle_check = now + 1.0
                        idle = session_idle_seconds()
                        if idle is not None and idle <= 5:
                            if (dim_saved is not None
                                    and abs(current - dim_saved) <= PD_DEADBAND * 2):
                                applied = current
                                print("tb-als: 空闲调光结束，恢复自动亮度",
                                      flush=True)
                            dim_hold = False
                            dim_saved = None
                elif manual is None:
                    ramping = abs(target - applied) > PD_DEADBAND
                    limit = PD_MANUAL_DELTA
                    if ramping:
                        limit = max(limit, int(last_step * 1.6) + PD_DEADBAND)
                    if (now - started > LEARN_WARMUP
                            and abs(current - applied) > limit):
                        idle = session_idle_seconds()
                        if idle is not None and idle > DIM_IDLE_THRESHOLD:
                            dim_saved = applied
                            dim_hold = True
                            applied = current
                            reassert_at = None
                            print(
                                "tb-als: 空闲调光（空闲 %d 秒），暂停自动调整"
                                % idle,
                                flush=True,
                            )
                        else:
                            manual = {"value": current, "since": now, "lux": ema}
                            applied = current
                            reassert_at = None
                            print(
                                "tb-als: 检测到手动调整到 %.1f%%（光照 %.1f lx），等稳定"
                                % (current / 100.0, ema),
                                flush=True,
                            )
                elif abs(current - manual["value"]) > LEARN_STABLE:
                    manual["value"] = current
                    manual["since"] = now
                    manual["lux"] = ema
                elif now - manual["since"] >= LEARN_SETTLE:
                    learn_profile(profile, manual["lux"], manual["value"])
                    save_profile(profile)
                    applied = manual["value"]
                    target = target_value(ema, 10000, profile)
                    last_logged = applied
                    print(
                        "tb-als: 已学习：%.1f lx 下偏好 %.1f%%，当前偏移 %+.1f%%"
                        % (manual["lux"], applied / 100.0,
                           profile_offset(profile, manual["lux"]) / 100.0),
                        flush=True,
                    )
                    manual = None

        if manual is not None or dim_hold:
            if now - last_status >= 1.0:
                write_status(status_path(False), ema, target, applied,
                             profile_offset(profile, ema))
                last_status = now
            time.sleep(TICK)
            continue

        delta = target - applied
        if abs(delta) > PD_DEADBAND:
            step = max(PD_RAMP_MIN, min(PD_RAMP_MAX, abs(delta) // 8))
            step = min(step, abs(delta))
            value = applied + (step if delta > 0 else -step)
            if not pd_set(value):
                pd_ok = False
                continue
            applied = value
            last_step = step
            if (last_logged is None or abs(applied - last_logged) >= 300
                    or applied == target):
                print("tb-als: 光照 %.1f lx -> %.1f%%" % (ema, applied / 100.0),
                      flush=True)
                last_logged = applied
        elif reassert_at is not None and now >= reassert_at:
            if not pd_set(applied):
                pd_ok = False
                continue
            reassert_at = None
            print("tb-als: 已复核 %.1f%%" % (applied / 100.0), flush=True)

        if now - last_status >= 1.0:
            write_status(status_path(False), ema, target, applied,
                         profile_offset(profile, ema))
            last_status = now

        time.sleep(TICK)

    print("tb-als: stopped", flush=True)


def run_greeter():
    maximum = read_int(os.path.join(BACKLIGHT_DIR, "max_brightness")) or 4080
    profile = load_profile()
    ema = None
    target = None
    applied = None
    need_fresh = True
    last_write = 0.0
    last_status = 0.0
    active = False
    next_sensor = 0.0
    next_check = 0.0

    print("tb-als: starting (greeter)", flush=True)

    while running:
        now = time.monotonic()

        if now >= next_check:
            next_check = now + GREETER_CHECK_INTERVAL
            present = greeter_active()
            enabled = greeter_enabled()
            if present and enabled and not active:
                active = True
                profile = load_profile()
                ema = None
                target = None
                applied = None
                need_fresh = True
                print("tb-als: 检测到登录界面，开始接管亮度", flush=True)
            elif (not present or not enabled) and active:
                active = False
                if present:
                    print("tb-als: 自动亮度已关闭，登录界面保持当前亮度", flush=True)
                else:
                    print("tb-als: 登录界面已结束，停止接管", flush=True)

        if not active:
            time.sleep(0.5)
            continue

        if now >= next_sensor:
            next_sensor = now + SENSOR_INTERVAL
            lux = read_lux()
            if lux is not None:
                if ema is None:
                    ema = lux
                else:
                    ema += EMA_ALPHA * (lux - ema)
                target = target_value(ema, maximum, profile)

        current = read_int(os.path.join(BACKLIGHT_DIR, "brightness"))
        if current is None or target is None:
            time.sleep(TICK)
            continue

        if applied is None or need_fresh:
            applied = current
            need_fresh = False
            print(
                "tb-als: 登录界面初始光照 %.1f lx，从 %d/%d 过渡到 %d/%d"
                % (ema, applied, maximum, target, maximum),
                flush=True,
            )

        # KWin 可能在启动/唤醒时写回它保存的亮度，发现外部改动就重新收敛。
        if abs(current - applied) > RAW_EXTERNAL_DELTA and now - last_write > RAW_EXTERNAL_WAIT:
            print("tb-als: 登录界面亮度被外部改为 %d，重新收敛" % current, flush=True)
            applied = current

        delta = target - applied
        if abs(delta) > RAW_DEADBAND:
            step = max(RAW_RAMP_MIN, min(RAW_RAMP_MAX, abs(delta) // 8))
            step = min(step, abs(delta))
            value = applied + (step if delta > 0 else -step)
            if write_raw(value):
                applied = value
                last_write = now

        if now - last_status >= 1.0:
            write_status(status_path(True), ema, target, applied,
                         profile_offset(profile, ema) if ema is not None else 0.0)
            last_status = now

        time.sleep(TICK)

    print("tb-als: stopped", flush=True)


def main():
    global running
    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    greeter = "--greeter" in sys.argv[1:]
    if "--simulate" in sys.argv[1:]:
        simulate()
        return 0

    if greeter:
        run_greeter()
    else:
        run_powerdevil()
    return 0


if __name__ == "__main__":
    sys.exit(main())
