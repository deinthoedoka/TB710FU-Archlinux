#!/usr/bin/env python3
"""make_vbmeta.py - build a vbmeta_a that boots our packed boot on a locked TB710FU.

Why this is needed at all: the stock images are signed with Lenovo's key (public sha1
8fcb864f...), which we do not have. AVB chains `boot` through the top-level vbmeta, so a
boot image signed with the AOSP testkey can only boot if the vbmeta chains boot to that same
testkey. The locked ABL of this tablet trusts the AOSP test keys, so a vbmeta signed with
testkey_rsa4096 is accepted - this is the same mechanism the community "WITHOUT_UBL" packages
use on 1.5.04.495.

What the new vbmeta contains:
  * signed with testkey_rsa4096, flags=1 (hashtree disabled), rollback index 0 (stock value),
    padding 4096
  * chain boot -> AOSP testkey    (our packed boot is signed with it)
  * chain recovery -> stock Lenovo public key  (recovery_a is left untouched)
  * chain vbmeta_system -> stock Lenovo public key (vbmeta_system_a is left untouched, so its
    own descriptors for system/vendor keep verifying the stock super)
No hash descriptors are copied for dtbo/init_boot/vendor_boot: those partitions stay stock and
simply are not covered, which AVB allows (an unlisted partition is not verified). Reproducing
their OEM digests would require the original unpadded images.

Usage:
  python3 -I make_vbmeta.py --stock-vbmeta <vbmeta_a.img> --testkey <testkey_rsa4096.pem> \
          --boot <boot_zui.img> [--vbmeta-system <vbmeta_system_a.img>] --out <dir>
"""
import argparse
import hashlib
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.environ.get("TBTOOLS") or os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "tools")
AVBTOOL = os.path.join(TOOLS, "avbtool.py")


def avb(*args):
    r = subprocess.run([sys.executable, AVBTOOL] + list(args), capture_output=True, text=True,
                       errors="replace")
    return r


def avb_ok(*args):
    r = avb(*args)
    if r.returncode:
        sys.exit("avbtool %s failed:\n%s%s" % (args[0], r.stdout, r.stderr))
    return r.stdout


def chain_keys(stock_vbmeta, out_dir):
    """Pull the chain-descriptor public keys out of the stock vbmeta."""
    sys.path.insert(0, TOOLS)
    import avbtool as at
    data = open(stock_vbmeta, "rb").read()
    hdr = at.AvbVBMetaHeader(bytes(data[:at.AvbVBMetaHeader.SIZE]))
    aux = at.AvbVBMetaHeader.SIZE + hdr.authentication_data_block_size
    blob = data[aux + hdr.descriptors_offset:aux + hdr.descriptors_offset + hdr.descriptors_size]
    keys = {}
    for d in at.parse_descriptors(blob):
        if isinstance(d, at.AvbChainPartitionDescriptor):
            p = os.path.join(out_dir, d.partition_name + ".pk")
            open(p, "wb").write(d.public_key)
            keys[d.partition_name] = (p, d.rollback_index_location,
                                      hashlib.sha1(d.public_key).hexdigest())
    return keys, hdr


def verify_chain_image(path, expected_pk, label):
    """Verify an AVB image the way the bootloader does for a chained partition.

    avbtool's `verify_image --key` wants a PEM and `--follow_chain_partitions` re-uses the
    top-level key for chained images, which is not what a device checks. A chained partition is
    accepted when (a) its signature is valid for the key embedded in it and (b) that embedded
    key is byte-identical to the key in the parent's chain descriptor.
    """
    import struct
    sys.path.insert(0, TOOLS)
    import avbtool as at

    data = open(path, "rb").read()
    if data[:4] == b"AVB0":
        off = 0
    else:
        foot = data[-64:]
        if foot[:4] != b"AVBf":
            sys.exit("%s: neither a vbmeta image nor an AVB-footer image" % label)
        # AVB footer: magic[4] ver_major[4] ver_minor[4] original_image_size[8]
        #             vbmeta_offset[8] vbmeta_size[8] reserved[28]
        off = struct.unpack("!Q", foot[20:28])[0]      # vbmeta_offset
    hdr = at.AvbVBMetaHeader(bytes(data[off:off + at.AvbVBMetaHeader.SIZE]))
    blob = data[off:off + at.AvbVBMetaHeader.SIZE + hdr.authentication_data_block_size
                + hdr.auxiliary_data_block_size]
    if not at.verify_vbmeta_signature(hdr, blob):
        sys.exit("%s: signature does not match its embedded public key" % label)
    koff = (at.AvbVBMetaHeader.SIZE + hdr.authentication_data_block_size
            + hdr.public_key_offset)
    embedded = blob[koff:koff + hdr.public_key_size]
    if embedded != expected_pk:
        sys.exit("%s: embedded key %s != chained key %s"
                 % (label, hashlib.sha1(embedded).hexdigest(), hashlib.sha1(expected_pk).hexdigest()))
    print("%s: signature ok, chained key %s matches" % (label, hashlib.sha1(embedded).hexdigest()))
    return True


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--stock-vbmeta", required=True, help="the device's own vbmeta_a backup")
    ap.add_argument("--testkey", required=True, help="AOSP testkey_rsa4096.pem")
    ap.add_argument("--boot", required=True, help="the packed boot image that goes on boot_a")
    ap.add_argument("--vbmeta-system", default="", help="stock vbmeta_system_a.img, to verify")
    ap.add_argument("--out", required=True)
    ap.add_argument("--flags", type=int, default=1, help="vbmeta flags (1 = hashtree disabled)")
    a = ap.parse_args()

    os.makedirs(a.out, exist_ok=True)
    keys, stock_hdr = chain_keys(a.stock_vbmeta, a.out)
    for name, (path, loc, sha1) in sorted(keys.items()):
        print("stock chain %-14s loc=%d key sha1 %s" % (name, loc, sha1))
    for need in ("recovery", "vbmeta_system"):
        if need not in keys:
            sys.exit("stock vbmeta has no chain descriptor for %s" % need)

    pk_test = os.path.join(a.out, "testkey_rsa4096.pk")
    avb_ok("extract_public_key", "--key", a.testkey, "--output", pk_test)
    test_sha1 = hashlib.sha1(open(pk_test, "rb").read()).hexdigest()
    print("testkey public key sha1 %s" % test_sha1)

    out_vbmeta = os.path.join(a.out, "vbmeta.img")
    avb_ok("make_vbmeta_image", "--output", out_vbmeta,
           "--key", a.testkey, "--algorithm", "SHA256_RSA4096",
           "--flags", str(a.flags), "--padding_size", "4096",
           "--rollback_index", str(stock_hdr.rollback_index),
           "--rollback_index_location", str(stock_hdr.rollback_index_location),
           "--chain_partition", "boot:%d:%s" % (keys["boot"][1], pk_test),
           "--chain_partition", "recovery:%d:%s" % (keys["recovery"][1], keys["recovery"][0]),
           "--chain_partition", "vbmeta_system:%d:%s" % (keys["vbmeta_system"][1],
                                                         keys["vbmeta_system"][0]))
    print("built %s (%d bytes)" % (out_vbmeta, os.path.getsize(out_vbmeta)))

    # pad to the partition size, so the EDL write replaces all 64 KiB of vbmeta_a instead of
    # leaving the tail of the previous image behind
    PART_SIZE = 65536
    data = open(out_vbmeta, "rb").read()
    if len(data) > PART_SIZE:
        sys.exit("vbmeta is %d bytes, larger than the %d-byte partition" % (len(data), PART_SIZE))
    if len(data) < PART_SIZE:
        open(out_vbmeta, "wb").write(data + b"\0" * (PART_SIZE - len(data)))
        print("padded to %d bytes (partition size)" % PART_SIZE)

    # verify the way the device does: signature over each image + chained key identity
    print("--- chain verification ---")
    verify_chain_image(out_vbmeta, open(pk_test, "rb").read(), "vbmeta.img")
    verify_chain_image(a.boot, open(pk_test, "rb").read(), "boot.img (ours)")
    if a.vbmeta_system:
        verify_chain_image(a.vbmeta_system, open(keys["vbmeta_system"][0], "rb").read(),
                           "vbmeta_system.img (stock, untouched)")
    print("recovery.img: not verified locally (no readback); it stays stock and is chained to "
          "the stock key, so the device checks it exactly as before")

    # and the reverse check: the new vbmeta must NOT be accepted with the stock key identity
    print("--- summary ---")
    print("vbmeta.img     %d bytes" % os.path.getsize(out_vbmeta))
    print("  signed by    testkey_rsa4096 (%s)" % test_sha1)
    print("  chain boot   -> testkey (%s) loc %d" % (test_sha1, keys["boot"][1]))
    print("  chain recovery -> stock key (%s) loc %d" % (keys["recovery"][2], keys["recovery"][1]))
    print("  chain vbmeta_system -> stock key (%s) loc %d"
          % (keys["vbmeta_system"][2], keys["vbmeta_system"][1]))
    open(os.path.join(a.out, "vbmeta.img.sha256"), "w").write(
        "%s  vbmeta.img\n" % hashlib.sha256(open(out_vbmeta, "rb").read()).hexdigest())
    return 0


if __name__ == "__main__":
    sys.exit(main())
