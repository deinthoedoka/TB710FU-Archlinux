#!/usr/bin/env python3
"""make-boot.py - produce TB710FU boot_a variants from the device's live boot image.

The deployed boot_a is a DBKP PackedKernel: [GKI][Shim][Arch Image][DTB][Manifest]
inside the Android boot v4 kernel slot.  The kernel receives its command line from
the DTB's /chosen/bootargs (the boot header cmdline is not forwarded by kShim), so
each variant rewrites that property and repacks the DTB/manifest tail.  The GKI,
shim and Arch kernel stay byte-identical.

Variants produced:
  boot_arch.img           dual boot, menu default Arch, 8 s countdown
  boot_zui.img            dual boot, menu default ZUXOS, 8 s countdown
  boot_single.img         Arch only, no menu (timeout 0)
  boot_install_dual.img   installer, forced Arch + NBD, no menu
  boot_install_single.img installer, forced Arch + NBD, no menu

Usage:
  DTC=/path/to/dtc python3 -I make-boot.py --boot boot_a.live.img --out out/boot
"""
import argparse
import hashlib
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile

PAGE = 4096
PART_SIZE = 100663296
HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.environ.get("TBTOOLS") or os.path.join(HERE, "..", "tools")
AVBTOOL = os.path.join(TOOLS, "avbtool.py")
TESTKEY = os.path.join(TOOLS, "testkey_rsa4096.pem")
DTC = os.environ.get("DTC") or shutil.which("dtc") or ""


def avb(*args):
    return subprocess.run([sys.executable, AVBTOOL] + list(args),
                          capture_output=True, text=True, errors="replace")


def avb_info(image):
    r = avb("info_image", "--image", image)
    if r.returncode:
        sys.exit("avbtool info_image failed:\n" + r.stdout + r.stderr)
    return r.stdout


def manifest_entries(man):
    count = struct.unpack_from("<I", man, 8)[0]
    entries, pos = [], 60
    for _ in range(count):
        (off, size, typ, flags, load, ent, dtb, align, cmax,
         nlen) = struct.unpack_from("<QQIIQIIIQI", man, pos)
        name = man[pos + 56:pos + 56 + nlen].decode("latin1")
        entries.append(dict(name=name, offset=off, size=size, type=typ,
                            flags=flags, alignment=align, entry_pos=pos))
        pos += 56 + ((nlen + 3) // 4) * 4
    return entries


def patch_dtb(dtb, extra, tmpdir):
    """Return a new DTB with /chosen/bootargs + extra (space separated)."""
    if not DTC:
        sys.exit("dtc not found; set DTC=/path/to/dtc")
    src = os.path.join(tmpdir, "in.dtb")
    dts = os.path.join(tmpdir, "in.dts")
    out = os.path.join(tmpdir, "out.dtb")
    open(src, "wb").write(dtb)
    r = subprocess.run([DTC, "-I", "dtb", "-O", "dts", "-o", dts, src],
                       capture_output=True, text=True, errors="replace")
    if r.returncode:
        sys.exit("dtc decompile failed:\n" + r.stdout + r.stderr)
    text = open(dts, encoding="utf-8", errors="replace").read()
    m = re.search(r'^(\s*)bootargs = "([^"]*)";', text, re.M)
    if not m:
        sys.exit("no /chosen/bootargs in the DTB")
    base = m.group(2)
    words = base.split()
    for w in extra.split():
        if w not in words:
            words.append(w)
    new_args = " ".join(words)
    text = text[:m.start()] + '%sbootargs = "%s";' % (m.group(1), new_args) + text[m.end():]
    with open(dts, "w", encoding="utf-8") as f:
        f.write(text)
    r = subprocess.run([DTC, "-I", "dts", "-O", "dtb", "-o", out, dts],
                       capture_output=True, text=True, errors="replace")
    if r.returncode:
        sys.exit("dtc compile failed:\n" + r.stdout + r.stderr)
    new = open(out, "rb").read()
    if new[:4] != b"\xd0\x0d\xfe\xed":
        sys.exit("dtc produced a non-DTB")
    # sanity: the new bootargs must be present verbatim
    if new_args.encode() not in new:
        sys.exit("new bootargs not found in the compiled DTB")
    return new, new_args


def align_up(n, a):
    return (n + a - 1) & ~(a - 1)


def patch_variant(src, out_path, default_entry, timeout_ms, extra_args):
    data = bytearray(open(src, "rb").read())
    if data[:8] != b"ANDROID!":
        sys.exit("%s: not an Android boot image" % src)
    if struct.unpack_from("<I", data, 40)[0] != 4:
        sys.exit("%s: not a boot v4 header" % src)
    kernel_size, ramdisk_size = struct.unpack_from("<II", data, 8)
    if ramdisk_size:
        sys.exit("%s: unexpected boot ramdisk" % src)
    blob = bytes(data[PAGE:PAGE + kernel_size])
    if blob[56:60] != b"ARMd":
        sys.exit("%s: packed kernel is not an arm64 Image" % src)
    man_off = struct.unpack_from("<Q", blob, 0x20)[0]
    man_size = struct.unpack_from("<Q", blob, 0x28)[0]
    man = bytearray(blob[man_off:man_off + man_size])
    if man[:4] != b"KPMF":
        sys.exit("no KPMF manifest")
    entries = manifest_entries(man)
    by_name = {e["name"]: e for e in entries}
    if "Arch" not in by_name or "Arch DTB" not in by_name:
        sys.exit("manifest has no Arch/Arch DTB entries")
    arch = by_name["Arch"]
    dtbe = by_name["Arch DTB"]
    if default_entry >= len(entries):
        sys.exit("default entry out of range")

    with tempfile.TemporaryDirectory(prefix="tbdtb.") as td:
        new_dtb, new_bootargs = patch_dtb(blob[dtbe["offset"]:dtbe["offset"] + dtbe["size"]],
                                          extra_args, td)

    # Keep the GKI/shim/Arch image byte-identical; rebuild only the DTB+manifest tail.
    head = blob[:arch["offset"] + arch["size"]]
    new_dtb_off = align_up(len(head), 8)
    new_man_off = align_up(new_dtb_off + len(new_dtb), 4)
    struct.pack_into("<Q", man, dtbe["entry_pos"], new_dtb_off)
    struct.pack_into("<Q", man, dtbe["entry_pos"] + 8, len(new_dtb))
    new_blob = bytearray(head)
    new_blob += b"\0" * (new_dtb_off - len(head))
    new_blob += new_dtb
    new_blob += b"\0" * (new_man_off - new_dtb_off - len(new_dtb))
    new_blob += man
    struct.pack_into("<Q", new_blob, 0x10, len(new_blob))       # runtimeSize
    struct.pack_into("<Q", new_blob, 0x20, new_man_off)         # manifestOffset
    if len(new_blob) >= PART_SIZE - 1024 * 1024:
        sys.exit("packed kernel too large")

    hdr = bytearray(data[:PAGE])
    struct.pack_into("<I", hdr, 8, len(new_blob))
    text = new_bootargs.encode()
    if len(text) >= 1536:
        sys.exit("cmdline too long")
    hdr[44:44 + 1536] = text + b"\0" * (1536 - len(text))
    body = bytes(hdr) + bytes(new_blob)
    body += b"\0" * (-len(body) % PAGE)

    # kShim manifest header: defaultEntry at +12, timeoutMs at +16.
    man_abs = PAGE + new_man_off
    body = bytearray(body)
    struct.pack_into("<I", body, man_abs + 12, default_entry)
    struct.pack_into("<I", body, man_abs + 16, timeout_ms)

    tmp = out_path + ".body"
    open(tmp, "wb").write(body)

    info = avb_info(src)
    salt = re.search(r"Salt:\s+([0-9a-f]+)", info)
    rb = re.search(r"Rollback Index:\s+(\d+)", info)
    if not salt or not rb:
        sys.exit("cannot read salt/rollback index")
    props, seen = [], set()
    for k, v in re.findall(r"Prop: (\S+) -> '([^']*)'", info):
        if (k, v) not in seen:
            seen.add((k, v))
            props += ["--prop", "%s:%s" % (k, v)]
    r = avb("add_hash_footer", "--image", tmp,
            "--partition_name", "boot", "--partition_size", str(PART_SIZE),
            "--key", TESTKEY, "--algorithm", "SHA256_RSA4096",
            "--rollback_index", rb.group(1), "--salt", salt.group(1), *props)
    if r.returncode:
        sys.exit("add_hash_footer failed:\n" + r.stdout + r.stderr)
    os.replace(tmp, out_path)
    os.chmod(out_path, 0o644)
    h = hashlib.sha256(open(out_path, "rb").read()).hexdigest()
    print("%-26s %10d  %s  bootargs=%s" %
          (os.path.basename(out_path), os.path.getsize(out_path), h, new_bootargs))
    return h


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--boot", required=True, help="live boot_a image (packed kShim)")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    variants = [
        ("boot_arch.img", 1, 8000, "tb710fu.nbd androidboot.slot_suffix=_a"),
        ("boot_zui.img", 0, 8000, "tb710fu.nbd androidboot.slot_suffix=_a"),
        ("boot_single.img", 1, 1000, "tb710fu.nbd androidboot.slot_suffix=_a"),
        ("boot_install_dual.img", 1, 1000, "tb710fu.nbd androidboot.slot_suffix=_a tb710fu.install=dual"),
        ("boot_install_single.img", 1, 1000, "tb710fu.nbd androidboot.slot_suffix=_a tb710fu.install=single"),
    ]
    hashes = {}
    for name, default, timeout, extra in variants:
        hashes[name] = patch_variant(a.boot, os.path.join(a.out, name),
                                     default, timeout, extra)
    with open(os.path.join(a.out, "SHA256SUMS"), "w") as f:
        for name, h in hashes.items():
            f.write("%s  %s\n" % (h, name))


if __name__ == "__main__":
    main()
