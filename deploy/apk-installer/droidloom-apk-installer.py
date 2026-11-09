#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Install or uninstall Android APKs in Droidloom, from a double-click or the terminal.

The graphical window is a small GTK4 frontend for ``droidloomctl install``,
``droidloomctl applications`` and ``droidloomctl uninstall``.
The same file also provides a headless mode (``--cli``), an installed-app
list (``--list``), an uninstall action (``--uninstall``) and an APK metadata
dump (``--check``) that only need the Python standard library.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pwd
import shutil
import struct
import subprocess
import sys
import threading
import time
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional

APP_NAME = "APK 安装器"
APP_ID = "org.droidloom.ApkInstaller"
VERSION = "1.1.0"
DROIDLOOMCTL = "/usr/bin/droidloomctl"
LOG_DIR = Path(os.environ.get("XDG_STATE_HOME") or (Path.home() / ".local/state")) / "droidloom-apk-installer"


# ---------------------------------------------------------------------------
# Android binary XML (AXML) parser
# ---------------------------------------------------------------------------

RES_XML_TYPE = 0x0003
RES_STRING_POOL_TYPE = 0x0001
RES_TABLE_TYPE = 0x0002
RES_TABLE_PACKAGE_TYPE = 0x0200
RES_TABLE_TYPE_TYPE = 0x0201
RES_XML_RESOURCE_MAP_TYPE = 0x0180
RES_XML_START_ELEMENT_TYPE = 0x0102

TYPE_REFERENCE = 0x01
TYPE_STRING = 0x03
TYPE_FLOAT = 0x04
TYPE_INT_DEC = 0x10
TYPE_INT_HEX = 0x11
TYPE_BOOLEAN = 0x12


class ApkError(Exception):
    pass


@dataclass(frozen=True)
class ResourceRef:
    ident: int


@dataclass
class XmlElement:
    name: str
    attrs: dict


def _read_string_pool(data: bytes, off: int) -> list[str]:
    _, header_size, size = struct.unpack_from("<HHI", data, off)
    string_count, _style_count, flags, strings_start, _styles_start = struct.unpack_from(
        "<IIIII", data, off + 8
    )
    if string_count == 0:
        return []
    offsets = struct.unpack_from(f"<{string_count}I", data, off + header_size)
    base = off + strings_start
    end = min(off + size, len(data))
    utf8 = bool(flags & 0x100)
    strings: list[str] = []
    for string_off in offsets:
        pos = base + string_off
        if pos >= end:
            strings.append("")
            continue
        try:
            if utf8:
                length = data[pos]
                pos += 1
                if length & 0x80:
                    length = ((length & 0x7F) << 8) | data[pos]
                    pos += 1
                byte_length = data[pos]
                pos += 1
                if byte_length & 0x80:
                    byte_length = ((byte_length & 0x7F) << 8) | data[pos]
                    pos += 1
                strings.append(data[pos : pos + byte_length].decode("utf-8", "replace"))
            else:
                length = struct.unpack_from("<H", data, pos)[0]
                pos += 2
                if length & 0x8000:
                    length = ((length & 0x7FFF) << 16) | struct.unpack_from("<H", data, pos)[0]
                    pos += 2
                strings.append(data[pos : pos + length * 2].decode("utf-16-le", "replace"))
        except (IndexError, struct.error):
            strings.append("")
    return strings


def _typed_value(raw: int, data_type: int, data_value: int, strings: list[str]):
    if raw != 0xFFFFFFFF and raw < len(strings):
        return strings[raw]
    if data_type == TYPE_STRING:
        return strings[data_value] if data_value < len(strings) else ""
    if data_type == TYPE_REFERENCE:
        return ResourceRef(data_value)
    if data_type in (TYPE_INT_DEC, TYPE_INT_HEX):
        return data_value
    if data_type == TYPE_BOOLEAN:
        return bool(data_value)
    if data_type == TYPE_FLOAT:
        return struct.unpack("<f", struct.pack("<I", data_value))[0]
    return data_value


def parse_axml(data: bytes) -> list[XmlElement]:
    if len(data) < 8:
        raise ApkError("AndroidManifest.xml 为空")
    chunk_type, header_size, total_size = struct.unpack_from("<HHI", data, 0)
    if chunk_type != RES_XML_TYPE:
        raise ApkError("AndroidManifest.xml 不是二进制 XML")
    strings: list[str] = []
    resource_ids: list[int] = []
    elements: list[XmlElement] = []
    off = max(header_size, 8)
    end = min(total_size, len(data))
    while off + 8 <= end:
        chunk_type, chunk_header, chunk_size = struct.unpack_from("<HHI", data, off)
        if chunk_size < 8 or off + chunk_size > end:
            break
        if chunk_type == RES_STRING_POOL_TYPE:
            strings = _read_string_pool(data, off)
        elif chunk_type == RES_XML_RESOURCE_MAP_TYPE:
            count = max(0, (chunk_size - chunk_header) // 4)
            if count:
                resource_ids = list(struct.unpack_from(f"<{count}I", data, off + chunk_header))
        elif chunk_type == RES_XML_START_ELEMENT_TYPE:
            ns_idx, name_idx = struct.unpack_from("<II", data, off + 16)
            (
                attr_start,
                attr_size,
                attr_count,
                _id_index,
                _class_index,
                _style_index,
            ) = struct.unpack_from("<HHHHHH", data, off + 24)
            name = strings[name_idx] if name_idx < len(strings) else ""
            attrs: dict = {}
            if attr_size >= 20:
                base = off + 16 + attr_start
                for index in range(attr_count):
                    pos = base + index * attr_size
                    if pos + 20 > off + chunk_size:
                        break
                    _attr_ns, attr_name_idx, raw_idx = struct.unpack_from("<III", data, pos)
                    _typed_size, _res0, data_type, data_value = struct.unpack_from(
                        "<HBBI", data, pos + 12
                    )
                    attr_name = strings[attr_name_idx] if attr_name_idx < len(strings) else ""
                    if not attr_name:
                        res_id = (
                            resource_ids[attr_name_idx]
                            if attr_name_idx < len(resource_ids)
                            else None
                        )
                        attr_name = f"0x{res_id:08x}" if res_id else f"attr{attr_name_idx}"
                    attrs[attr_name] = _typed_value(raw_idx, data_type, data_value, strings)
            elements.append(XmlElement(name=name, attrs=attrs))
        off += chunk_size
    return elements


def _as_string(value) -> Optional[str]:
    return value if isinstance(value, str) and value else None


def _as_int(value) -> Optional[int]:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        try:
            return int(value, 0)
        except ValueError:
            return None
    return None


def _resolve_string_resource(table: bytes, resource_id: int) -> Optional[str]:
    """Resolve one string resource from resources.arsc (default config first)."""
    if len(table) < 12:
        return None
    chunk_type, header_size, total_size = struct.unpack_from("<HHI", table, 0)
    if chunk_type != RES_TABLE_TYPE:
        return None
    package_id = (resource_id >> 24) & 0xFF
    type_id = (resource_id >> 16) & 0xFF
    entry_id = resource_id & 0xFFFF
    global_strings: list[str] = []
    fallback: Optional[str] = None
    off = max(header_size, 12)
    end = min(total_size, len(table))
    while off + 8 <= end:
        chunk_type, chunk_header, chunk_size = struct.unpack_from("<HHI", table, off)
        if chunk_size < 8 or off + chunk_size > end:
            break
        if chunk_type == RES_STRING_POOL_TYPE:
            global_strings = _read_string_pool(table, off)
        elif chunk_type == RES_TABLE_PACKAGE_TYPE:
            try:
                package = struct.unpack_from("<I", table, off + 8)[0]
            except struct.error:
                package = -1
            if package == package_id:
                inner = off + chunk_header
                package_end = off + chunk_size
                while inner + 8 <= package_end:
                    inner_type, inner_header, inner_size = struct.unpack_from(
                        "<HHI", table, inner
                    )
                    if inner_size < 8 or inner + inner_size > package_end:
                        break
                    if (
                        inner_type == RES_TABLE_TYPE_TYPE
                        and table[inner + 8] == type_id
                        and not (table[inner + 9] & 0x03)  # sparse/offset16 unsupported
                    ):
                        try:
                            entry_count, entries_start = struct.unpack_from(
                                "<II", table, inner + 12
                            )
                        except struct.error:
                            entry_count = 0
                            entries_start = 0
                        if entry_id < entry_count:
                            offsets_at = inner + inner_header + entry_id * 4
                            if offsets_at + 4 <= inner + inner_size:
                                entry_offset = struct.unpack_from("<I", table, offsets_at)[0]
                                if entry_offset != 0xFFFFFFFF:
                                    pos = inner + entries_start + entry_offset
                                    if pos + 8 <= inner + inner_size:
                                        entry_size, entry_flags, _key = struct.unpack_from(
                                            "<HHI", table, pos
                                        )
                                        value_pos = pos + entry_size
                                        if (
                                            not (entry_flags & 1)
                                            and entry_size >= 8
                                            and value_pos + 8 <= inner + inner_size
                                        ):
                                            _size, _res0, data_type, data_value = (
                                                struct.unpack_from("<HBBI", table, value_pos)
                                            )
                                            if (
                                                data_type == TYPE_STRING
                                                and data_value < len(global_strings)
                                            ):
                                                value = global_strings[data_value]
                                                config_size = struct.unpack_from(
                                                    "<I", table, inner + 20
                                                )[0]
                                                config = table[
                                                    inner + 24 : inner + 20 + config_size
                                                ]
                                                if not any(config):
                                                    return value
                                                if fallback is None:
                                                    fallback = value
                    inner += inner_size
        off += chunk_size
    return fallback


def read_apk_metadata(path: Path) -> dict:
    try:
        stat = path.stat()
    except OSError as error:
        raise ApkError(f"无法读取文件：{error}") from error
    if not path.is_file():
        raise ApkError("不是普通文件")
    if stat.st_size < 4:
        raise ApkError("文件太小，不是 APK")
    with path.open("rb") as handle:
        if handle.read(4) != b"PK\x03\x04":
            raise ApkError("不是 APK（ZIP 头不正确）")
    try:
        with zipfile.ZipFile(path) as archive:
            names = archive.namelist()
            if "AndroidManifest.xml" not in names:
                raise ApkError("不是有效的 APK：缺少 AndroidManifest.xml")
            manifest = archive.read("AndroidManifest.xml")
            abis = sorted(
                {
                    name.split("/")[1]
                    for name in names
                    if name.startswith("lib/") and name.count("/") >= 2 and name.split("/")[1]
                }
            )
    except zipfile.BadZipFile as error:
        raise ApkError(f"APK 的 ZIP 结构损坏：{error}") from error
    elements = parse_axml(manifest)
    manifest_element = next((element for element in elements if element.name == "manifest"), None)
    if manifest_element is None:
        raise ApkError("AndroidManifest.xml 中找不到 <manifest>")

    package = _as_string(manifest_element.attrs.get("package"))
    version_name = _as_string(manifest_element.attrs.get("versionName"))
    version_code = _as_int(manifest_element.attrs.get("versionCode"))
    label = None
    label_ref = None
    icon = None
    min_sdk = None
    target_sdk = None
    permissions: list[str] = []
    for element in elements:
        if element.name == "uses-sdk":
            min_sdk = _as_int(element.attrs.get("minSdkVersion")) or min_sdk
            target_sdk = _as_int(element.attrs.get("targetSdkVersion")) or target_sdk
        elif element.name == "application":
            label_value = element.attrs.get("label")
            if isinstance(label_value, str) and label_value:
                label = label or label_value
            elif isinstance(label_value, ResourceRef):
                label_ref = label_ref or label_value.ident
            icon = _as_string(element.attrs.get("icon")) or icon
        elif element.name in ("uses-permission", "uses-permission-sdk-23"):
            permission = _as_string(element.attrs.get("name"))
            if permission and permission not in permissions:
                permissions.append(permission)
    # Resolving a label reference needs the whole resources.arsc, which can be
    # hundreds of megabytes in big games.  Keep the pre-install window quick;
    # the Android catalog supplies the real label after installation.
    if (
        label is None
        and label_ref is not None
        and stat.st_size <= 64 * 1024 * 1024
    ):
        try:
            with zipfile.ZipFile(path) as archive:
                if "resources.arsc" in archive.namelist():
                    label = _resolve_string_resource(
                        archive.read("resources.arsc"), label_ref
                    ) or None
        except (OSError, zipfile.BadZipFile, struct.error):
            label = None
    return {
        "path": str(path),
        "size": stat.st_size,
        "package": package,
        "version_name": version_name,
        "version_code": version_code,
        "label": label,
        "icon": icon,
        "min_sdk": min_sdk,
        "target_sdk": target_sdk,
        "abis": abis,
        "permissions": permissions,
    }


def display_name(meta: dict, path: Path) -> str:
    if meta.get("label"):
        return meta["label"]
    package = meta.get("package")
    if package:
        tail = package.rsplit(".", 1)[-1]
        pretty = tail.replace("_", " ").replace("-", " ").strip()
        if pretty and len(pretty) > 2:
            return pretty[:1].upper() + pretty[1:]
        if path.stem:
            return path.stem
        return package
    return path.stem


def human_size(size: int) -> str:
    value = float(size)
    for unit in ("B", "KiB", "MiB", "GiB"):
        if value < 1024 or unit == "GiB":
            return f"{value:.0f} {unit}" if unit == "B" else f"{value:.1f} {unit}"
        value /= 1024
    return f"{size} B"


# ---------------------------------------------------------------------------
# Droidloom control
# ---------------------------------------------------------------------------


class InstallError(Exception):
    pass


def _desktop_user() -> str:
    try:
        config = json.loads(Path("/etc/droidloom/cell.json").read_text(encoding="utf-8"))
        uid = int(config.get("host_uid", 1000))
        return pwd.getpwuid(uid).pw_name
    except Exception:
        return "alarm"


def _start_command() -> list[str]:
    command = [DROIDLOOMCTL, "start"]
    if os.geteuid() == 0:
        runuser = shutil.which("runuser") or "/usr/sbin/runuser"
        command = [runuser, "-u", _desktop_user(), "--"] + command
    return command


def _run_streaming(command: list[str], report: Callable[[str], None], timeout: float = 240.0):
    try:
        process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
        )
    except OSError as error:
        raise InstallError(f"无法运行 {command[0]}：{error}") from error
    timer = threading.Timer(timeout, process.kill)
    timer.daemon = True
    timer.start()
    lines: list[str] = []
    try:
        assert process.stdout is not None
        for raw in process.stdout:
            line = raw.rstrip()
            if line:
                lines.append(line)
                report(line)
        code = process.wait()
    finally:
        timer.cancel()
    return code, "\n".join(lines)


def run_install(path: Path, report: Callable[[str], None]) -> str:
    command = [DROIDLOOMCTL, "install", str(path), "--user", "0"]
    code, output = _run_streaming(command, report)
    if code != 0 and _is_stopped(output):
        report("Android 未运行，正在启动 Droidloom…")
        start_code, start_output = _run_streaming(_start_command(), report, timeout=300.0)
        if start_code != 0:
            raise InstallError("启动 Android 失败：\n" + (start_output.strip() or f"退出码 {start_code}"))
        report("Android 已启动，重新安装…")
        code, output = _run_streaming(command, report)
    if code != 0 or "APK installed successfully" not in output:
        detail = output.strip() or f"droidloomctl 退出码 {code}"
        raise InstallError(detail)
    return output


def find_catalog_app(package: Optional[str], timeout: float = 12.0) -> Optional[dict]:
    if not package:
        return None
    deadline = time.monotonic() + timeout
    while True:
        try:
            result = subprocess.run(
                [DROIDLOOMCTL, "applications", "--json"],
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=10,
            )
            if result.returncode == 0:
                payload = json.loads(result.stdout)
                for application in payload.get("applications", []):
                    if application.get("package") == package:
                        return application
        except (OSError, subprocess.SubprocessError, ValueError):
            pass
        if time.monotonic() >= deadline:
            return None
        time.sleep(0.4)


def _is_stopped(output: str) -> bool:
    """True when droidloomctl failed because no daemon is listening."""
    lowered = output.lower()
    return (
        "not running" in lowered
        or "connect to droidloomd" in lowered
        or "no such file or directory" in lowered
    )


def list_catalog_apps() -> list[dict]:
    """Return the launcher catalog's installed Android applications."""
    result = subprocess.run(
        [DROIDLOOMCTL, "applications", "--json"],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=20,
    )
    if result.returncode != 0:
        detail = (
            (result.stdout + result.stderr).strip()
            or f"droidloomctl 退出码 {result.returncode}"
        )
        raise InstallError(detail)
    try:
        payload = json.loads(result.stdout)
    except ValueError as error:
        raise InstallError(f"无法解析应用列表：{error}") from error
    applications = payload.get("applications")
    if not isinstance(applications, list):
        raise InstallError("应用列表格式不正确")
    return [app for app in applications if isinstance(app, dict)]


def load_catalog_apps(report: Callable[[str], None]) -> list[dict]:
    """Like list_catalog_apps(), starting Droidloom once when it is stopped."""
    try:
        return list_catalog_apps()
    except InstallError as error:
        if not _is_stopped(str(error)):
            raise
    report("Android 未运行，正在启动 Droidloom…")
    code, output = _run_streaming(_start_command(), report, timeout=300.0)
    if code != 0:
        raise InstallError(
            "启动 Android 失败：\n" + (output.strip() or f"退出码 {code}")
        )
    report("Android 已启动，读取应用列表…")
    return list_catalog_apps()


def run_uninstall(package: str, report: Callable[[str], None]) -> str:
    """Uninstall one Android package through droidloomctl."""
    command = [DROIDLOOMCTL, "uninstall", package, "--user", "0"]
    code, output = _run_streaming(command, report)
    if code != 0 and _is_stopped(output):
        report("Android 未运行，正在启动 Droidloom…")
        start_code, start_output = _run_streaming(_start_command(), report, timeout=300.0)
        if start_code != 0:
            raise InstallError(
                "启动 Android 失败：\n" + (start_output.strip() or f"退出码 {start_code}")
            )
        report("Android 已启动，重新卸载…")
        code, output = _run_streaming(command, report)
    if code != 0:
        raise InstallError(output.strip() or f"droidloomctl 退出码 {code}")
    return output


def _icon_home() -> Path:
    if os.geteuid() == 0:
        try:
            config = json.loads(Path("/etc/droidloom/cell.json").read_text(encoding="utf-8"))
            return Path(pwd.getpwuid(int(config.get("host_uid", 1000))).pw_dir)
        except Exception:
            pass
    return Path.home()


def find_app_icon(application: dict, user: int = 0) -> Optional[Path]:
    home = _icon_home()
    component = application.get("component") or ""
    if component:
        app_id = hashlib.sha256(
            struct.pack("<I", user) + b"\0" + component.encode("utf-8")
        ).hexdigest()[:32]
        for size in (128, 256, 64, 512):
            candidate = (
                home / ".local/share/icons/hicolor" / f"{size}x{size}" / "apps"
                / f"droidloom-{app_id}.png"
            )
            if candidate.is_file():
                return candidate
    package = application.get("package")
    try:
        for desktop in (home / ".local/share/applications").glob("droidloom-*.desktop"):
            text = desktop.read_text(encoding="utf-8", errors="replace")
            if package and f"X-Droidloom-Package={package}" not in text:
                continue
            for line in text.splitlines():
                if line.startswith("Icon="):
                    icon = line[5:].strip()
                    for size in (128, 256, 64, 512):
                        candidate = (
                            home / ".local/share/icons/hicolor" / f"{size}x{size}" / "apps"
                            / f"{icon}.png"
                        )
                        if candidate.is_file():
                            return candidate
    except OSError:
        pass
    return None


def launch_application(application: dict) -> None:
    command = [DROIDLOOMCTL, "launch", application["package"], "--user", "0"]
    if application.get("component"):
        command += ["--component", application["component"]]
    result = subprocess.run(
        command,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=30,
    )
    if result.returncode != 0:
        detail = (result.stdout + result.stderr).strip() or f"退出码 {result.returncode}"
        raise InstallError(detail)


# ---------------------------------------------------------------------------
# GTK4 frontend
# ---------------------------------------------------------------------------


def run_gui(apk_path: Optional[str], auto_install: bool) -> int:
    try:
        import gi

        gi.require_version("Gtk", "4.0")
        gi.require_version("Gdk", "4.0")
        from gi.repository import Gdk, Gio, GLib, Gtk
    except (ImportError, ValueError) as error:
        print(f"缺少 GTK4/PyGObject：{error}\n请使用 --cli 在终端安装。", file=sys.stderr)
        return 1

    css = """
    .apk-card {
        background: alpha(currentColor, 0.06);
        border-radius: 14px;
        padding: 18px;
    }
    .apk-title {
        font-size: 1.45em;
        font-weight: 700;
    }
    .apk-dim {
        opacity: 0.66;
    }
    .apk-success {
        color: #2ec27e;
        font-weight: 600;
    }
    .apk-error {
        color: #e01b24;
        font-weight: 600;
    }
    .apk-row {
        padding: 8px 4px;
    }
    .apk-row-name {
        font-weight: 600;
    }
    """

    class InstallerWindow(Gtk.ApplicationWindow):
        def __init__(self, application: Gtk.Application):
            super().__init__(application=application, title=APP_NAME)
            self.set_default_size(680, 650)
            self.set_size_request(540, 480)
            self.path: Optional[Path] = None
            self.meta: Optional[dict] = None
            self.installed_app: Optional[dict] = None
            self._busy = False
            self._installed_loading = False
            self._uninstalling = False
            self._auto_install = auto_install
            self._pulse_source: Optional[int] = None
            self._log_lines: list[str] = []
            self._log_handle = None
            self._build_ui()
            if apk_path:
                GLib.idle_add(self.load_path, apk_path)

        # -- construction -------------------------------------------------

        def _build_ui(self) -> None:
            provider = Gtk.CssProvider()
            provider.load_from_data(css.encode("utf-8"))
            display = Gdk.Display.get_default()
            if display is not None:
                Gtk.StyleContext.add_provider_for_display(
                    display, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
                )

            header = Gtk.HeaderBar()
            header.set_show_title_buttons(True)
            installed_button = Gtk.Button(label="已安装应用")
            installed_button.connect("clicked", self._show_installed_page)
            header.pack_end(installed_button)
            self.set_titlebar(header)

            self.stack = Gtk.Stack()
            self.stack.set_transition_type(Gtk.StackTransitionType.CROSSFADE)
            self.stack.set_vexpand(True)

            self.stack.add_named(self._build_empty_page(), "empty")
            self.stack.add_named(self._build_file_page(), "file")
            self.stack.add_named(self._build_installed_page(), "installed")
            self.set_child(self.stack)

            drop = Gtk.DropTarget.new(Gdk.FileList, Gdk.DragAction.COPY)
            drop.connect("drop", self._on_drop)
            self.add_controller(drop)

        def _build_empty_page(self) -> Gtk.Widget:
            box = Gtk.Box(
                orientation=Gtk.Orientation.VERTICAL,
                spacing=12,
                valign=Gtk.Align.CENTER,
                halign=Gtk.Align.CENTER,
                margin_top=24,
                margin_bottom=24,
                margin_start=24,
                margin_end=24,
            )
            icon = Gtk.Image.new_from_icon_name("application-x-executable")
            icon.set_pixel_size(96)
            title = Gtk.Label(label="把 APK 拖到这里")
            title.add_css_class("apk-title")
            subtitle = Gtk.Label(
                label="或点击下面的按钮选择文件\n安装完成后会直接出现在应用列表里"
            )
            subtitle.add_css_class("apk-dim")
            subtitle.set_justify(Gtk.Justification.CENTER)
            choose = Gtk.Button(label="选择 APK…")
            choose.add_css_class("suggested-action")
            choose.add_css_class("pill")
            choose.set_halign(Gtk.Align.CENTER)
            choose.connect("clicked", self._choose_file)
            box.append(icon)
            box.append(title)
            box.append(subtitle)
            box.append(choose)
            return box

        def _build_file_page(self) -> Gtk.Widget:
            page = Gtk.Box(
                orientation=Gtk.Orientation.VERTICAL,
                spacing=12,
                margin_top=16,
                margin_bottom=16,
                margin_start=18,
                margin_end=18,
            )

            content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
            card = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=18)
            card.add_css_class("apk-card")
            self.app_icon = Gtk.Image.new_from_icon_name("application-x-executable")
            self.app_icon.set_pixel_size(76)
            self.app_icon.set_valign(Gtk.Align.START)
            info = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
            info.set_hexpand(True)
            self.name_label = Gtk.Label(xalign=0)
            self.name_label.add_css_class("apk-title")
            self.name_label.set_wrap(True)
            self.package_label = Gtk.Label(xalign=0)
            self.package_label.add_css_class("apk-dim")
            self.package_label.set_selectable(True)
            self.meta_label = Gtk.Label(xalign=0)
            self.meta_label.add_css_class("apk-dim")
            self.meta_label.set_wrap(True)
            info.append(self.name_label)
            info.append(self.package_label)
            info.append(self.meta_label)
            card.append(self.app_icon)
            card.append(info)
            content.append(card)

            self.banner = Gtk.Label(xalign=0)
            self.banner.set_wrap(True)
            self.banner.set_visible(False)
            content.append(self.banner)

            details = Gtk.Expander(label="详细信息")
            grid = Gtk.Grid(column_spacing=18, row_spacing=6, margin_top=8, margin_start=6)
            self.detail_values = {}
            rows = [
                ("文件", "path"),
                ("大小", "size"),
                ("包名", "package"),
                ("版本", "version"),
                ("SDK", "sdk"),
                ("架构", "abis"),
                ("权限", "permissions"),
            ]
            for row, (label, key) in enumerate(rows):
                name = Gtk.Label(label=label, xalign=0)
                name.add_css_class("apk-dim")
                value = Gtk.Label(label="", xalign=0)
                value.set_selectable(True)
                value.set_wrap(True)
                grid.attach(name, 0, row, 1, 1)
                grid.attach(value, 1, row, 1, 1)
                self.detail_values[key] = value
            details.set_child(grid)
            content.append(details)

            status_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
            self.spinner = Gtk.Spinner()
            self.status_label = Gtk.Label(label="", xalign=0)
            self.status_label.set_wrap(True)
            self.status_label.set_hexpand(True)
            status_box.append(self.spinner)
            status_box.append(self.status_label)
            content.append(status_box)

            self.progress = Gtk.ProgressBar()
            self.progress.set_visible(False)
            content.append(self.progress)

            self.log_expander = Gtk.Expander(label="安装日志")
            self.log_expander.set_expanded(False)
            self.log_view = Gtk.TextView()
            self.log_view.set_editable(False)
            self.log_view.set_cursor_visible(False)
            self.log_view.set_monospace(True)
            self.log_view.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
            scroller = Gtk.ScrolledWindow()
            scroller.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
            scroller.set_min_content_height(120)
            scroller.set_child(self.log_view)
            self.log_expander.set_child(scroller)
            content.append(self.log_expander)

            content_scroller = Gtk.ScrolledWindow()
            content_scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
            content_scroller.set_vexpand(True)
            content_scroller.set_child(content)
            page.append(content_scroller)

            actions = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
            self.choose_button = Gtk.Button(label="选择其他 APK")
            self.choose_button.connect("clicked", self._choose_file)
            actions.append(self.choose_button)
            expand = Gtk.Box()
            expand.set_hexpand(True)
            actions.append(expand)
            self.install_button = Gtk.Button(label="安装")
            self.install_button.add_css_class("suggested-action")
            self.install_button.connect("clicked", self.start_install)
            self.cancel_button = Gtk.Button(label="取消")
            self.cancel_button.connect("clicked", lambda *_: self.close())
            self.open_button = Gtk.Button(label="打开应用")
            self.open_button.add_css_class("suggested-action")
            self.open_button.set_visible(False)
            self.open_button.connect("clicked", self._open_app)
            self.done_button = Gtk.Button(label="完成")
            self.done_button.set_visible(False)
            self.done_button.connect("clicked", lambda *_: self.close())
            actions.append(self.install_button)
            actions.append(self.cancel_button)
            actions.append(self.open_button)
            actions.append(self.done_button)
            page.append(actions)
            return page

        # -- installed apps ------------------------------------------------

        def _build_installed_page(self) -> Gtk.Widget:
            page = Gtk.Box(
                orientation=Gtk.Orientation.VERTICAL,
                spacing=12,
                margin_top=16,
                margin_bottom=16,
                margin_start=18,
                margin_end=18,
            )

            title_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
            title = Gtk.Label(label="已安装的 Android 应用", xalign=0)
            title.add_css_class("apk-title")
            title.set_hexpand(True)
            self.installed_spinner = Gtk.Spinner()
            refresh = Gtk.Button(label="刷新")
            refresh.connect("clicked", lambda *_: self.load_installed())
            title_box.append(title)
            title_box.append(self.installed_spinner)
            title_box.append(refresh)
            page.append(title_box)

            self.installed_status = Gtk.Label(label="", xalign=0)
            self.installed_status.add_css_class("apk-dim")
            self.installed_status.set_wrap(True)
            page.append(self.installed_status)

            self.installed_list = Gtk.ListBox()
            self.installed_list.set_selection_mode(Gtk.SelectionMode.NONE)
            self.installed_list.set_show_separators(True)
            scroller = Gtk.ScrolledWindow()
            scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
            scroller.set_vexpand(True)
            scroller.set_child(self.installed_list)
            page.append(scroller)

            actions = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
            back = Gtk.Button(label="安装 APK…")
            back.connect("clicked", self._show_install_page)
            actions.append(back)
            page.append(actions)
            return page

        def _show_installed_page(self, *_args) -> None:
            self.stack.set_visible_child_name("installed")
            self.load_installed()

        def _show_install_page(self, *_args) -> None:
            self.stack.set_visible_child_name("empty")

        def load_installed(self) -> None:
            if self._installed_loading or self._uninstalling:
                return
            self._installed_loading = True
            self.installed_status.set_text("正在读取应用列表…")
            self.installed_spinner.start()
            self._clear_installed_rows()
            threading.Thread(target=self._load_installed_worker, daemon=True).start()

        def _load_installed_worker(self) -> None:
            try:
                applications = load_catalog_apps(self._post_installed_status)
                GLib.idle_add(self._show_installed, applications, None)
            except Exception as error:  # noqa: BLE001 - shown to the user
                GLib.idle_add(self._show_installed, [], str(error))

        def _post_installed_status(self, text: str) -> None:
            GLib.idle_add(self.installed_status.set_text, text)

        def _clear_installed_rows(self) -> None:
            child = self.installed_list.get_first_child()
            while child is not None:
                next_child = child.get_next_sibling()
                self.installed_list.remove(child)
                child = next_child

        def _show_installed(self, applications: list[dict], error: Optional[str]) -> bool:
            self._installed_loading = False
            self.installed_spinner.stop()
            if error:
                self.installed_status.set_text(f"读取失败：{error}")
                return False
            unique: dict[str, dict] = {}
            for application in applications:
                key = (
                    application.get("package")
                    or application.get("component")
                    or application.get("name")
                )
                if key:
                    unique.setdefault(key, application)
            ordered = sorted(
                unique.values(),
                key=lambda app: (app.get("name") or app.get("package") or "").casefold(),
            )
            if not ordered:
                self.installed_status.set_text("没有已安装的 Android 应用。")
                return False
            self.installed_status.set_text(f"共 {len(ordered)} 个应用。")
            for application in ordered:
                self.installed_list.append(self._make_installed_row(application))
            return False

        def _make_installed_row(self, application: dict) -> Gtk.ListBoxRow:
            row = Gtk.ListBoxRow()
            row.add_css_class("apk-row")
            box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
            icon = Gtk.Image.new_from_icon_name("application-x-executable")
            icon.set_pixel_size(40)
            icon_path = find_app_icon(application)
            if icon_path:
                icon.set_from_file(str(icon_path))
            info = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
            info.set_hexpand(True)
            name = Gtk.Label(
                label=application.get("name") or application.get("package") or "?",
                xalign=0,
            )
            name.add_css_class("apk-row-name")
            package = Gtk.Label(label=application.get("package") or "", xalign=0)
            package.add_css_class("apk-dim")
            package.set_selectable(True)
            info.append(name)
            info.append(package)
            remove = Gtk.Button(label="卸载")
            remove.add_css_class("destructive-action")
            remove.connect("clicked", lambda *_: self._confirm_uninstall(application))
            box.append(icon)
            box.append(info)
            box.append(remove)
            row.set_child(box)
            return row

        def _confirm_uninstall(self, application: dict) -> None:
            name = application.get("name") or application.get("package") or "?"
            package = application.get("package") or ""
            dialog = Gtk.AlertDialog()
            dialog.set_modal(True)
            dialog.set_message(f"卸载 {name}？")
            dialog.set_detail(f"{package}\n应用的 Android 数据也会被删除。")
            dialog.set_buttons(["取消", "卸载"])
            dialog.set_cancel_button(0)
            dialog.set_default_button(0)
            dialog.choose(self, None, self._on_uninstall_choice, application)

        def _on_uninstall_choice(self, dialog, result, application) -> None:
            try:
                choice = dialog.choose_finish(result)
            except GLib.Error:
                return
            if choice == 1:
                self._start_uninstall(application)

        def _start_uninstall(self, application: dict) -> None:
            if self._uninstalling or self._installed_loading:
                return
            package = application.get("package")
            if not package:
                return
            self._uninstalling = True
            name = application.get("name") or package
            self.installed_status.set_text(f"正在卸载 {name}…")
            self.installed_spinner.start()
            self._open_log_file()
            self._append_log(f"$ {DROIDLOOMCTL} uninstall {package}")
            threading.Thread(
                target=self._uninstall_worker, args=(application,), daemon=True
            ).start()

        def _uninstall_worker(self, application: dict) -> None:
            try:
                run_uninstall(application["package"], self._post_log)
                GLib.idle_add(self._uninstall_done, application, None)
            except Exception as error:  # noqa: BLE001 - shown to the user
                GLib.idle_add(self._uninstall_done, application, str(error))

        def _uninstall_done(self, application: dict, error: Optional[str]) -> bool:
            self._uninstalling = False
            self.installed_spinner.stop()
            self._close_log_file()
            name = application.get("name") or application.get("package") or "?"
            if error:
                self.installed_status.set_text(f"卸载失败：{error}")
            else:
                self.installed_status.set_text(f"已卸载 {name}。")
                GLib.timeout_add(800, self._reload_installed)
            return False

        def _reload_installed(self) -> bool:
            self.load_installed()
            return False

        # -- file loading -------------------------------------------------

        def _choose_file(self, *_args) -> None:
            dialog = Gtk.FileDialog(title="选择 APK 文件", modal=True)
            file_filter = Gtk.FileFilter()
            file_filter.set_name("Android 应用包 (*.apk)")
            file_filter.add_pattern("*.apk")
            file_filter.add_mime_type("application/vnd.android.package-archive")
            filters = Gio.ListStore.new(Gtk.FileFilter)
            filters.append(file_filter)
            dialog.set_filters(filters)
            dialog.set_default_filter(file_filter)
            downloads = Path.home() / "下载"
            if downloads.is_dir():
                dialog.set_initial_folder(Gio.File.new_for_path(str(downloads)))
            dialog.open(self, None, self._on_file_dialog)

        def _on_file_dialog(self, dialog, result) -> None:
            try:
                gfile = dialog.open_finish(result)
            except GLib.Error:
                return
            path = gfile.get_path()
            if path:
                self.load_path(path)

        def _on_drop(self, _target, value, _x, _y) -> bool:
            try:
                files = value.get_files()
            except AttributeError:
                files = [value]
            if not files:
                return False
            path = files[0].get_path()
            if path:
                self.load_path(path)
                return True
            return False

        def load_path(self, path: str) -> bool:
            candidate = Path(path)
            self.path = candidate
            self.installed_app = None
            self._set_banner(None)
            self.install_button.set_visible(True)
            self.install_button.set_label("安装")
            self.install_button.set_sensitive(True)
            self.open_button.set_visible(False)
            self.done_button.set_visible(False)
            self.cancel_button.set_visible(True)
            self.status_label.set_text("")
            self.stack.set_visible_child_name("file")
            self.name_label.set_text(candidate.name)
            self.package_label.set_text("正在读取 APK…")
            self.meta_label.set_text("")
            for label in self.detail_values.values():
                label.set_text("")
            try:
                meta = read_apk_metadata(candidate)
            except (ApkError, OSError, zipfile.BadZipFile) as error:
                self.meta = None
                self.package_label.set_text("无法读取 APK")
                self.meta_label.set_text(str(error))
                self._set_banner(f"无法安装：{error}", "apk-error")
                self.install_button.set_sensitive(False)
                self._append_log(f"读取失败：{error}")
                return False
            self.meta = meta
            self.name_label.set_text(display_name(meta, candidate))
            self.package_label.set_text(meta.get("package") or "（未找到包名）")
            version = meta.get("version_name") or "未知版本"
            if meta.get("version_code") is not None:
                version += f"（{meta['version_code']}）"
            self.meta_label.set_text(f"{human_size(meta['size'])} · {version}")
            self.detail_values["path"].set_text(str(candidate))
            self.detail_values["size"].set_text(human_size(meta["size"]))
            self.detail_values["package"].set_text(meta.get("package") or "—")
            self.detail_values["version"].set_text(version)
            sdk = []
            if meta.get("min_sdk") is not None:
                sdk.append(f"minSdk {meta['min_sdk']}")
            if meta.get("target_sdk") is not None:
                sdk.append(f"targetSdk {meta['target_sdk']}")
            self.detail_values["sdk"].set_text(" · ".join(sdk) or "—")
            self.detail_values["abis"].set_text(", ".join(meta.get("abis", [])) or "未包含原生库")
            permissions = meta.get("permissions", [])
            if permissions:
                preview = ", ".join(permissions[:6])
                if len(permissions) > 6:
                    preview += f" 等 {len(permissions)} 项"
                self.detail_values["permissions"].set_text(preview)
            else:
                self.detail_values["permissions"].set_text("无")
            if candidate.suffix.lower() != ".apk":
                self._set_banner(
                    "文件扩展名不是 .apk；droidloom 只支持单一 APK，不支持 .apks/.xapk 分包。",
                    "apk-error",
                )
            self._refresh_spinner()
            if self._auto_install:
                self._auto_install = False
                GLib.timeout_add(700, self.start_install)
            return False

        # -- installing ---------------------------------------------------

        def start_install(self, *_args) -> bool:
            if self._busy or self.meta is None or self.path is None:
                return False
            self._busy = True
            self._set_banner(None)
            self.installed_app = None
            self._log_lines.clear()
            self._log_expander_reset()
            self._open_log_file()
            self._append_log(f"$ {DROIDLOOMCTL} install {self.path}")
            self._set_status("正在安装…")
            self.install_button.set_sensitive(False)
            self.choose_button.set_sensitive(False)
            self.cancel_button.set_visible(False)
            self.spinner.start()
            self.progress.set_visible(True)
            self._pulse_source = GLib.timeout_add(120, self._pulse)
            threading.Thread(target=self._install_worker, daemon=True).start()
            return False

        def _pulse(self) -> bool:
            if self._busy:
                self.progress.pulse()
                return True
            return False

        def _install_worker(self) -> None:
            assert self.path is not None
            try:
                run_install(self.path, self._post_log)
                self._post_status("正在刷新应用列表…")
                application = find_catalog_app((self.meta or {}).get("package"))
                GLib.idle_add(self._install_succeeded, application)
            except Exception as error:  # noqa: BLE001 - shown to the user
                GLib.idle_add(self._install_failed, str(error))

        def _install_succeeded(self, application: Optional[dict]) -> bool:
            self._finish_busy()
            self.installed_app = application
            if application:
                self.name_label.set_text(application.get("name") or self.name_label.get_text())
                self.package_label.set_text(application.get("package") or self.package_label.get_text())
                icon_path = find_app_icon(application)
                if icon_path:
                    self.app_icon.set_from_file(str(icon_path))
                self.open_button.set_visible(True)
                self._set_banner(f"安装成功：{application.get('name')}", "apk-success")
            else:
                self._set_banner(
                    "安装成功。这个包没有可启动的桌面活动，所以没有出现在应用列表里。",
                    "apk-success",
                )
            self.install_button.set_visible(False)
            self.choose_button.set_sensitive(True)
            self.choose_button.set_visible(True)
            self.cancel_button.set_visible(False)
            self.done_button.set_visible(True)
            self._set_status("安装完成")
            self._append_log("安装完成。")
            self._close_log_file()
            return False

        def _install_failed(self, message: str) -> bool:
            self._finish_busy()
            self._set_banner(f"安装失败：{message}", "apk-error")
            self._set_status("安装失败")
            self.install_button.set_label("重试")
            self.install_button.set_sensitive(True)
            self.install_button.set_visible(True)
            self.choose_button.set_sensitive(True)
            self.cancel_button.set_visible(True)
            self.log_expander.set_expanded(True)
            self._append_log(f"错误：{message}")
            self._close_log_file()
            return False

        def _finish_busy(self) -> None:
            self._busy = False
            self.spinner.stop()
            self.progress.set_visible(False)
            if self._pulse_source is not None:
                GLib.source_remove(self._pulse_source)
                self._pulse_source = None
            self._refresh_spinner()

        def _open_app(self, *_args) -> None:
            if not self.installed_app:
                return
            self.open_button.set_sensitive(False)
            self._set_status("正在打开应用…")
            threading.Thread(target=self._open_app_worker, args=(self.installed_app,), daemon=True).start()

        def _open_app_worker(self, application: dict) -> None:
            try:
                launch_application(application)
                GLib.idle_add(self.close)
            except Exception as error:  # noqa: BLE001
                GLib.idle_add(self._open_app_failed, str(error))

        def _open_app_failed(self, message: str) -> bool:
            self.open_button.set_sensitive(True)
            self._set_banner(f"打开失败：{message}", "apk-error")
            self._set_status("")
            return False

        # -- small helpers ------------------------------------------------

        def _refresh_spinner(self) -> None:
            self.spinner.set_visible(self._busy)
            if self._busy:
                self.spinner.start()
            else:
                self.spinner.stop()

        def _set_status(self, text: str) -> None:
            self.status_label.set_text(text)

        def _post_status(self, text: str) -> None:
            GLib.idle_add(self._set_status, text)

        def _post_log(self, line: str) -> None:
            GLib.idle_add(self._append_log, line)

        def _set_banner(self, text: Optional[str], style: Optional[str] = None) -> None:
            self.banner.set_visible(bool(text))
            self.banner.set_text(text or "")
            for css_class in ("apk-success", "apk-error"):
                self.banner.remove_css_class(css_class)
            if style:
                self.banner.add_css_class(style)

        def _log_expander_reset(self) -> None:
            buffer = self.log_view.get_buffer()
            buffer.set_text("")
            self.log_expander.set_expanded(False)

        def _append_log(self, line: str) -> bool:
            self._log_lines.append(line)
            if len(self._log_lines) > 500:
                self._log_lines = self._log_lines[-500:]
            buffer = self.log_view.get_buffer()
            buffer.set_text("\n".join(self._log_lines))
            end = buffer.get_end_iter()
            self.log_view.scroll_to_iter(end, 0.0, True, 0.0, 1.0)
            if self._log_handle is not None:
                try:
                    self._log_handle.write(line + "\n")
                    self._log_handle.flush()
                except OSError:
                    pass
            return False

        def _open_log_file(self) -> None:
            try:
                LOG_DIR.mkdir(parents=True, exist_ok=True)
                path = LOG_DIR / f"install-{time.strftime('%Y%m%d-%H%M%S')}.log"
                self._log_handle = path.open("a", encoding="utf-8")
                self._log_handle.write(f"# {time.ctime()}\n")
            except OSError:
                self._log_handle = None

        def _close_log_file(self) -> None:
            if self._log_handle is not None:
                try:
                    self._log_handle.close()
                except OSError:
                    pass
                self._log_handle = None

    class Application(Gtk.Application):
        def __init__(self):
            super().__init__(
                application_id=APP_ID,
                flags=Gio.ApplicationFlags.NON_UNIQUE,
            )

        def do_activate(self) -> None:
            window = InstallerWindow(self)
            window.present()

    application = Application()
    return application.run([sys.argv[0]])


# ---------------------------------------------------------------------------
# Terminal entry points
# ---------------------------------------------------------------------------


def print_metadata(meta: dict) -> None:
    print(f"文件:   {meta['path']}")
    print(f"大小:   {human_size(meta['size'])}")
    print(f"包名:   {meta.get('package') or '—'}")
    version = meta.get("version_name") or "—"
    if meta.get("version_code") is not None:
        version += f" ({meta['version_code']})"
    print(f"版本:   {version}")
    if meta.get("label"):
        print(f"名称:   {meta['label']}")
    sdk = []
    if meta.get("min_sdk") is not None:
        sdk.append(f"minSdk={meta['min_sdk']}")
    if meta.get("target_sdk") is not None:
        sdk.append(f"targetSdk={meta['target_sdk']}")
    print(f"SDK:    {' '.join(sdk) or '—'}")
    print(f"架构:   {', '.join(meta.get('abis', [])) or '—'}")
    print(f"权限:   {len(meta.get('permissions', []))} 项")
    sys.stdout.flush()


def cli_install(path: Path) -> int:
    try:
        meta = read_apk_metadata(path)
    except (ApkError, OSError, zipfile.BadZipFile) as error:
        print(f"无法读取 APK：{error}", file=sys.stderr)
        return 2
    print_metadata(meta)
    try:
        run_install(path, lambda line: print(f"  {line}", file=sys.stderr, flush=True))
    except InstallError as error:
        print(f"安装失败：{error}", file=sys.stderr)
        return 1
    application = find_catalog_app(meta.get("package"))
    if application:
        print(f"安装成功：{application.get('name')} ({application.get('package')})")
    else:
        print(f"安装成功：{meta.get('package') or path.name}")
    return 0


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        prog="droidloom-apk-installer",
        description="安装 Android APK 到 Droidloom（双击或命令行）",
    )
    parser.add_argument("apk", nargs="?", help="APK 文件路径")
    parser.add_argument("--cli", action="store_true", help="在终端安装，不打开窗口")
    parser.add_argument("--check", action="store_true", help="只显示 APK 信息，不安装")
    parser.add_argument("--list", action="store_true", help="列出已安装的 Android 应用")
    parser.add_argument(
        "--uninstall", metavar="PACKAGE", help="卸载已安装的 Android 应用"
    )
    parser.add_argument("--version", action="version", version=f"%(prog)s {VERSION}")
    parser.add_argument("--auto-install", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args(argv)

    report = lambda line: print(f"  {line}", file=sys.stderr, flush=True)  # noqa: E731
    if args.list:
        try:
            applications = load_catalog_apps(report)
        except InstallError as error:
            print(f"读取失败：{error}", file=sys.stderr)
            return 1
        unique: dict[str, dict] = {}
        for application in applications:
            package = application.get("package")
            if package:
                unique.setdefault(package, application)
        if not unique:
            print("没有已安装的 Android 应用。")
        else:
            for application in sorted(
                unique.values(),
                key=lambda app: (app.get("name") or app.get("package") or "").casefold(),
            ):
                print(f"{application.get('name') or '?'}\t{application.get('package')}")
        return 0

    if args.uninstall:
        try:
            run_uninstall(args.uninstall, report)
        except InstallError as error:
            print(f"卸载失败：{error}", file=sys.stderr)
            return 1
        print(f"已卸载 {args.uninstall}")
        return 0

    if args.check:
        if not args.apk:
            parser.error("--check 需要 APK 路径")
        try:
            print_metadata(read_apk_metadata(Path(args.apk)))
        except (ApkError, OSError, zipfile.BadZipFile) as error:
            print(f"无法读取 APK：{error}", file=sys.stderr)
            return 2
        return 0

    if args.cli:
        if not args.apk:
            parser.error("--cli 需要 APK 路径")
        return cli_install(Path(args.apk))

    return run_gui(args.apk, args.auto_install)


if __name__ == "__main__":
    sys.exit(main())
