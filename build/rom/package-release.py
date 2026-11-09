#!/usr/bin/env python3
"""Package the TB710FU ROM as two self-contained kits: Windows and Linux.

Each kit contains the firmware (rootfs + install boot images) *and* the tools
for that OS, so users download exactly one archive.

  Windows kit -> <name>-windows.zip       boot/, rootfs/, windows/ (flash.cmd,
                                            flash.ps1, tools/), docs, SHA256SUMS
  Linux kit   -> <name>-linux.tar.zst     boot/, rootfs/, flash.sh, tools/
                                            (nbd_server.py), docs, SHA256SUMS

The big payload (rootfs image, boot images) is already compressed and stored
as-is (ZIP_STORED / zstd -3), so packaging is I/O bound instead of CPU bound.

Usage:
  package-release.py --src out-rom/tb710fu-arch-rom-v1.1 --out out-rom \
      --name tb710fu-arch-rom-v1.1
"""
import argparse
import hashlib
import os
import shutil
import stat
import subprocess
import sys
import time
import zipfile

BIG_FILE = 32 * 1024 * 1024  # store instead of deflate above this size
CHUNK = 8 * 1024 * 1024

# Files/dirs copied into both kits. Missing entries are an error.
COMMON = ["README.zh-CN.md", "CREDITS.md", "boot", "rootfs"]
VARIANTS = {
    "windows": {"extras": ["windows"], "archive": "zip"},
    "linux": {"extras": ["flash.sh", "tools"], "archive": "tar.zst"},
}
# Not hashed: the manifest itself, plus the README (users may annotate it).
SKIP_HASH = {"SHA256SUMS", "README.zh-CN.md"}


def log(msg):
    print(msg, flush=True)


def collect(src, entries):
    """Return [(relpath, abspath)] sorted, following the given top-level entries."""
    out = []
    for entry in entries:
        top = os.path.join(src, entry)
        if not os.path.exists(top):
            sys.exit(f"error: missing {top}")
        if os.path.isdir(top):
            for dirpath, dirnames, filenames in os.walk(top):
                dirnames.sort()
                for name in sorted(filenames):
                    full = os.path.join(dirpath, name)
                    out.append((os.path.relpath(full, src), full))
        else:
            out.append((entry, top))
    return sorted(out)


def stage(files, dest):
    """Materialise files under dest; hard-link the big ones to avoid 6 GB copies."""
    for rel, full in files:
        target = os.path.join(dest, rel)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        size = os.path.getsize(full)
        if size >= BIG_FILE:
            os.link(full, target)
        else:
            shutil.copy2(full, target)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(CHUNK), b""):
            h.update(block)
    return h.hexdigest()


def write_manifest(root):
    """Write SHA256SUMS with paths relative to root, sorted like sha256sum output."""
    lines = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in sorted(filenames):
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, root).replace(os.sep, "/")
            if rel in SKIP_HASH:
                continue
            lines.append((rel, sha256_file(full)))
    lines.sort()
    with open(os.path.join(root, "SHA256SUMS"), "w", encoding="utf-8") as fh:
        for rel, digest in lines:
            fh.write(f"{digest}  {rel}\n")
    return lines


def build_zip(root, out_path):
    root = os.path.abspath(root)
    base = os.path.dirname(root)
    with zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED, allowZip64=True) as zf:
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames.sort()
            for name in sorted(filenames):
                full = os.path.join(dirpath, name)
                rel = os.path.relpath(full, base).replace(os.sep, "/")
                st = os.stat(full)
                zi = zipfile.ZipInfo(rel, time.localtime(st.st_mtime)[:6])
                zi.create_system = 3
                zi.external_attr = (stat.S_IMODE(st.st_mode) | stat.S_IFREG) << 16
                zi.file_size = st.st_size
                big = st.st_size >= BIG_FILE
                zi.compress_type = zipfile.ZIP_STORED if big else zipfile.ZIP_DEFLATED
                with open(full, "rb") as src, zf.open(zi, "w") as dst:
                    shutil.copyfileobj(src, dst, CHUNK)
                log(f"  + {rel} ({st.st_size / 1024 / 1024:.1f} MiB)")


def build_tar_zst(root, out_path):
    name = os.path.basename(root)
    cmd = (
        f"tar -C {shlex_quote(os.path.dirname(root))} --numeric-owner -cf - {shlex_quote(name)}"
        f" | zstd -T0 -3 -q -f -o {shlex_quote(out_path)}"
    )
    subprocess.run(["bash", "-c", cmd], check=True)
    log(f"  + {out_path}")


def shlex_quote(s):
    import shlex

    return shlex.quote(s)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True, help="prepared package dir (boot/ rootfs/ ...)")
    ap.add_argument("--out", required=True, help="where the archives and .sha256 go")
    ap.add_argument("--name", required=True, help="archive basename, e.g. tb710fu-arch-rom-v1.1")
    ap.add_argument("--work", help="staging dir (default: <out>/.stage)")
    ap.add_argument("--only", choices=sorted(VARIANTS), help="build one variant only")
    args = ap.parse_args()

    out = os.path.abspath(args.out)
    src = os.path.abspath(args.src)
    work = os.path.abspath(args.work or os.path.join(out, ".stage"))
    os.makedirs(out, exist_ok=True)

    for variant, spec in VARIANTS.items():
        if args.only and variant != args.only:
            continue
        pkg = f"{args.name}-{variant}"
        root = os.path.join(work, pkg)
        log(f"== {pkg}")
        shutil.rmtree(root, ignore_errors=True)

        files = collect(src, COMMON + spec["extras"])
        stage(files, root)
        manifest = write_manifest(root)
        log(f"  SHA256SUMS: {len(manifest)} entries")

        if spec["archive"] == "zip":
            archive = os.path.join(out, pkg + ".zip")
        else:
            archive = os.path.join(out, pkg + ".tar.zst")
        if os.path.exists(archive):
            os.unlink(archive)

        if spec["archive"] == "zip":
            build_zip(root, archive)
        else:
            build_tar_zst(root, archive)

        digest = sha256_file(archive)
        with open(archive + ".sha256", "w", encoding="utf-8") as fh:
            fh.write(f"{digest}  {os.path.basename(archive)}\n")
        size = os.path.getsize(archive)
        log(f"  -> {archive} ({size / 1024 / 1024 / 1024:.2f} GiB)")
        log(f"  sha256 {digest}")

        shutil.rmtree(root, ignore_errors=True)

    # Drop the staging dir if we created it and it is empty.
    try:
        os.rmdir(work)
    except OSError:
        pass


if __name__ == "__main__":
    main()
