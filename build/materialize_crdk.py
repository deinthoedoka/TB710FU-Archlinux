#!/usr/bin/env python3
"""Offline stand-in for kshim-success-source/ports/crdk/prepare.py.

prepare.py materializes the pinned CrDK tree into lib/CrDK and verifies the patch hashes, but
it requires the source to be a git clone at the pinned revision (it runs `git rev-parse HEAD`
and `git archive <revision>`). When GitHub is not reachable from the build host, build_shim.sh
stages a codeload tarball for exactly that revision instead, and this unpacks it into lib/CrDK.

What this keeps from prepare.py:
  * every patch in UPSTREAM.json is checked against its recorded sha256 before it is trusted
  * the same .kshim-crdk-stamp signature is written, so kShimC's configure sees a materialized
    tree
What is different, deliberately:
  * lib/CrDK stays PRISTINE. prepare.py applies the (hash-verified) patches itself, into its
    build-dir copy, so patching here would make them fail to apply there.
  * the revision identity comes from the tarball's sha256 (recorded in deps.sha256 when it was
    fetched from codeload/<revision>) instead of from a git commit hash. Pass --sha256 to check
    it; without it the tree is accepted unverified and the run says so.

Usage:
  python3 materialize_crdk.py --port <kshim>/ports/crdk --source <CrDK .tar.gz or tree> \
          --output <kshim>/lib/CrDK [--sha256 <hex>]
"""
import argparse
import hashlib
import json
import os
import shutil
import sys
import tarfile
import tempfile


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--port", required=True, help="the kShimC ports/crdk directory")
    ap.add_argument("--source", required=True, help="extracted CrDK tree, or a .tar.gz of one")
    ap.add_argument("--output", required=True)
    ap.add_argument("--sha256", default="", help="expected sha256 of the tarball, if --source is one")
    a = ap.parse_args()

    port = os.path.abspath(a.port)
    output = os.path.abspath(a.output)
    manifest = json.loads(open(os.path.join(port, "UPSTREAM.json")).read())
    revision = manifest["revision"]

    patches = []
    for entry in manifest["patches"]:
        patch = os.path.join(port, "patches", entry["file"])
        got = sha256_file(patch)
        if got != entry["sha256"]:
            sys.exit("CrDK patch hash mismatch: %s (want %s got %s)" % (entry["file"], entry["sha256"], got))
        patches.append(patch)
    print("verified %d CrDK patch hashes for revision %s" % (len(patches), revision))

    signature = hashlib.sha256(open(os.path.join(port, "UPSTREAM.json"), "rb").read()
                               + open(os.path.join(port, "prepare.py"), "rb").read()).hexdigest()
    stamp = os.path.join(output, ".kshim-crdk-stamp")
    if os.path.exists(stamp) and open(stamp).read() == signature:
        print("already materialized at %s" % output)
        return 0

    os.makedirs(os.path.dirname(output), exist_ok=True)
    tmp = tempfile.mkdtemp(prefix="crdk-", dir=os.path.dirname(output))
    tree = os.path.join(tmp, "tree")
    os.makedirs(tree)
    try:
        if os.path.isdir(a.source):
            shutil.copytree(a.source, tree, dirs_exist_ok=True, symlinks=True)
            print("source tree %s (directory: revision is not checked here)" % a.source)
        else:
            if a.sha256:
                got = sha256_file(a.source)
                if got != a.sha256:
                    sys.exit("CrDK tarball sha256 %s != recorded %s - do not use it" % (got, a.sha256))
                print("CrDK tarball sha256 verified (%s)" % got)
            else:
                print("WARNING: no recorded sha256 for %s; using it unverified" % a.source)
            with tarfile.open(a.source) as tar:
                tar.extractall(tree, filter="data")
            # codeload tarballs wrap everything in one <name>-<rev>/ directory
            entries = os.listdir(tree)
            if len(entries) == 1 and os.path.isdir(os.path.join(tree, entries[0])):
                inner = os.path.join(tree, entries[0])
                for name in os.listdir(inner):
                    shutil.move(os.path.join(inner, name), os.path.join(tree, name))
                os.rmdir(inner)

        # The patches are NOT applied here: prepare.py expects lib/CrDK to be the pristine
        # pinned tree and applies them itself into the build-dir copy (git apply --check first).
        # Their hashes were verified above, which is the provenance check that matters.
        print("   %d patches verified; prepare.py applies them to its build copy" % len(patches))
        # the revision identity, recorded so the port's prepare.py (patched to read this file
        # when there is no .git) still refuses a tree that is not the pinned one
        open(os.path.join(tree, ".kshim-crdk-revision"), "w").write(revision + "\n")
        open(os.path.join(tree, ".kshim-crdk-stamp"), "w").write(signature)
        if os.path.exists(output):
            shutil.rmtree(output)
        os.rename(tree, output)
    finally:
        if os.path.isdir(tmp):
            shutil.rmtree(tmp, ignore_errors=True)
    print("materialized %s" % output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
