// TB710FU 自动亮度（GNOME Shell 扩展）
//
// 为什么不用 gnome-settings-daemon 自带的 ambient 逻辑：
//   gsd 把读数按「启动时的光照 ×1.5」做线性归一化，再以 10Hz 把目标丢给
//   shell；光照稍一变化就会在两条写回路径之间来回推，亮度表现为 1~2 秒一次
//   的抽动。这里改成：对数曲线定目标、对数域低通抑噪、目标值再做指数逼近，
//   每一步都是小步，观感匀速。
//
// 执行器走 shell 自己的 brightnessManager：先把 scale.value 同步成目标值（不
// 触发归一化），再 setBacklight()，这样 shell 的「用户亮度」和硬件始终一致，
// 不会出现 gsd 那种 udev 回写导致的漂移。

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const POWER_SCHEMA = 'org.gnome.settings-daemon.plugins.power';
const SENSOR_NAME = 'net.hadess.SensorProxy';
const SENSOR_PATH = '/net/hadess/SensorProxy';
const SENSOR_IFACE = 'net.hadess.SensorProxy';

const TICK_MS = 100;           // 控制周期（10Hz，和旧 daemon 一致）
const SENSOR_POLL_MS = 500;    // 传感器读取周期
const LUX_TAU_S = 1.2;         // 对数域 EMA 时间常数
const RAMP_TAU_S = 0.70;       // 目标值指数逼近时间常数
const MAX_STEP = 0.012;        // 单步最多 1.2%（约 49/4080），肉眼基本看不出台阶
const TARGET_DEADBAND = 0.010; // 目标差 <1% 不动
const DIM_DEADBAND = 0.004;    // 已知目标与实测差 <0.4% 不动

// 曲线锚点：(log10(lux), 亮度 0..1)
const CURVE = [
    [-1.30, 0.04],
    [0.00, 0.06],
    [0.50, 0.09],
    [1.00, 0.14],
    [1.50, 0.21],
    [2.00, 0.32],
    [2.50, 0.45],
    [3.00, 0.62],
    [3.50, 0.78],
    [4.00, 0.92],
    [4.60, 1.00],
];

// 学习曲线：14 个锚点覆盖 -1.5..5.0 log10(lux)
const PROFILE_X0 = -1.5;
const PROFILE_STEP = 0.5;
const PROFILE_N = 14;
const PROFILE_MAX_OFFSET = 0.70;

const PROFILE_PATH = GLib.build_filenamev([
    GLib.get_user_config_dir(), 'tb-als-profile.json',
]);

function log10(x) {
    return Math.log10(Math.max(x, 1e-3));
}

function curveValue(lux) {
    const v = log10(Math.max(lux, 0.05));
    if (v <= CURVE[0][0])
        return CURVE[0][1];
    for (let i = 0; i < CURVE.length - 1; i++) {
        const [x0, y0] = CURVE[i];
        const [x1, y1] = CURVE[i + 1];
        if (v <= x1)
            return y0 + (y1 - y0) * (v - x0) / (x1 - x0);
    }
    return CURVE[CURVE.length - 1][1];
}

function profilePos(lux) {
    const v = Math.min(Math.max(log10(Math.max(lux, 0.05)), PROFILE_X0),
        PROFILE_X0 + PROFILE_STEP * (PROFILE_N - 1));
    return (v - PROFILE_X0) / PROFILE_STEP;
}

function interpOffsets(offsets, pos) {
    const index = Math.min(Math.floor(pos), PROFILE_N - 2);
    const frac = pos - index;
    return offsets[index] * (1 - frac) + offsets[index + 1] * frac;
}

function loadProfile() {
    const profile = {offsets: new Array(PROFILE_N).fill(0)};
    try {
        const [ok, bytes] = GLib.file_get_contents(PROFILE_PATH);
        if (!ok)
            return profile;
        const data = JSON.parse(new TextDecoder().decode(bytes));
        // 旧版 tb-als（KDE，0..10000 标度）的档案不兼容，直接忽略。
        if (data.version !== 2)
            return profile;
        if (Array.isArray(data.offsets) && data.offsets.length === PROFILE_N) {
            profile.offsets = data.offsets.map(v =>
                Math.min(PROFILE_MAX_OFFSET, Math.max(-PROFILE_MAX_OFFSET, Number(v) || 0)));
        }
    } catch (e) {
        // 没有档案或格式不对：用默认曲线
    }
    return profile;
}

function saveProfile(profile) {
    try {
        GLib.file_set_contents(PROFILE_PATH,
            JSON.stringify({version: 2, offsets: profile.offsets}));
    } catch (e) {
        console.warn(`tb-als: 保存学习数据失败: ${e.message}`);
    }
}

function learnProfile(profile, lux, value) {
    const pos = profilePos(lux);
    const delta = value - curveValue(lux);
    const index = Math.min(Math.floor(pos), PROFILE_N - 2);
    const frac = pos - index;
    const offsets = profile.offsets.slice();

    for (let j = Math.max(0, index - 2); j < Math.min(PROFILE_N, index + 4); j++) {
        const distance = Math.abs(j - pos);
        let rate = 0;
        if (distance < 0.75)
            rate = 0.55;
        else if (distance < 1.75)
            rate = 0.30;
        else if (distance < 2.5)
            rate = 0.12;
        else
            continue;
        offsets[j] += (delta - offsets[j]) * rate;
    }

    const residual = delta - interpOffsets(offsets, pos);
    const denom = (1 - frac) ** 2 + frac ** 2;
    if (denom > 0.01) {
        offsets[index] += residual * (1 - frac) / denom;
        offsets[index + 1] += residual * frac / denom;
    }

    profile.offsets = offsets.map(v =>
        Math.min(PROFILE_MAX_OFFSET, Math.max(-PROFILE_MAX_OFFSET, v)));
}

export default class TbAlsExtension extends Extension {
    enable() {
        this._settings = new Gio.Settings({schema_id: POWER_SCHEMA});
        this._profile = loadProfile();
        this._luxEma = null;
        this._ramped = null;
        this._lastSensor = 0;
        this._lastTick = GLib.get_monotonic_time();
        this._userValue = null;
        this._userSince = 0;
        this._lastLogged = -1;
        this._sawLux = false;
        this._lastApplyValue = null;

        // Claim 由 root 的 tb-als-claim.service 常驻持有（需要 polkit 授权），
        // 这里只负责读 LightLevel。

        this._settingsId = this._settings.connect('changed::ambient-enabled',
            () => this._onEnabledChanged());

        const bm = Main.brightnessManager;
        this._bmSignal = bm?.connect('user-update', () => this._onUserUpdate()) ?? 0;

        this._enabled = this._settings.get_boolean('ambient-enabled');
        this._timerId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, TICK_MS,
            () => this._tick());
        console.log(`tb-als: extension enabled (ambient=${this._enabled})`);
    }

    disable() {
        if (this._timerId) {
            GLib.source_remove(this._timerId);
            this._timerId = 0;
        }
        if (this._settingsId) {
            this._settings.disconnect(this._settingsId);
            this._settingsId = 0;
        }
        const bm = Main.brightnessManager;
        if (this._bmSignal && bm)
            bm.disconnect(this._bmSignal);
        this._bmSignal = 0;
        this._sensor = null;
        this._settings = null;
        console.log('tb-als: extension disabled');
    }

    _debug(now, message) {
        if (now - (this._lastDebug ?? 0) < 5000000)
            return;
        this._lastDebug = now;
        console.log(`tb-als: ${message}`);
    }

    _onEnabledChanged() {
        this._enabled = this._settings.get_boolean('ambient-enabled');
        this._ramped = this._current();
        console.log(`tb-als: ambient-enabled=${this._enabled}`);
    }

    _onUserUpdate() {
        const actual = this._current();
        if (actual === null)
            return;
        // 忽略自己写入的回声（正常情况下写 scale.value 时是 inhibited 的，
        // 这里只是兜底，避免把自动亮度误当成用户偏好学进去）。
        if (this._lastApplyValue !== null &&
            Math.abs(actual - this._lastApplyValue) < 0.005)
            return;
        // 用户拨了亮度（滑块/快捷键）：等 0.7s 稳定后学习，拖动过程不抢。
        this._userValue = actual;
        this._userSince = GLib.get_monotonic_time();
    }

    _scale() {
        const bm = Main.brightnessManager;
        if (!bm)
            return null;
        const scales = bm.scales;
        return scales.length > 0 ? scales[0] : null;
    }

    _current() {
        const scale = this._scale();
        if (!scale)
            return null;
        return Math.min(1, Math.max(0, scale.value));
    }

    _readLux() {
        // 直接 Properties.Get：GDBusProxy 的属性缓存不会跟着
        // iio-sensor-proxy 的 PropertiesChanged 更新，只有显式读取才是活的。
        try {
            const reply = Gio.DBus.system.call_sync(
                SENSOR_NAME, SENSOR_PATH,
                'org.freedesktop.DBus.Properties', 'Get',
                new GLib.Variant('(ss)', [SENSOR_IFACE, 'LightLevel']),
                null, Gio.DBusCallFlags.NONE, 500, null);
            const [variant] = reply.deepUnpack();
            const lux = variant.deepUnpack();
            if (typeof lux !== 'number' || !isFinite(lux) || lux < 0)
                return null;
            if (lux > 0)
                this._sawLux = true;
            // 0 可能是「还没数据」，也可能是真黑屋；见过真值之后才信 0。
            if (lux === 0 && !this._sawLux)
                return null;
            return lux;
        } catch (e) {
            return null;
        }
    }

    _apply(scale, value) {
        const bm = Main.brightnessManager;
        if (!bm || bm.dimming)
            return;

        // 同步 shell 的「用户亮度」和 UI 滑块，但不触发归一化/OSD 路径。
        bm._inhibitUpdates = true;
        try {
            scale.value = value;
            scale._scaleChanged = false;
            if (bm._globalScale) {
                bm._globalScale.value = value;
                bm._globalScaleChanged = false;
            }
        } finally {
            bm._inhibitUpdates = false;
        }
        this._lastApplyValue = value;
        scale.setBacklight(value);
    }

    _tick() {
        const now = GLib.get_monotonic_time();
        const dt = Math.min(1, Math.max(0.001, (now - this._lastTick) / 1e6));
        this._lastTick = now;

        // 扩展可能比 brightnessManager 先就绪，第一次拿到时补连信号。
        const bm = Main.brightnessManager;
        if (!this._bmSignal && bm)
            this._bmSignal = bm.connect('user-update', () => this._onUserUpdate());

        if (!this._enabled)
            return GLib.SOURCE_CONTINUE;

        const scale = this._scale();
        if (!scale) {
            this._debug(now, 'no brightness scale yet');
            return GLib.SOURCE_CONTINUE;
        }

        if (now - this._lastSensor >= SENSOR_POLL_MS * 1000) {
            this._lastSensor = now;
            const lux = this._readLux();
            if (lux !== null) {
                const v = log10(lux);
                if (this._luxEma === null)
                    this._luxEma = v;
                else {
                    const alpha = 1 - Math.exp(-SENSOR_POLL_MS / 1000 / LUX_TAU_S);
                    this._luxEma += alpha * (v - this._luxEma);
                }
            }
        }

        if (this._luxEma === null) {
            this._debug(now, 'no lux yet');
            return GLib.SOURCE_CONTINUE;
        }

        const lux = 10 ** this._luxEma;
        const actual = Math.min(1, Math.max(0, scale.value));

        this._debug(now, `lux=${(10 ** this._luxEma).toFixed(1)} ` +
            `target=${((this._ramped ?? actual) * 100).toFixed(1)}% ` +
            `actual=${(actual * 100).toFixed(1)}% dim=${Main.brightnessManager?.dimming}`);

        if (this._userValue !== null) {
            if ((now - this._userSince) / 1e6 < 0.7)
                return GLib.SOURCE_CONTINUE;
            learnProfile(this._profile, lux, this._userValue);
            saveProfile(this._profile);
            console.log(`tb-als: 学习 ${lux.toFixed(1)} lx -> ` +
                `${(this._userValue * 100).toFixed(1)}%`);
            this._ramped = this._userValue;
            this._userValue = null;
            return GLib.SOURCE_CONTINUE;
        }

        if (this._ramped === null)
            this._ramped = actual;

        const offset = interpOffsets(this._profile.offsets, profilePos(lux));
        const desired = Math.min(1, Math.max(0, curveValue(lux) + offset));

        let step = 0;
        if (Math.abs(desired - this._ramped) > TARGET_DEADBAND)
            step = (desired - this._ramped) * (1 - Math.exp(-dt / RAMP_TAU_S));
        step = Math.min(MAX_STEP, Math.max(-MAX_STEP, step));
        this._ramped += step;

        if (Main.brightnessManager?.dimming)
            return GLib.SOURCE_CONTINUE;

        if (Math.abs(this._ramped - actual) < DIM_DEADBAND)
            return GLib.SOURCE_CONTINUE;

        if (Math.abs(this._ramped - this._lastLogged) >= 0.03) {
            this._lastLogged = this._ramped;
            console.log(`tb-als: lux=${lux.toFixed(1)} -> ` +
                `${(this._ramped * 100).toFixed(1)}%`);
        }
        this._apply(scale, this._ramped);
        return GLib.SOURCE_CONTINUE;
    }
}
