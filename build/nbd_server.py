#!/usr/bin/env python3
"""nbd_server.py - serve a raw disk image over NBD so the TB710FU can boot Arch from it.

Pure Python, no dependencies, runs on Windows (the dry-run host here) and Linux.
The pad's initramfs probes 172.16.42.2-10 on port 10809, greps the greeting for
"NBDMAGIC", then runs `nbd-client -b 512 -N <export> <host> 10809 /dev/nbd0` and mounts
/dev/nbd0p2. So: new-style fixed handshake, simple replies, export names "arch"/"steamos".

Protocol constants and byte layouts are taken from qemu's nbd-internal.h / include/block/nbd.h
(verified against qemu master on 2026-10-31), which is what nbd-client talks to:

  greeting   8  "NBDMAGIC" | 8 NBD_OPTS_MAGIC(IHAVEOPT) | 4 global flags (FIXED_NEWSTYLE|NO_ZEROES)
  client     4  client flags (C_FIXED_NEWSTYLE expected)
  option    16  8 NBD_OPTS_MAGIC | 4 option | 4 length   then length bytes of payload
  reply     20  8 NBD_REP_MAGIC | 4 option echoed | 4 type | 4 length  then length bytes
  EXPORT_NAME reply: 8 size | 2 transmission flags | 124 reserved (omitted when NO_ZEROES)
  INFO/GO   reply: NBD_REP_INFO(NBD_INFO_EXPORT: 2 type | 8 size | 2 flags) then NBD_REP_ACK
  request   28  4 magic(0x25609513) | 2 flags | 2 type | 8 handle | 8 offset | 4 length
  reply     16  4 magic(0x67446698) | 4 error | 8 handle

Usage (the image comes from build_rootfs.sh):
  python nbd_server.py --image arch-nbd.img --listen 0.0.0.0 --port 10809
  python nbd_server.py --image arch-nbd.img --ro          # never modify the image
Windows notes: run from an elevated shell only if you bind a specific address; bind 0.0.0.0
otherwise. Allow the port in the firewall. The pad gives the host 172.16.42.2-.10 over DHCP.
"""
import argparse, os, socket, struct, sys, threading, time

NBDMAGIC = b"NBDMAGIC"
OPTS_MAGIC = 0x49484156454F5054          # "IHAVEOPT"
REP_MAGIC = 0x0003E889045565A9
REQ_MAGIC = 0x25609513
SIMPLE_REPLY_MAGIC = 0x67446698

G_FIXED_NEWSTYLE, G_NO_ZEROES = 1, 2
C_FIXED_NEWSTYLE, C_NO_ZEROES = 1, 2

OPT_EXPORT_NAME, OPT_ABORT, OPT_LIST = 1, 2, 3
OPT_STARTTLS, OPT_INFO, OPT_GO, OPT_STRUCTURED_REPLY = 5, 6, 7, 8
OPT_LIST_META_CTX, OPT_SET_META_CTX, OPT_EXTENDED_HEADERS = 9, 10, 11

VERBOSE = False

REP_ACK, REP_SERVER, REP_INFO = 1, 2, 3
def rep_err(v): return (1 << 31) | v
ERR_UNSUP, ERR_POLICY, ERR_INVALID, ERR_UNKNOWN = rep_err(1), rep_err(2), rep_err(3), rep_err(6)

INFO_EXPORT = 0
F_HAS_FLAGS, F_READ_ONLY, F_FLUSH, F_TRIM = 1, 2, 4, 32
CMD_READ, CMD_WRITE, CMD_DISC, CMD_FLUSH, CMD_TRIM = 0, 1, 2, 3, 4
EPERM, EINVAL = 1, 22
MAX_LEN = 4 << 20

class Image:
    def __init__(self, path, read_only):
        self.lock = threading.Lock()
        self.size = os.path.getsize(path)
        self.f = open(path, "rb" if read_only else "r+b")
        self.read_only = read_only
        self.stats = {"read": 0, "write": 0, "trim": 0, "flush": 0}

    def read(self, off, n):
        with self.lock:
            self.f.seek(off)
            data = self.f.read(n)
            if len(data) < n:                       # sparse tail / short read
                data += b"\0" * (n - len(data))
            self.stats["read"] += len(data)
            return data

    def write(self, off, data):
        if self.read_only:
            raise PermissionError("export is read-only")
        with self.lock:
            self.f.seek(off)
            self.f.write(data)
            self.stats["write"] += len(data)

    def trim(self, off, n):
        with self.lock:
            self.stats["trim"] += n
            if self.read_only:
                return
            self.f.seek(off)
            self.f.write(b"\0" * min(n, 1 << 20))   # discard semantics: contents undefined

    def flush(self):
        with self.lock:
            self.stats["flush"] += 1
            self.f.flush()
            os.fsync(self.f.fileno())


def recv_exact(c, n, what):
    buf = b""
    while len(buf) < n:
        chunk = c.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("peer closed while reading %s" % what)
        buf += chunk
    return buf


def send_all(c, data):
    c.sendall(data)


def send_reply(c, option, rtype, payload=b""):
    send_all(c, struct.pack(">QIII", REP_MAGIC, option, rtype, len(payload)) + payload)


def serve_client(conn, peer, img, exports, log):
    conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    try:
        # greeting
        send_all(conn, NBDMAGIC + struct.pack(">QI", OPTS_MAGIC, G_FIXED_NEWSTYLE | G_NO_ZEROES))
        (cflags,) = struct.unpack(">I", recv_exact(conn, 4, "client flags"))
        # Fixed newstyle is optional for clients: busybox's nbd-client (the one this
        # initramfs uses) sends flags 0 and goes straight to NBD_OPT_EXPORT_NAME. Accept it
        # and keep the 124-byte padding in the EXPORT_NAME reply, since it never asks for
        # NO_ZEROES either.
        if not cflags & C_FIXED_NEWSTYLE:
            log("  client is plain newstyle (busybox nbd-client), continuing")
        no_zeroes = bool(cflags & C_NO_ZEROES)

        export = None
        transmitting = False
        # NBD_OPT_INFO only asks for facts about an export; negotiation continues afterwards, so
        # only GO / EXPORT_NAME may leave this loop (nbd-client does INFO first, then GO).
        while not transmitting:
            magic, opt, optlen = struct.unpack(">QII", recv_exact(conn, 16, "option header"))
            if magic != OPTS_MAGIC:
                raise ValueError("bad option magic 0x%x" % magic)
            payload = recv_exact(conn, optlen, "option payload") if optlen else b""

            if opt == OPT_ABORT:
                send_reply(conn, opt, REP_ACK)
                raise ConnectionError("client aborted")
            if opt == OPT_LIST:
                for name in exports:
                    send_reply(conn, opt, REP_SERVER, struct.pack(">I", len(name)) + name.encode())
                send_reply(conn, opt, REP_ACK)
                continue
            if opt in (OPT_INFO, OPT_GO):
                # payload: 4-byte name length + name + 4-byte count of requested info types
                nlen = struct.unpack(">I", payload[:4])[0] if len(payload) >= 4 else 0
                name = payload[4:4 + nlen].decode("utf-8", "replace")
                if name not in exports:
                    send_reply(conn, opt, ERR_UNKNOWN, struct.pack(">I", ERR_UNKNOWN))
                    log("  %s: unknown export %r" % ("GO" if opt == OPT_GO else "INFO", name))
                    continue
                export = name
                send_reply(conn, opt, REP_INFO, struct.pack(">HHQ", INFO_EXPORT, img.size, export_flags(img)))
                send_reply(conn, opt, REP_ACK)
                transmitting = opt == OPT_GO
                continue
            if opt == OPT_EXPORT_NAME:
                name = payload.decode("utf-8", "replace")
                if name not in exports:
                    # EXPORT_NAME has no reply header; the only way to report failure is to drop
                    log("  EXPORT_NAME: unknown export %r -> dropping connection" % name)
                    raise ConnectionError("export not found")
                export = name
                reply = struct.pack(">QH", img.size, export_flags(img))
                if not no_zeroes:
                    reply += b"\0" * 124
                send_all(conn, reply)
                transmitting = True
                continue
            # everything else we deliberately do not implement
            for unsupported, why in ((OPT_STRUCTURED_REPLY, "structured replies"),
                                     (OPT_STARTTLS, "TLS"),
                                     (OPT_LIST_META_CTX, "meta contexts"),
                                     (OPT_SET_META_CTX, "meta contexts"),
                                     (OPT_EXTENDED_HEADERS, "extended headers")):
                if opt == unsupported:
                    send_reply(conn, opt, ERR_UNSUP, struct.pack(">I", ERR_UNSUP))
                    log("  rejected %s (%s)" % (opt, why))
                    break
            else:
                send_reply(conn, opt, ERR_UNSUP, struct.pack(">I", ERR_UNSUP))
                log("  rejected unknown option %d" % opt)

        log("  export %s, size %d bytes" % (export, img.size))

        # transmission phase (simple replies only)
        while True:
            hdr = recv_exact(conn, 28, "request")
            magic, flags, cmd, handle, off, ln = struct.unpack(">IHHQQI", hdr)
            if VERBOSE:
                log("  req cmd=%d off=%d len=%d flags=0x%x" % (cmd, off, ln, flags))
            if magic != REQ_MAGIC:
                log("  bad request magic 0x%x" % magic)
                return
            if cmd == CMD_DISC:
                log("  disconnect")
                return
            if cmd == CMD_FLUSH:
                img.flush()
                send_all(conn, struct.pack(">IIQ", SIMPLE_REPLY_MAGIC, 0, handle))
                continue
            if ln == 0 or ln > MAX_LEN:
                if VERBOSE:
                    log("  EINVAL: length %d (max %d)" % (ln, MAX_LEN))
                send_all(conn, struct.pack(">IIQ", SIMPLE_REPLY_MAGIC, EINVAL, handle))
                continue
            if off + ln > img.size:
                if VERBOSE:
                    log("  EINVAL: offset %d + length %d past end %d" % (off, ln, img.size))
                send_all(conn, struct.pack(">IIQ", SIMPLE_REPLY_MAGIC, EINVAL, handle))
                continue
            if cmd == CMD_READ:
                data = img.read(off, ln)
                send_all(conn, struct.pack(">IIQ", SIMPLE_REPLY_MAGIC, 0, handle) + data)
            elif cmd == CMD_WRITE:
                data = recv_exact(conn, ln, "write payload")
                try:
                    img.write(off, data)
                    send_all(conn, struct.pack(">IIQ", SIMPLE_REPLY_MAGIC, 0, handle))
                except PermissionError:
                    send_all(conn, struct.pack(">IIQ", SIMPLE_REPLY_MAGIC, EPERM, handle))
            elif cmd == CMD_TRIM:
                try:
                    img.trim(off, ln)
                    send_all(conn, struct.pack(">IIQ", SIMPLE_REPLY_MAGIC, 0, handle))
                except PermissionError:
                    send_all(conn, struct.pack(">IIQ", SIMPLE_REPLY_MAGIC, EPERM, handle))
            else:
                # CACHE / WRITE_ZEROES / BLOCK_STATUS are not offered in the export flags
                send_all(conn, struct.pack(">IIQ", SIMPLE_REPLY_MAGIC, EPERM, handle))
    except (ConnectionError, ConnectionResetError) as e:
        log("  %s ended: %s" % (peer, e))
    except Exception as e:
        log("  %s error: %r" % (peer, e))
    finally:
        log("  counters: %s" % img.stats)
        conn.close()


def export_flags(img):
    f = F_HAS_FLAGS | F_FLUSH | F_TRIM
    if img.read_only:
        f |= F_READ_ONLY
    return f


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--image", required=True, help="raw disk image from build_rootfs.sh")
    ap.add_argument("--port", type=int, default=10809)
    ap.add_argument("--listen", default="0.0.0.0")
    ap.add_argument("--export", default="arch,steamos",
                    help="comma separated export names; the pad tries 'arch' then 'steamos'")
    ap.add_argument("--ro", action="store_true", help="read-only export (dry run without writes)")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--verbose", action="store_true", help="log every NBD request")
    a = ap.parse_args()

    global VERBOSE
    VERBOSE = a.verbose

    exports = [e.strip() for e in a.export.split(",") if e.strip()]
    img = Image(a.image, a.ro)
    log = (lambda *_: None) if a.quiet else (
        lambda m: print("%s %s" % (time.strftime("%H:%M:%S"), m), flush=True))

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((a.listen, a.port))
    srv.listen(4)
    print("serving %s (%d bytes) on %s:%d exports=%s%s" %
          (a.image, img.size, a.listen, a.port, exports, " [read-only]" if a.ro else ""), flush=True)
    print("the pad waits for a host answering 10809 in 172.16.42.2-10; keep this running.", flush=True)
    try:
        while True:
            conn, peer = srv.accept()
            log("connection from %s:%d" % peer)
            threading.Thread(target=serve_client, args=(conn, "%s:%d" % peer, img, exports, log),
                             daemon=True).start()
    except KeyboardInterrupt:
        print("stopped", flush=True)
    finally:
        img.f.close()


if __name__ == "__main__":
    main()
