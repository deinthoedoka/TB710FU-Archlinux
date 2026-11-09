// nbdserver - a small NBD server for the TB710FU first-boot installer.
//
// The tablet's initramfs probes 172.16.42.2-10 on port 10809, greps the
// greeting for NBDMAGIC, then connects with a fixed-newstyle handshake and
// NBD_OPT_EXPORT_NAME (build/nbdclient.c).  This server implements exactly
// that path plus the list/info/go options of the NBD spec, and serves one raw
// disk image read-only by default.
//
// Built for Windows so the ROM package can ship a single .exe:
//
//	GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags "-s -w"
package main

import (
	"encoding/binary"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const (
	nbdMagic    = 0x4e42444d41474943 // "NBDMAGIC"
	optsMagic   = 0x49484156454f5054 // "IHAVEOPT"
	repMagic    = 0x0003e889045565a9
	reqMagic    = 0x25609513
	simpleReply = 0x67446698

	globalFixedNewstyle = 1
	globalNoZeroes      = 2
	clientFixedNewstyle = 1
	clientNoZeroes      = 2

	optExportName = 1
	optAbort      = 2
	optList       = 3
	optStartTLS   = 5
	optInfo       = 6
	optGo         = 7
	optStructRep  = 8
	optListMeta   = 9
	optSetMeta    = 10
	optExtHeaders = 11

	repAck    = 1
	repServer = 2
	repInfo   = 3

	infoExport = 0

	flagHasFlags  = 1
	flagReadOnly  = 2
	flagFlush     = 4
	flagTrim      = 32
	cmdRead       = 0
	cmdWrite      = 1
	cmdDisc       = 2
	cmdFlush      = 3
	cmdTrim       = 4
	errPerm       = 1
	errInval      = 22
	maxRequestLen = 4 << 20
)

func repErr(code uint32) uint32 { return 1<<31 | code }

type image struct {
	f     *os.File
	size  int64
	ro    bool
	mu    sync.RWMutex
	reads atomic.Int64
}

func openImage(path string, ro bool) (*image, error) {
	flags := os.O_RDONLY
	if !ro {
		flags = os.O_RDWR
	}
	f, err := os.OpenFile(path, flags, 0)
	if err != nil {
		return nil, err
	}
	st, err := f.Stat()
	if err != nil {
		f.Close()
		return nil, err
	}
	return &image{f: f, size: st.Size(), ro: ro}, nil
}

func (im *image) readAt(p []byte, off int64) error {
	im.mu.RLock()
	n, err := im.f.ReadAt(p, off)
	im.mu.RUnlock()
	im.reads.Add(int64(n))
	if len(p) > n {
		for i := n; i < len(p); i++ {
			p[i] = 0
		}
	}
	if err != nil && !errors.Is(err, io.EOF) {
		return err
	}
	return nil
}

func (im *image) writeAt(p []byte, off int64) error {
	if im.ro {
		return errors.New("read-only export")
	}
	im.mu.Lock()
	defer im.mu.Unlock()
	_, err := im.f.WriteAt(p, off)
	return err
}

func (im *image) flush() error {
	im.mu.Lock()
	defer im.mu.Unlock()
	return im.f.Sync()
}

func (im *image) flags() uint16 {
	f := uint16(flagHasFlags | flagFlush | flagTrim)
	if im.ro {
		f |= flagReadOnly
	}
	return f
}

func readFull(c net.Conn, n int) ([]byte, error) {
	buf := make([]byte, n)
	if _, err := io.ReadFull(c, buf); err != nil {
		return nil, err
	}
	return buf, nil
}

func writeAll(c net.Conn, parts ...[]byte) error {
	for _, p := range parts {
		if _, err := c.Write(p); err != nil {
			return err
		}
	}
	return nil
}

func u32(v uint32) []byte {
	b := make([]byte, 4)
	binary.BigEndian.PutUint32(b, v)
	return b
}

func u64(v uint64) []byte {
	b := make([]byte, 8)
	binary.BigEndian.PutUint64(b, v)
	return b
}

func sendReply(c net.Conn, option, rtype uint32, payload []byte) error {
	return writeAll(c, u64(repMagic), u32(option), u32(rtype), u32(uint32(len(payload))), payload)
}

type server struct {
	img     *image
	exports map[string]bool
	verbose bool
	logMu   sync.Mutex
}

func (s *server) logf(format string, args ...any) {
	s.logMu.Lock()
	defer s.logMu.Unlock()
	fmt.Printf("%s %s\n", time.Now().Format("15:04:05"), fmt.Sprintf(format, args...))
}

func (s *server) exportFlags() []byte {
	f := s.img.flags()
	b := make([]byte, 2)
	binary.BigEndian.PutUint16(b, f)
	return b
}

func (s *server) serve(conn net.Conn, peer string) {
	defer conn.Close()
	if tcp, ok := conn.(*net.TCPConn); ok {
		tcp.SetNoDelay(true)
	}
	s.logf("connection from %s", peer)
	defer func() {
		s.logf("%s closed (bytes read %d)", peer, s.img.reads.Load())
	}()

	// Greeting: fixed-newstyle, no zero padding unless the client asks.
	if err := writeAll(conn, []byte("NBDMAGIC"), u64(optsMagic),
		u32(globalFixedNewstyle|globalNoZeroes)); err != nil {
		s.logf("%s greeting failed: %v", peer, err)
		return
	}
	raw, err := readFull(conn, 4)
	if err != nil {
		s.logf("%s client flags: %v", peer, err)
		return
	}
	cflags := binary.BigEndian.Uint32(raw)
	noZeroes := cflags&clientNoZeroes != 0
	if cflags&clientFixedNewstyle == 0 {
		s.logf("%s plain newstyle client (no fixed-newstyle flag)", peer)
	}

	export := ""
	transmitting := false
	for !transmitting {
		hdr, err := readFull(conn, 16)
		if err != nil {
			s.logf("%s option header: %v", peer, err)
			return
		}
		omagic := binary.BigEndian.Uint64(hdr[0:8])
		opt := binary.BigEndian.Uint32(hdr[8:12])
		optLen := binary.BigEndian.Uint32(hdr[12:16])
		if omagic != optsMagic {
			s.logf("%s bad option magic 0x%x", peer, omagic)
			return
		}
		var payload []byte
		if optLen > 0 {
			if payload, err = readFull(conn, int(optLen)); err != nil {
				s.logf("%s option payload: %v", peer, err)
				return
			}
		}
		switch opt {
		case optAbort:
			sendReply(conn, opt, repAck, nil)
			s.logf("%s aborted negotiation", peer)
			return
		case optList:
			for name := range s.exports {
				if err := sendReply(conn, opt, repServer, append(u32(uint32(len(name))), []byte(name)...)); err != nil {
					return
				}
			}
			if err := sendReply(conn, opt, repAck, nil); err != nil {
				return
			}
		case optInfo, optGo:
			name := ""
			if len(payload) >= 4 {
				n := binary.BigEndian.Uint32(payload[0:4])
				if int(n) <= len(payload)-4 {
					name = string(payload[4 : 4+n])
				}
			}
			if !s.exports[name] {
				s.logf("%s unknown export %q", peer, name)
				if err := sendReply(conn, opt, repErr(6), u32(repErr(6))); err != nil {
					return
				}
				continue
			}
			info := make([]byte, 12)
			binary.BigEndian.PutUint16(info[0:2], infoExport)
			binary.BigEndian.PutUint64(info[2:10], uint64(s.img.size))
			binary.BigEndian.PutUint16(info[10:12], s.img.flags())
			if err := sendReply(conn, opt, repInfo, info); err != nil {
				return
			}
			if err := sendReply(conn, opt, repAck, nil); err != nil {
				return
			}
			export = name
			transmitting = opt == optGo
		case optExportName:
			name := string(payload)
			if !s.exports[name] {
				s.logf("%s EXPORT_NAME unknown export %q, dropping", peer, name)
				return
			}
			export = name
			reply := append(u64(uint64(s.img.size)), make([]byte, 2)...)
			binary.BigEndian.PutUint16(reply[8:10], s.img.flags())
			if !noZeroes {
				reply = append(reply, make([]byte, 124)...)
			}
			if err := writeAll(conn, reply); err != nil {
				s.logf("%s export reply: %v", peer, err)
				return
			}
			transmitting = true
		default:
			why := "unknown option"
			switch opt {
			case optStructRep:
				why = "structured replies"
			case optStartTLS:
				why = "TLS"
			case optListMeta, optSetMeta:
				why = "meta contexts"
			case optExtHeaders:
				why = "extended headers"
			}
			s.logf("%s rejected option %d (%s)", peer, opt, why)
			if err := sendReply(conn, opt, repErr(1), u32(repErr(1))); err != nil {
				return
			}
		}
	}
	s.logf("%s export %q (%d bytes)", peer, export, s.img.size)

	for {
		hdr, err := readFull(conn, 28)
		if err != nil {
			if !errors.Is(err, io.EOF) {
				s.logf("%s request: %v", peer, err)
			}
			return
		}
		magic := binary.BigEndian.Uint32(hdr[0:4])
		cmd := binary.BigEndian.Uint16(hdr[6:8])
		handle := binary.BigEndian.Uint64(hdr[8:16])
		off := binary.BigEndian.Uint64(hdr[16:24])
		ln := binary.BigEndian.Uint32(hdr[24:28])
		if magic != reqMagic {
			s.logf("%s bad request magic 0x%x", peer, magic)
			return
		}
		if s.verbose {
			s.logf("%s cmd=%d off=%d len=%d", peer, cmd, off, ln)
		}
		if cmd == cmdDisc {
			return
		}
		if cmd == cmdFlush {
			if err := s.img.flush(); err != nil {
				s.logf("%s flush: %v", peer, err)
			}
			writeAll(conn, u32(simpleReply), u32(0), u64(handle))
			continue
		}
		if ln == 0 || ln > maxRequestLen || off+uint64(ln) > uint64(s.img.size) {
			writeAll(conn, u32(simpleReply), u32(errInval), u64(handle))
			continue
		}
		switch cmd {
		case cmdRead:
			data := make([]byte, ln)
			if err := s.img.readAt(data, int64(off)); err != nil {
				s.logf("%s read: %v", peer, err)
				writeAll(conn, u32(simpleReply), u32(errInval), u64(handle))
				continue
			}
			if err := writeAll(conn, u32(simpleReply), u32(0), u64(handle), data); err != nil {
				return
			}
		case cmdWrite:
			data, err := readFull(conn, int(ln))
			if err != nil {
				s.logf("%s write payload: %v", peer, err)
				return
			}
			code := uint32(0)
			if err := s.img.writeAt(data, int64(off)); err != nil {
				code = errPerm
			}
			writeAll(conn, u32(simpleReply), u32(code), u64(handle))
		case cmdTrim:
			// The installer only reads. Treat trim as a successful no-op.
			writeAll(conn, u32(simpleReply), u32(0), u64(handle))
		default:
			writeAll(conn, u32(simpleReply), u32(errPerm), u64(handle))
		}
	}
}

func main() {
	imagePath := flag.String("image", "", "raw disk image to serve")
	listen := flag.String("listen", "0.0.0.0", "listen address")
	port := flag.Int("port", 10809, "listen port")
	exportList := flag.String("export", "arch,steamos", "comma-separated export names")
	// The initramfs mounts the export read-write (and the installer writes
	// its log there), so writes must be allowed by default.  --ro is for a
	// dry run against an image that must not change.
	readOnly := flag.Bool("ro", false, "serve read-only (the installer needs read-write)")
	verbose := flag.Bool("verbose", false, "log every NBD request")
	flag.Parse()

	if *imagePath == "" {
		fmt.Fprintln(os.Stderr, "usage: nbdserver --image <arch-nbd.img> [--port 10809] [--ro]")
		os.Exit(2)
	}
	im, err := openImage(*imagePath, *readOnly)
	if err != nil {
		fmt.Fprintf(os.Stderr, "nbdserver: %v\n", err)
		os.Exit(1)
	}
	exports := make(map[string]bool)
	for _, name := range strings.Split(*exportList, ",") {
		if name = strings.TrimSpace(name); name != "" {
			exports[name] = true
		}
	}
	s := &server{img: im, exports: exports, verbose: *verbose}

	ln, err := net.Listen("tcp", fmt.Sprintf("%s:%d", *listen, *port))
	if err != nil {
		fmt.Fprintf(os.Stderr, "nbdserver: %v\n", err)
		os.Exit(1)
	}
	mode := "read-only"
	if !im.ro {
		mode = "read-write"
	}
	fmt.Printf("serving %s (%d bytes, %s) on %s:%d exports=%s\n",
		*imagePath, im.size, mode, *listen, *port, *exportList)
	fmt.Println("waiting for the tablet (172.16.42.2-10:10809); keep this window open")
	for {
		conn, err := ln.Accept()
		if err != nil {
			fmt.Fprintf(os.Stderr, "nbdserver: accept: %v\n", err)
			continue
		}
		go s.serve(conn, conn.RemoteAddr().String())
	}
}
