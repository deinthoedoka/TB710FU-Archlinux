// Touch-friendly power menu shown on a long press of the PMIC power key.
//
// tb-power-key (a small evdev daemon running as the session user) calls
// org.tb.PowerMenu.Open on the session bus.  The dialog is a shell ModalDialog,
// so it lives in modalDialogGroup above the lock screen; the same menu works
// while locked.  Buttons call systemd-logind directly (the dialog itself is the
// confirmation), with a gnome-session fallback if polkit refuses.

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import St from 'gi://St';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as ModalDialog from 'resource:///org/gnome/shell/ui/modalDialog.js';

const BUS_NAME = 'org.tb.PowerMenu';
const OBJECT_PATH = '/org/tb/PowerMenu';
const IFACE = 'org.tb.PowerMenu';

const IFACE_XML = `
<node>
  <interface name="org.tb.PowerMenu">
    <method name="Open"/>
    <method name="Close"/>
  </interface>
</node>`;

const BUTTON_HEIGHT = 64;

function logMessage(message) {
    log(`[tb-power-menu] ${message}`);
}

export default class PowerMenuExtension extends Extension {
    enable() {
        this._dialog = null;

        this._dbus = Gio.DBusExportedObject.wrapJSObject(IFACE_XML, this);
        this._dbus.export(Gio.DBus.session, OBJECT_PATH);
        this._nameId = Gio.bus_own_name_on_connection(
            Gio.DBus.session, BUS_NAME, Gio.BusNameOwnerFlags.NONE,
            null, null);
        logMessage('ready');
    }

    disable() {
        this._close();
        if (this._dbus) {
            this._dbus.unexport();
            this._dbus = null;
        }
        if (this._nameId) {
            Gio.bus_unown_name(this._nameId);
            this._nameId = 0;
        }
    }

    // Called over D-Bus by tb-power-key.
    Open() {
        this._show();
    }

    Close() {
        this._close();
    }

    _button(label, styleClass, callback) {
        const button = new St.Button({
            label,
            style_class: `tb-power-button ${styleClass}`,
            height: BUTTON_HEIGHT,
            x_expand: true,
            can_focus: true,
        });
        button.connect('clicked', callback);
        return button;
    }

    _show() {
        if (this._dialog) {
            this._dialog.open();
            return;
        }

        const dialog = new ModalDialog.ModalDialog({
            styleClass: 'tb-power-dialog',
            destroyOnClose: true,
        });

        const content = new St.BoxLayout({
            orientation: Clutter.Orientation.VERTICAL,
            style_class: 'tb-power-content',
            x_expand: true,
        });
        content.add_child(new St.Icon({
            icon_name: 'system-shutdown-symbolic',
            icon_size: 72,
            x_align: Clutter.ActorAlign.CENTER,
        }));
        content.add_child(new St.Label({
            text: '电源',
            style_class: 'tb-power-title',
            x_align: Clutter.ActorAlign.CENTER,
        }));

        const buttons = new St.BoxLayout({
            style_class: 'tb-power-buttons',
            x_expand: true,
        });
        buttons.add_child(this._button('重启', 'tb-power-reboot',
            () => this._confirm('Reboot')));
        buttons.add_child(this._button('关机', 'tb-power-off',
            () => this._confirm('PowerOff')));
        content.add_child(buttons);
        content.add_child(this._button('取消', 'tb-power-cancel',
            () => this._close()));

        dialog.contentLayout.add_child(content);
        dialog.connect('destroy', () => {
            if (this._dialog === dialog)
                this._dialog = null;
        });
        this._dialog = dialog;
        dialog.open();
        logMessage('opened');
    }

    _close() {
        if (this._dialog) {
            this._dialog.close();
            this._dialog = null;
        }
    }

    _confirm(action) {
        this._close();
        logMessage(`${action} requested`);
        Gio.DBus.system.call(
            'org.freedesktop.login1',
            '/org/freedesktop/login1',
            'org.freedesktop.login1.Manager',
            action,
            new GLib.Variant('(b)', [false]),
            null,
            Gio.DBusCallFlags.NONE,
            -1,
            null,
            (connection, result) => {
                try {
                    connection.call_finish(result);
                } catch (e) {
                    logError(e, `[tb-power-menu] ${action} denied`);
                    this._sessionFallback(action, e);
                }
            });
    }

    // If logind/polkit refuses, go through gnome-session, which shows the
    // regular GNOME confirmation dialog.
    _sessionFallback(action, error) {
        const method = action === 'Reboot' ? 'Reboot' : 'Shutdown';
        Gio.DBus.session.call(
            'org.gnome.SessionManager',
            '/org/gnome/SessionManager',
            'org.gnome.SessionManager',
            method,
            null,
            null,
            Gio.DBusCallFlags.NONE,
            -1,
            null,
            (connection, result) => {
                try {
                    connection.call_finish(result);
                } catch (fallbackError) {
                    logError(fallbackError,
                        `[tb-power-menu] session ${method} failed`);
                    Main.notifyError('电源操作失败',
                        `${error.message}; ${fallbackError.message}`);
                }
            });
    }
}
