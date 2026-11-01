/*
 * nbdclient.c - minimal static NBD client for the TB710FU initramfs.
 *
 * Busybox's nbd-client applet reads only 2 of the 4 greeting flag bytes this server sends,
 * which leaves the stream shifted by two bytes: the export reply is parsed as a 1.5 TiB disk
 * and the kernel rejects it with "Wrong magic (0x6744)". This client speaks the same plain
 * newstyle handshake but reads the greeting exactly.
 *
 * usage: nbdclient HOST PORT EXPORT DEVICE [BLOCKSIZE]
 *
 * It connects, negotiates NBD_OPT_EXPORT_NAME, points the kernel nbd device at the socket,
 * forks the NBD_DO_IT server loop into its own session (so switch_root and the initramfs
 * process group cannot kill it), then rescans partitions and prints READY. The caller waits
 * for that line before mounting /dev/nbd0p2.
 *
 * No getaddrinfo: this runs before any root filesystem exists, so only numeric IPv4.
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/fs.h>
#include <linux/nbd.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#define NBD_MAGIC  0x4e42444d41474943ULL  /* "NBDMAGIC" */
#define OPTS_MAGIC 0x49484156454f5054ULL  /* "IHAVEOPT" */
#define OPT_EXPORT_NAME 1

static int read_full(int fd, void *buf, size_t len)
{
	char *p = buf;
	size_t off = 0;

	while (off < len) {
		ssize_t n = read(fd, p + off, len - off);

		if (n < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		if (n == 0)
			return -1;
		off += (size_t)n;
	}
	return 0;
}

static int write_full(int fd, const void *buf, size_t len)
{
	const char *p = buf;
	size_t off = 0;

	while (off < len) {
		ssize_t n = write(fd, p + off, len - off);

		if (n < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		off += (size_t)n;
	}
	return 0;
}

static void put_be32(unsigned char *p, uint32_t v)
{
	p[0] = (unsigned char)(v >> 24);
	p[1] = (unsigned char)(v >> 16);
	p[2] = (unsigned char)(v >> 8);
	p[3] = (unsigned char)v;
}

static void put_be64(unsigned char *p, uint64_t v)
{
	put_be32(p, (uint32_t)(v >> 32));
	put_be32(p + 4, (uint32_t)v);
}

static uint64_t get_be64(const unsigned char *p)
{
	return ((uint64_t)p[0] << 56) | ((uint64_t)p[1] << 48) |
	       ((uint64_t)p[2] << 40) | ((uint64_t)p[3] << 32) |
	       ((uint64_t)p[4] << 24) | ((uint64_t)p[5] << 16) |
	       ((uint64_t)p[6] << 8) | (uint64_t)p[7];
}

int main(int argc, char **argv)
{
	const char *host, *export_name, *device;
	unsigned long blocksize;
	struct sockaddr_in sa;
	unsigned char buf[256];
	uint64_t size;
	uint32_t global_flags;
	uint16_t transmission_flags;
	size_t name_len;
	int port, sock, dev, flags, ro = 0, i, ret = 1;
	pid_t pid;

	if (argc < 5 || argc > 6) {
		fprintf(stderr, "usage: %s HOST PORT EXPORT DEVICE [BLOCKSIZE]\n", argv[0]);
		return 2;
	}
	host = argv[1];
	port = atoi(argv[2]);
	export_name = argv[3];
	device = argv[4];
	blocksize = argc > 5 ? strtoul(argv[5], NULL, 10) : 4096;
	if (!port || !blocksize) {
		fprintf(stderr, "nbdclient: bad port or blocksize\n");
		return 2;
	}
	name_len = strlen(export_name);
	if (name_len == 0 || name_len > 255) {
		fprintf(stderr, "nbdclient: bad export name\n");
		return 2;
	}

	memset(&sa, 0, sizeof(sa));
	sa.sin_family = AF_INET;
	sa.sin_port = htons((uint16_t)port);
	if (inet_pton(AF_INET, host, &sa.sin_addr) != 1) {
		fprintf(stderr, "nbdclient: bad IPv4 address '%s'\n", host);
		return 2;
	}

	sock = socket(AF_INET, SOCK_STREAM, 0);
	if (sock < 0) {
		fprintf(stderr, "nbdclient: socket: %s\n", strerror(errno));
		return 1;
	}
	if (connect(sock, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
		fprintf(stderr, "nbdclient: connect %s:%d: %s\n", host, port, strerror(errno));
		close(sock);
		return 1;
	}

	/* greeting: NBDMAGIC | IHAVEOPT | 4-byte global flags */
	if (read_full(sock, buf, 20) < 0) {
		fprintf(stderr, "nbdclient: short greeting: %s\n", strerror(errno));
		goto out_sock;
	}
	if (get_be64(buf) != NBD_MAGIC || get_be64(buf + 8) != OPTS_MAGIC) {
		fprintf(stderr, "nbdclient: not an NBD newstyle server\n");
		goto out_sock;
	}
	global_flags = ((uint32_t)buf[16] << 24) | ((uint32_t)buf[17] << 16) |
		       ((uint32_t)buf[18] << 8) | (uint32_t)buf[19];

	/* plain newstyle: client flags 0, no structured replies, keep the 124 zero bytes */
	put_be32(buf, 0);
	if (write_full(sock, buf, 4) < 0)
		goto out_sock;

	/* option: NBD_OPT_EXPORT_NAME */
	put_be64(buf, OPTS_MAGIC);
	put_be32(buf + 8, OPT_EXPORT_NAME);
	put_be32(buf + 12, (uint32_t)name_len);
	memcpy(buf + 16, export_name, name_len);
	if (write_full(sock, buf, 16 + name_len) < 0)
		goto out_sock;

	/* reply: 8-byte size, 2-byte transmission flags, 124 reserved bytes */
	if (read_full(sock, buf, 8 + 2 + 124) < 0) {
		fprintf(stderr, "nbdclient: short export reply: %s\n", strerror(errno));
		goto out_sock;
	}
	size = get_be64(buf);
	transmission_flags = (uint16_t)((buf[8] << 8) | buf[9]);
	fprintf(stderr, "export %s: %llu bytes, flags 0x%x, blocksize %lu\n",
		export_name, (unsigned long long)size, transmission_flags, blocksize);

	dev = open(device, O_RDWR);
	if (dev < 0) {
		fprintf(stderr, "nbdclient: open %s: %s\n", device, strerror(errno));
		goto out_sock;
	}
	if (ioctl(dev, NBD_SET_BLKSIZE, blocksize) < 0) {
		fprintf(stderr, "nbdclient: NBD_SET_BLKSIZE: %s\n", strerror(errno));
		goto out_dev;
	}
	if (ioctl(dev, NBD_SET_SIZE_BLOCKS, size / blocksize) < 0) {
		fprintf(stderr, "nbdclient: NBD_SET_SIZE_BLOCKS: %s\n", strerror(errno));
		goto out_dev;
	}
	if (ioctl(dev, NBD_SET_SOCK, sock) < 0) {
		fprintf(stderr, "nbdclient: NBD_SET_SOCK: %s\n", strerror(errno));
		goto out_dev;
	}

	pid = fork();
	if (pid < 0) {
		fprintf(stderr, "nbdclient: fork: %s\n", strerror(errno));
		goto out_dev;
	}
	if (pid == 0) {
		/* serve the block device in our own session; initramfs teardown must not kill it */
		if (setsid() < 0)
			fprintf(stderr, "nbdclient: setsid: %s\n", strerror(errno));
		signal(SIGHUP, SIG_IGN);
		signal(SIGINT, SIG_IGN);
		signal(SIGTERM, SIG_IGN);
		signal(SIGCHLD, SIG_IGN);
		fprintf(stderr, "NBD_DO_IT on %s (pid %d)\n", device, (int)getpid());
		flags = ioctl(dev, NBD_DO_IT);
		fprintf(stderr, "NBD_DO_IT returned %d, errno %d (%s)\n",
			flags, errno, strerror(errno));
		ioctl(dev, NBD_CLEAR_QUE);
		ioctl(dev, NBD_CLEAR_SOCK);
		close(dev);
		close(sock);
		_exit(1);
	}

	/* the kernel needs a moment before the partition table can be read */
	for (i = 0; i < 20; i++) {
		usleep(100000);
		if (ioctl(dev, BLKRRPART) == 0)
			break;
	}
	if (i == 20)
		fprintf(stderr, "nbdclient: BLKRRPART did not succeed, continuing\n");
	if (ioctl(dev, BLKROSET, &ro) < 0)
		fprintf(stderr, "nbdclient: BLKROSET: %s\n", strerror(errno));

	printf("READY\n");
	fflush(stdout);
	ret = 0;

out_dev:
	close(dev);
out_sock:
	close(sock);
	return ret;
}
