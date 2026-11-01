#!/usr/bin/env python3
"""patch_prepare_offline.py - let ports/crdk/prepare.py work without a git checkout.

prepare.py is designed for a CrDK git clone at the pinned revision: it runs
`git rev-parse HEAD` to check the revision and `git archive <rev>` to materialize a clean copy
into the build dir. Offline (GitHub unreachable, CrDK staged as a codeload tarball) there is no
repository, so two spots are taught the alternative:

  1. the revision check: accept a `.kshim-crdk-revision` file written by
     arch/materialize_crdk.py, which verified the pinned tarball's sha256
  2. the materialize step: copy the verified tree instead of `git archive`

Everything else - the UPSTREAM.json patch list, the per-patch sha256 check, the stamp
signature, `git apply --check` before `git apply`, GIT_CEILING_DIRECTORIES - is untouched.

Usage: python3 patch_prepare_offline.py <path to prepare.py>
"""
import io
import sys

REV_CHECK_OLD = '''    actual = subprocess.check_output(
        ["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
    if actual != revision:
        raise ValueError(f"CrDK must be at {revision}, found {actual}")'''

REV_CHECK_NEW = '''    if (source / ".git").exists():
        actual = subprocess.check_output(
            ["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
    else:
        marker = source / ".kshim-crdk-revision"
        actual = marker.read_text().strip() if marker.exists() else "unknown"
    if actual != revision:
        raise ValueError(f"CrDK must be at {revision}, found {actual}")'''

ARCHIVE_OLD = '''        archive = subprocess.check_output(
            ["git", "-C", str(source), "archive", "--format=tar", revision])
        with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
            tar.extractall(tree, filter="data")'''

ARCHIVE_NEW = '''        if (source / ".git").exists():
            archive = subprocess.check_output(
                ["git", "-C", str(source), "archive", "--format=tar", revision])
            with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
                tar.extractall(tree, filter="data")
        else:
            # offline: lib/CrDK came from the pinned codeload tarball via
            # arch/materialize_crdk.py, which checked its recorded sha256 and every patch hash
            shutil.copytree(source, tree, dirs_exist_ok=True, symlinks=True,
                            ignore=shutil.ignore_patterns(".kshim-crdk-*"))'''


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__.split("\n")[0])
    path = sys.argv[1]
    s = io.open(path, encoding="utf-8").read()
    if "kshim-crdk-revision" in s and "offline: lib/CrDK" in s:
        print("   prepare.py: offline paths already in place")
        return 0
    for old, new, label in ((REV_CHECK_OLD, REV_CHECK_NEW, "revision check"),
                            (ARCHIVE_OLD, ARCHIVE_NEW, "materialize step")):
        if old not in s:
            sys.exit("!! prepare.py changed upstream; cannot patch the %s" % label)
        s = s.replace(old, new)
    io.open(path, "w", encoding="utf-8").write(s)
    print("   prepare.py: offline revision check + copy-instead-of-archive installed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
