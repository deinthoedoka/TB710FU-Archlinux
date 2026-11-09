// Refresh-rate mode switch for the TB710FU panel.
//
// The DSI panel has one 3200x2000@120Hz KMS mode, and switching to a real 60Hz
// mode makes it re-power and garble the picture.  Instead the shell process is
// started with libtb-refreshcap.so, which tells mutter's frame clock to schedule
// at 60Hz while KMS keeps scanning the 120Hz mode.  This extension only writes
// the mode to ~/.config/tb-display-mode and updates the Quick Settings tile.
//
// Modes:
//   adaptive - native on-demand cadence, up to 120Hz (default)
//   60       - cap the compositor frame clock at 60Hz

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import St from 'gi://St';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import * as QuickSettings from 'resource:///org/gnome/shell/ui/quickSettings.js';

const MODE_ADAPTIVE = 'adaptive';
const MODE_60 = '60';
const CONFIG_NAME = 'tb-display-mode';
const MARKER_NAME = 'tb-refreshcap-loaded';

function configPath() {
    return GLib.build_filenamev([GLib.get_user_config_dir(), CONFIG_NAME]);
}

function shimLoaded() {
    return GLib.file_test(
        GLib.build_filenamev([GLib.get_user_runtime_dir(), MARKER_NAME]),
        GLib.FileTest.EXISTS);
}

function logMessage(message) {
    log(`[tb-display-mode] ${message}`);
}

export default class DisplayModeExtension extends Extension {
    enable() {
        this._mode = this._readMode();
        this._menuItems = [];

        this._toggle = new QuickSettings.QuickMenuToggle({
            title: '刷新率',
            iconName: 'video-display-symbolic',
        });
        this._toggle.menuEnabled = true;

        this._adaptiveItem = new PopupMenu.PopupMenuItem('自适应（最高 120Hz）');
        this._adaptiveItem.connect('activate', () => this._setMode(MODE_ADAPTIVE));
        this._toggle.menu.addMenuItem(this._adaptiveItem);

        this._capItem = new PopupMenu.PopupMenuItem('60Hz 上限');
        this._capItem.connect('activate', () => this._setMode(MODE_60));
        this._toggle.menu.addMenuItem(this._capItem);

        // Tapping the tile itself flips between the two modes.
        this._toggle.connect('clicked', () => {
            this._setMode(this._mode === MODE_60 ? MODE_ADAPTIVE : MODE_60);
        });

        const quickSettings = Main.panel.statusArea.quickSettings;
        if (quickSettings) {
            quickSettings.menu.addItem(this._toggle);
            this._added = true;
        } else {
            this._addId = GLib.idle_add(GLib.PRIORITY_DEFAULT, () => {
                this._addId = 0;
                if (!this._toggle)
                    return GLib.SOURCE_REMOVE;
                const menu = Main.panel.statusArea.quickSettings;
                if (menu) {
                    menu.menu.addItem(this._toggle);
                    this._added = true;
                }
                return GLib.SOURCE_REMOVE;
            });
        }

        this._update();
        logMessage(`mode=${this._mode} shim=${shimLoaded() ? 'loaded' : 'pending'}`);
    }

    disable() {
        if (this._addId) {
            GLib.source_remove(this._addId);
            this._addId = 0;
        }
        if (this._toggle) {
            this._toggle.destroy();
            this._toggle = null;
        }
        this._added = false;
        this._menuItems = [];
    }

    _readMode() {
        try {
            const [ok, bytes] = GLib.file_get_contents(configPath());
            if (ok) {
                const text = new TextDecoder().decode(bytes).trim();
                if (text === MODE_60)
                    return MODE_60;
            }
        } catch (e) {
            // No config: adaptive is the default.
        }
        return MODE_ADAPTIVE;
    }

    _writeMode(mode) {
        const file = Gio.File.new_for_path(configPath());
        try {
            file.replace_contents(
                new TextEncoder().encode(`${mode}\n`),
                null, false,
                Gio.FileCreateFlags.REPLACE_DESTINATION,
                null);
            return true;
        } catch (e) {
            logError(e, '[tb-display-mode] failed to write the mode');
            return false;
        }
    }

    _setMode(mode) {
        if (this._writeMode(mode))
            this._mode = mode;
        this._update();
        Main.panel.closeQuickSettings();
    }

    _update() {
        if (!this._toggle)
            return;
        const is60 = this._mode === MODE_60;
        this._toggle.checked = is60;

        if (!shimLoaded()) {
            this._toggle.subtitle = is60 ? '60Hz（重启后生效）' : '自适应（重启后生效）';
        } else {
            this._toggle.subtitle = is60 ? '60Hz 上限' : '自适应';
        }

        this._adaptiveItem.setOrnament(
            is60 ? PopupMenu.Ornament.NONE : PopupMenu.Ornament.CHECK);
        this._capItem.setOrnament(
            is60 ? PopupMenu.Ornament.CHECK : PopupMenu.Ornament.NONE);
    }
}
