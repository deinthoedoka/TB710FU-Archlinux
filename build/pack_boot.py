#!/usr/bin/env python3
"""pack_boot.py - build the TB710FU dual-boot boot_a for ZUXOS + Arch Linux.

Port of the repo's tools/kshim_pack_boot.py, with two changes for this build:
  * the DualBootKernelPatcher packer runs LOCALLY (freedom's vendored packer or a local
    DBKP build), no docker; DBKP occasionally exits 234, so it is retried
  * menu labels are configurable and default to ZUXOS / Arch, and the boot header cmdline
    carries the initramfs tokens (tb710fu.nbd, optional tb710fu.diag)

Structure of the result (boot v4, page 4096, partition 100663296 bytes):
  header (ours cmdline) | kernel = PackedKernel(shim + Image-00 stock GKI [BaseImage]
  + Image-01 Arch raw Image + Image-02 its DTB + Manifest) | AVB hash footer signed with
  testkey_rsa4096 using the SAME salt / rollback index / props as the stock footer, so the
  stock vbmeta_a chain still verifies boot. vbmeta, init_boot and vendor_boot are not touched.

Run this INSIDE WSL2 (or any Linux host), not on Windows: the packer is a Linux ELF binary,
and avbtool shells out to `openssl` to read the test key - Windows has neither.

Environment:
  AVBTOOL   path to avbtool.py      (default: <tools>/avbtool.py)
  TESTKEY   testkey_rsa4096.pem     (default: <tools>/testkey_rsa4096.pem)
  PACKER    packer binary           (default: searched under KSHIM_BUILD, else freedom's vendor)
  KSHIM_BUILD  dir with a built DBKP (default work/kshim-build next to the tools dir)
  VBMETA    not used any more: the stock vbmeta_a is Lenovo-signed and gets replaced by
            arch/make_vbmeta.py, which chains boot to the AOSP testkey this script signs with
  TBTOOLS   override the tools dir (default: build/tools)

Usage (both variants):
  python -I pack_boot.py --boot <stock boot_a.img> --shim kShimC.bin \
         --linux out/Image --dtb out/sm8650-lenovo-tb710fu-kshim.dtb --out ../out/boot \
         --default arch
  python -I pack_boot.py ... --default zui
"""
import argparse, gzip, hashlib, os, re, shutil, struct, subprocess, sys

PAGE = 4096
PART_SIZE = 100663296
# ABL on this board loads a raw packed kernel up to ~86.5 MB (docs/dualboot-kshim.md)
ABL_RAW_LIMIT = 86 * 1024 * 1024
# the build/tools helper dir
TOOLS = os.environ.get("TBTOOLS") or os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "tools")
AVBTOOL = os.environ.get("AVBTOOL", os.path.join(TOOLS, "avbtool.py"))
TESTKEY = os.environ.get("TESTKEY", os.path.join(TOOLS, "testkey_rsa4096.pem"))
KSHIM_BUILD = os.environ.get("KSHIM_BUILD", os.path.join(os.path.dirname(TOOLS), "kshim-build"))
PY = sys.executable


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def avb(*args):
    return subprocess.run([PY, AVBTOOL] + list(args), capture_output=True, text=True,
                          errors="replace")


def find_packer():
    env = os.environ.get("PACKER")
    if env:
        return env
    hits = []
    for root, _, files in os.walk(KSHIM_BUILD):
        for name in files:
            if "Patcher" in name and not name.endswith((".c", ".h", ".obj", ".o", ".txt")):
                hits.append(os.path.join(root, name))
    if hits:
        return sorted(hits)[0]
    sys.exit("no DualBootKernelPatcher binary found (set PACKER=..., or build DBKP under %s)" % KSHIM_BUILD)


def run_packer(packer, work, retries=3):
    for i in range(retries):
        r = subprocess.run([packer, "build.cfg"], cwd=work, capture_output=True, text=True,
                           errors="replace")
        if r.returncode == 0:
            sys.stdout.write(r.stdout or "")
            return
        # DBKP is known to bail with 234 occasionally; anything else is a real failure
        sys.stdout.write((r.stdout or "") + (r.stderr or ""))
        if r.returncode != 234:
            sys.exit("packer failed with %d" % r.returncode)
        print("packer exited 234, retrying (%d/%d)" % (i + 1, retries))
    sys.exit("packer kept exiting 234")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--boot", required=True, help="stock boot_a.img that boots ZUXOS today")
    ap.add_argument("--shim", required=True, help="kShimC.bin")
    ap.add_argument("--linux", required=True, help="Arch kernel: raw arm64 Image")
    ap.add_argument("--dtb", required=True, help="sm8650-lenovo-tb710fu-kshim.dtb")
    ap.add_argument("--out", required=True)
    ap.add_argument("--default", choices=["zui", "arch"], default="arch",
                    help="entry booted when the 8 s countdown expires")
    ap.add_argument("--android-name", default="ZUXOS")
    ap.add_argument("--linux-name", default="Arch")
    ap.add_argument("--timeout-ms", type=int, default=8000)
    ap.add_argument("--gzip", action="store_true", help="gzip the packed kernel (ABL must support it)")
    ap.add_argument("--cmdline", default="tb710fu.nbd",
                    help="boot header cmdline; the initramfs reads tb710fu.nbd (root on the "
                         "NBD disk when no 'arch' partition exists yet). Android ignores it.")
    ap.add_argument("--diag", action="store_true", help="add tb710fu.diag (always drop to telnet shell)")
    ap.add_argument("--probe-slots", action="store_true",
                    help="reserve kshimreport/androidboot.kshim_s1..s8 placeholders so kShimC can "
                         "report diagnostics through Android props (no serial cable needed)")
    a = ap.parse_args()

    boot = open(a.boot, "rb").read()
    assert boot[:8] == b"ANDROID!", "not a boot image"
    kernel_size, ramdisk_size, _osver, header_size = struct.unpack_from("<IIII", boot, 8)
    header_version = struct.unpack_from("<I", boot, 40)[0]
    extra_cmdline = bytes(boot[1580:1584])            # first bytes of the extra_cmdline[] field
    assert header_version == 4 and ramdisk_size == 0 and extra_cmdline == b"\0\0\0\0", \
        (header_version, ramdisk_size, extra_cmdline)
    kernel = boot[PAGE:PAGE + kernel_size]
    assert kernel[56:60] == b"ARM\x64", "stock kernel must be a raw arm64 Image"
    linux = open(a.linux, "rb").read()
    assert linux[56:60] == b"ARM\x64", "--linux must be a raw arm64 Image"

    work = os.path.join(a.out, "pack-work")
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    open(os.path.join(work, "Image.android"), "wb").write(kernel)
    open(os.path.join(work, "Image.linux"), "wb").write(linux)
    shutil.copy(a.dtb, os.path.join(work, "linux.dtb"))
    shutil.copy(a.shim, os.path.join(work, "kShimC.bin"))

    default = "Image-01" if a.default == "arch" else "Image-00"
    cfg = ["[Pack]", "Shim=kShimC.bin", "Output=PackedKernel", "Default=" + default,
           "Timeout=%d" % a.timeout_ms, "",
           "[Image-00]", "Name=" + a.android_name, "Path=Image.android", "Type=Linux",
           "BaseImage=true", "Align=21", "",
           "[Image-01]", "Name=" + a.linux_name, "Path=Image.linux", "Type=Linux",
           "BaseImage=false", "Align=21", "DeviceTreeBlob=Image-02", "",
           # ARM64 requires the DTB to be 8-byte aligned. freedom patches the packer to make
           # DTB sections default to Align=3; state it here too so an unpatched packer is safe.
           "[Image-02]", "Name=" + a.linux_name + " DTB", "Path=linux.dtb", "Type=DTB",
           "BaseImage=false", "Align=3", "",
           "[Manifest]", "Type=Manifest", ""]
    open(os.path.join(work, "build.cfg"), "w").write("\n".join(cfg))

    run_packer(find_packer(), work)
    packed = open(os.path.join(work, "PackedKernel"), "rb").read()
    assert packed[56:60] == b"ARM\x64", "packed kernel is not a raw arm64 Image"
    if not a.gzip and len(packed) > ABL_RAW_LIMIT:
        sys.exit("packed kernel %d bytes exceeds the ABL raw limit (~%d); slim the kernel config"
                 % (len(packed), ABL_RAW_LIMIT))
    payload = gzip.compress(packed, compresslevel=9, mtime=0) if a.gzip else packed

    hdr = bytearray(boot[:PAGE])
    struct.pack_into("<I", hdr, 8, len(payload))
    text = a.cmdline.encode()
    if a.diag:
        text += b" tb710fu.diag"
    if a.probe_slots:
        pend = "pending" + "_" * 73
        params = ["kshimreport.kshim_probe=" + pend, "kshimreport.kshim_s0=" + pend]
        params += ["androidboot.kshim_s%d=%s" % (i, pend) for i in range(1, 9)]
        text += (b" " if text else b"") + " ".join(params).encode()
    assert len(text) < 1536, "cmdline too long for the boot v4 header"
    hdr[44:1580] = text + b"\0" * (1536 - len(text))
    body = bytes(hdr) + payload + b"\0" * (-len(payload) % PAGE)
    assert len(body) < PART_SIZE - 1024 * 1024, "boot image too large for the partition"

    name = "boot_%s.img" % a.default
    out_img = os.path.join(a.out, name)
    open(out_img, "wb").write(body)

    # AVB hash footer: same key, salt, rollback index and props as the stock boot footer, so
    # vbmeta_a's chained descriptor for boot still passes without touching vbmeta.
    info = avb("info_image", "--image", a.boot).stdout
    salt = re.search(r"Salt:\s+([0-9a-f]+)", info)
    rb = re.search(r"Rollback Index:\s+(\d+)", info)
    assert salt and rb, "could not read the stock footer's salt/rollback index"
    props, seen = [], set()
    for k, v in re.findall(r"Prop: (\S+) -> '([^']*)'", info):
        if (k, v) not in seen:
            seen.add((k, v))
            props += ["--prop", "%s:%s" % (k, v)]
    r = avb("add_hash_footer", "--image", out_img, "--partition_name", "boot",
            "--partition_size", str(PART_SIZE), "--key", TESTKEY, "--algorithm", "SHA256_RSA4096",
            "--rollback_index", rb.group(1), "--salt", salt.group(1), *props)
    if r.returncode:
        sys.exit("add_hash_footer failed:\n" + r.stdout + r.stderr)

    # The check that matters: this footer must verify for the AOSP testkey, because the new
    # vbmeta (arch/make_vbmeta.py) chains `boot` to exactly that key. The stock vbmeta is
    # Lenovo-signed and cannot accept a testkey-signed boot, which is why it is replaced too.
    pk = os.path.join(a.out, "testkey.pub")
    r = avb("extract_public_key", "--key", TESTKEY, "--output", pk)
    if r.returncode:
        sys.exit("extract_public_key failed:\n" + (r.stdout or "") + (r.stderr or ""))
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from make_vbmeta import verify_chain_image
    verify_chain_image(out_img, open(pk, "rb").read(), name)

    open(out_img + ".sha256", "w").write("%s  %s\n" % (sha(out_img), name))
    print("stock kernel  %d bytes sha256 %s" % (len(kernel), hashlib.sha256(kernel).hexdigest()))
    print("packed        %d bytes sha256 %s" % (len(packed), hashlib.sha256(packed).hexdigest()))
    print("payload       %d bytes (%s)" % (len(payload), "gzip" if a.gzip else "raw"))
    print("cmdline       %s" % text.decode(errors="replace")[:120])
    print("out           %s sha256 %s" % (out_img, sha(out_img)))
    print("menu          %s (default) / %s   countdown %d ms" % (a.linux_name if a.default == "arch"
          else a.android_name, a.android_name if a.default == "arch" else a.linux_name, a.timeout_ms))


if __name__ == "__main__":
    sys.exit(main())
