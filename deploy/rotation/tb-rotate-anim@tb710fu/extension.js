// Android-like rotation animation for the TB710FU builtin panel.
//
// How it works:
//   * The shell's own D-Bus connection already holds the accelerometer claim
//     (mutter claims it), so this proxy receives AccelerometerOrientation
//     changes as well.
//   * Mutter defers its orientation handling to an idle callback, so this
//     handler runs *before* the output transform is applied. That is the key
//     trick: we can snapshot the screen while it still shows the old
//     orientation.
//   * When mutter applies the new orientation (emits monitors-changed), the
//     snapshot is put on top of everything, rotated by the transform delta so
//     it looks exactly like the old screen, then eased back to 0.  A dark,
//     blurred-out copy of the snapshot sits behind it, so the new orientation
//     (in particular the top bar) does not peek through the corners during the
//     rotation.  Only at the end does the whole overlay fade out and reveal
//     the new screen.
//
// Everything is local to the shell: no root helpers, no screenshot round
// trips through the portal.
//
// Tunables can be overridden in ~/.config/tb-rotate-anim.json, for example:
//   { "duration_ms": 360, "fade_ms": 240, "scale": 0.93,
//     "backdrop_dim": 0.55, "prewarm": true }

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Graphene from 'gi://Graphene';
import Mtk from 'gi://Mtk';
import St from 'gi://St';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

const SENSOR_BUS_NAME = 'net.hadess.SensorProxy';
const SENSOR_OBJECT_PATH = '/net/hadess/SensorProxy';
const SENSOR_INTERFACE = 'net.hadess.SensorProxy';

const PREWARM_HELPER = '/usr/local/bin/tb-rotate-prewarm';

// Same mapping as mutter's meta_orientation_to_transform().
const ORIENTATION_TRANSFORMS = {
    'normal': 0,
    'left-up': 1,
    'bottom-up': 2,
    'right-up': 3,
    'undefined': 0,
};

const DEFAULT_CONFIG = {
    duration_ms: 360,   // rotation phase, before the fade starts
    fade_ms: 240,       // fade-out phase
    scale: 0.93,        // outgoing snapshot shrinks to this
    backdrop_dim: 0.55, // 0..1, how much the backdrop copy is darkened
    prewarm: true,      // pay the first rotated modeset while the shell starts
};

const PENDING_TIMEOUT = 1500;
// A hair larger than 1 at the start so a rounding seam at the stage edge does
// not show the black base for one frame.
const START_SCALE = 1.002;
const CONFIG_PATH = GLib.build_filenamev([
    GLib.get_user_config_dir(), 'tb-rotate-anim.json',
]);

function loadConfig() {
    const config = {...DEFAULT_CONFIG};
    try {
        const [ok, bytes] = GLib.file_get_contents(CONFIG_PATH);
        if (ok) {
            const data = JSON.parse(new TextDecoder().decode(bytes));
            for (const key of Object.keys(DEFAULT_CONFIG)) {
                if (key in data && typeof data[key] === typeof DEFAULT_CONFIG[key])
                    config[key] = data[key];
            }
        }
    } catch (e) {
        // Missing or malformed file: use the defaults.
    }
    config.duration_ms = Math.min(2000, Math.max(80, Number(config.duration_ms) || DEFAULT_CONFIG.duration_ms));
    config.fade_ms = Math.min(2000, Math.max(0, Number(config.fade_ms) || 0));
    config.scale = Math.min(1, Math.max(0.5, Number(config.scale) || DEFAULT_CONFIG.scale));
    config.backdrop_dim = Math.min(0.95, Math.max(0, Number(config.backdrop_dim) || 0));
    return config;
}

export default class RotationAnimationExtension extends Extension {
    enable() {
        this._container = null;
        this._pending = null;
        this._pendingTimeout = 0;
        this._fadeTimeout = 0;
        this._lastTransform = 0;
        this._config = loadConfig();

        // iio-sensor-proxy lives on the *system* bus. Mutter claims the
        // accelerometer over the same shared system-bus connection, and iio
        // sends PropertiesChanged as a unicast signal to the claimant's
        // unique name, so this proxy must be on the system bus as well.
        this._proxy = Gio.DBusProxy.new_for_bus_sync(
            Gio.BusType.SYSTEM,
            Gio.DBusProxyFlags.NONE,
            null,
            SENSOR_BUS_NAME,
            SENSOR_OBJECT_PATH,
            SENSOR_INTERFACE,
            null);

        const orientation = this._getOrientation();
        this._lastTransform = ORIENTATION_TRANSFORMS[orientation] ?? 0;

        this._propertiesChangedId = this._proxy.connect(
            'g-properties-changed', this._onPropertiesChanged.bind(this));
        this._monitorsChangedId = Main.layoutManager.connect(
            'monitors-changed', this._onMonitorsChanged.bind(this));

        if (this._config.prewarm) {
            this._prewarmId = GLib.timeout_add(
                GLib.PRIORITY_DEFAULT, 0, () => {
                    this._prewarmId = 0;
                    this._runPrewarm();
                    return GLib.SOURCE_REMOVE;
                });
        }
    }

    disable() {
        if (this._pendingTimeout) {
            GLib.source_remove(this._pendingTimeout);
            this._pendingTimeout = 0;
        }
        if (this._fadeTimeout) {
            GLib.source_remove(this._fadeTimeout);
            this._fadeTimeout = 0;
        }
        if (this._prewarmId) {
            GLib.source_remove(this._prewarmId);
            this._prewarmId = 0;
        }
        this._pending = null;

        if (this._monitorsChangedId) {
            Main.layoutManager.disconnect(this._monitorsChangedId);
            this._monitorsChangedId = 0;
        }
        if (this._propertiesChangedId) {
            this._proxy.disconnect(this._propertiesChangedId);
            this._propertiesChangedId = 0;
        }
        this._proxy = null;

        this._destroyOverlay();
    }

    _getOrientation() {
        const variant = this._proxy.get_cached_property('AccelerometerOrientation');
        return variant ? variant.unpack() : 'undefined';
    }

    // The first transform change after boot makes mutter allocate a new
    // rotated scan-out buffer and power-cycle the DSI panel (about 370 ms of
    // black).  Rotate to the other panel shape once while the shell is still
    // starting, and immediately rotate back, so the user's first real
    // rotation reuses the cached buffers.  One prewarm per boot.
    _runPrewarm() {
        if (!GLib.file_test(PREWARM_HELPER, GLib.FileTest.IS_EXECUTABLE))
            return;
        const marker = GLib.build_filenamev([
            GLib.get_user_runtime_dir(), 'tb-rotate-anim-prewarm',
        ]);
        if (GLib.file_test(marker, GLib.FileTest.EXISTS))
            return;
        try {
            const process = Gio.Subprocess.new(
                [PREWARM_HELPER],
                Gio.SubprocessFlags.STDOUT_SILENCE |
                Gio.SubprocessFlags.STDERR_SILENCE);
            log('[tb-rotate-anim] prewarm started');
            process.wait_check_async(null, (subprocess, result) => {
                try {
                    subprocess.wait_check_finish(result);
                    log('[tb-rotate-anim] prewarm finished');
                } catch (e) {
                    logError(e, '[tb-rotate-anim] prewarm failed');
                }
            });
        } catch (e) {
            logError(e, '[tb-rotate-anim] failed to start the prewarm helper');
        }
    }

    _onPropertiesChanged(proxy, changed, invalidated) {
        const variant = changed.lookup_value('AccelerometerOrientation', null);
        if (!variant)
            return;

        const orientation = variant.unpack();
        const transform = ORIENTATION_TRANSFORMS[orientation] ?? 0;
        if (transform === this._lastTransform)
            return;

        const delta = (transform - this._lastTransform + 4) % 4;
        this._lastTransform = transform;

        if (delta === 0)
            return;

        // Mutter handles the same signal in an idle callback, so the stage
        // still shows the old orientation right now.
        if (this._pending || this._container) {
            log(`[tb-rotate-anim] busy, dropping ${orientation}`);
            return;
        }

        const snapshot = this._captureStage();
        if (!snapshot)
            return;

        this._pending = {
            content: snapshot.content,
            scale: snapshot.scale,
            oldWidth: snapshot.width,
            oldHeight: snapshot.height,
            delta,
        };
        this._pendingTimeout = GLib.timeout_add(
            GLib.PRIORITY_DEFAULT, PENDING_TIMEOUT, () => {
                this._pendingTimeout = 0;
                this._pending = null;
                return GLib.SOURCE_REMOVE;
            });
    }

    _captureStage() {
        const width = global.screen_width;
        const height = global.screen_height;
        const rect = new Mtk.Rectangle({x: 0, y: 0, width, height});

        try {
            const [, , , scale] = global.stage.get_capture_final_size(rect);
            const content = global.stage.paint_to_content(
                rect, scale, null, Clutter.PaintFlag.NO_CURSORS);
            if (!content)
                return null;
            return {content, scale, width, height};
        } catch (e) {
            logError(e, '[tb-rotate-anim] failed to capture the stage');
            return null;
        }
    }

    _onMonitorsChanged() {
        if (!this._pending)
            return;

        const pending = this._pending;
        this._pending = null;
        if (this._pendingTimeout) {
            GLib.source_remove(this._pendingTimeout);
            this._pendingTimeout = 0;
        }

        const newWidth = global.screen_width;
        const newHeight = global.screen_height;

        // A rotation swaps the logical screen dimensions. If they did not
        // change, this was not an orientation-driven transform change.
        if (newWidth === pending.oldWidth && newHeight === pending.oldHeight) {
            log('[tb-rotate-anim] monitors changed without a size swap, skipping');
            return;
        }

        const config = this._config;
        const angle = pending.delta * 90;
        log(`[tb-rotate-anim] rotating ${angle}deg, ` +
            `${pending.oldWidth}x${pending.oldHeight} -> ${newWidth}x${newHeight}, ` +
            `${config.duration_ms}+${config.fade_ms}ms`);

        // Everything lives in one container so the final fade also hides the
        // dark backdrop.  The container is sized to the new stage.
        const container = new Clutter.Actor({
            x: 0,
            y: 0,
            width: newWidth,
            height: newHeight,
            opacity: 255,
        });

        // Opaque black base: nothing of the new screen can show through while
        // the old screenshot is still rotating.
        const black = new St.Widget({
            x: 0,
            y: 0,
            width: newWidth,
            height: newHeight,
            style: 'background-color: black;',
        });
        container.add_child(black);

        // Dimmed copy of the old screen, scaled to cover the new stage.  It
        // makes the corners look like the old screen turning away instead of
        // the new top bar appearing first.
        const coverScale = Math.max(
            newWidth / pending.oldWidth, newHeight / pending.oldHeight);
        const backdrop = new St.Widget({
            width: pending.oldWidth,
            height: pending.oldHeight,
            x: (newWidth - pending.oldWidth) / 2,
            y: (newHeight - pending.oldHeight) / 2,
            pivot_point: new Graphene.Point({x: 0.5, y: 0.5}),
            scale_x: coverScale,
            scale_y: coverScale,
            opacity: Math.round(255 * (1 - config.backdrop_dim)),
        });
        backdrop.set_content(pending.content);
        container.add_child(backdrop);

        // The old screenshot itself, rotated to exactly reproduce what the
        // panel showed before the transform changed.
        const overlay = new St.Widget({
            width: pending.oldWidth,
            height: pending.oldHeight,
            x: (newWidth - pending.oldWidth) / 2,
            y: (newHeight - pending.oldHeight) / 2,
            pivot_point: new Graphene.Point({x: 0.5, y: 0.5}),
            rotation_angle_z: angle,
            scale_x: START_SCALE,
            scale_y: START_SCALE,
            opacity: 255,
            reactive: true,
            visible: true,
        });
        overlay.set_content(pending.content);
        container.add_child(overlay);

        Main.uiGroup.add_child(container);
        Main.uiGroup.set_child_above_sibling(container, null);
        this._container = container;

        overlay.ease({
            rotation_angle_z: 0,
            scale_x: config.scale,
            scale_y: config.scale,
            duration: config.duration_ms,
            mode: Clutter.AnimationMode.EASE_IN_OUT_CUBIC,
        });

        this._fadeTimeout = GLib.timeout_add(
            GLib.PRIORITY_DEFAULT, config.duration_ms, () => {
                this._fadeTimeout = 0;
                if (this._container !== container)
                    return GLib.SOURCE_REMOVE;
                container.ease({
                    opacity: 0,
                    duration: config.fade_ms,
                    mode: Clutter.AnimationMode.EASE_IN_OUT_QUAD,
                    onComplete: () => this._destroyOverlay(container),
                });
                return GLib.SOURCE_REMOVE;
            });
    }

    _destroyOverlay(container = null) {
        if (!this._container)
            return;
        if (container && this._container !== container)
            return;
        const current = this._container;
        this._container = null;
        current.remove_all_transitions();
        current.destroy();
    }
}
