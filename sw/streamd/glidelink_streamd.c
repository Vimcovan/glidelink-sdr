// glidelink-streamd: sample streams between the board's IIO DMA buffers and the PC over UDP,
// for rates iiod does not reach over the USB network link (docs/known_issues.md 1.3).
//
// As UHD streams to network USRPs (host/docs/driver_usage/transport.dox, RFNoC specification
// 2.2.4): data in UDP packets with a sequence number, UDP checksum 0, flow control in both
// directions with stream status packets going the other way (TX: the board reports every 1/8
// of its buffer capacity consumed; RX: the PC reports every 1/32 of its own). The link is one
// USB cable, point to point: packets arrive in order, so a sequence gap means packets lost at
// a socket buffer, and flow control keeps the buffers from overflowing. The words pass
// unchanged (raw samples or the shell's packet headers alike); configuration (sample rate,
// routes, header mode, ...) stays with libiio / iiod.
//
// Setup over TCP (port 7040), which also bounds the stream's life:
//   PC -> board  "GLU1 <rx|tx> <iio device> <samples per buffer> <kernel buffers> <ch,ch,...>
//                 <PC UDP port> <frame bytes> <PC capacity bytes>\n"
//   board -> PC  "OK <bytes per sample> <board UDP port> <board capacity bytes>\n" or "ERR <msg>\n"
// UDP packets (frame bytes at most, header included), little endian:
//   uint32 magic 0x31554C47 ("GLU1"), uint16 type (0 data, 1 status), uint16 flags,
//   uint32 sequence number (per direction and type), uint32 reserved, then
//   data:   payload bytes (a multiple of the sample size); flag bit 0 = last packet of a buffer
//           (TX: the board pushes then, a shorter buffer as a partial one)
//   status: uint64 bytes consumed since the start of the stream
// Closing the TCP connection ends the stream.
//
//     glidelink_streamd [port]

#define _GNU_SOURCE                    // sendmmsg / recvmmsg
#include <arpa/inet.h>
#include <errno.h>
#include <iio.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <netinet/udp.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <syslog.h>
#include <unistd.h>

#ifndef UDP_SEGMENT
#define UDP_SEGMENT 103
#endif

#define MAGIC 0x31554C47u
#define TYPE_DATA 0
#define TYPE_STATUS 1
#define FLAG_END 1
#define HDR 16
#define BATCH 64
#define SOCK_BUF (16 << 20)

struct hdr {
	uint32_t magic;
	uint16_t type, flags;
	uint32_t seq, reserved;
};

struct stream {
	bool tx;
	int udp;                        // connected to the PC's UDP port
	struct iio_buffer *buf;
	size_t step, len;               // bytes per sample, samples per buffer
	size_t frame;                   // UDP payload bytes at most (header included)
	uint64_t peer_capacity;         // RX: the PC's buffer capacity
	uint64_t capacity;              // TX: the board's
	volatile bool stop;
	uint64_t lost;                  // TX: packets missing (sequence gaps)
	uint64_t backwards;             // TX: packets older than the one before (should never happen)
};

static void sendf(int fd, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static void sendf(int fd, const char *fmt, ...)
{
	char line[256];
	va_list ap;
	va_start(ap, fmt);
	int n = vsnprintf(line, sizeof line, fmt, ap);
	va_end(ap);
	send(fd, line, n, MSG_NOSIGNAL);
}

static int read_line(int fd, char *line, size_t size)
{
	size_t n = 0;
	while (n + 1 < size) {
		if (recv(fd, line + n, 1, 0) != 1)
			return -1;
		if (line[n] == '\n') {
			line[n] = 0;
			return 0;
		}
		n++;
	}
	return -1;
}

static void sock_bufs(int fd)
{
	int sz = SOCK_BUF;
	// root may exceed net.core.[rw]mem_max; fall back to the capped request otherwise
	if (setsockopt(fd, SOL_SOCKET, SO_RCVBUFFORCE, &sz, sizeof sz) < 0)
		setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &sz, sizeof sz);
	if (setsockopt(fd, SOL_SOCKET, SO_SNDBUFFORCE, &sz, sizeof sz) < 0)
		setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sz, sizeof sz);
}

// RX: read the status packets waiting (or wait up to timeout_ms for one); the PC's consumed count
static void rx_status(struct stream *st, uint64_t *consumed, int timeout_ms)
{
	struct pollfd p = {st->udp, POLLIN, 0};
	if (timeout_ms > 0 && poll(&p, 1, timeout_ms) <= 0)
		return;
	char pkt[64];
	for (;;) {
		ssize_t k = recv(st->udp, pkt, sizeof pkt, MSG_DONTWAIT);
		if (k < 0)
			return;
		struct hdr *h = (struct hdr *)pkt;
		if (k >= HDR + 8 && h->magic == MAGIC && h->type == TYPE_STATUS) {
			uint64_t c;
			memcpy(&c, pkt + HDR, 8);
			if (c > *consumed)
				*consumed = c;
		}
	}
}

// RX: refill, send the buffer in packets within the PC's capacity; waiting for room holds the
// refills back, so the DMA, not a socket, drops samples when the PC falls behind
//
// The packets of a batch go out as one UDP segmentation offload send (UDP_SEGMENT: the kernel cuts
// the header / payload pairs into packets of HDR + payload bytes), which costs the board's CPU
// about 1/1.7 of one send per packet. It needs checksum offload on the network device (the
// boards' NCM function has it with kernel patch 0005, which writes UDP checksum 0); without it
// the send fails and the packets go one by one (sendmmsg) with checksum 0 (SO_NO_CHECK).
static void rx_loop(struct stream *st)
{
	size_t payload = (st->frame - HDR) / st->step * st->step;
	uint64_t sent = 0, consumed = 0;
	uint32_t seq = 0;
	struct hdr hdrs[BATCH];
	struct iovec iov[BATCH][2];
	struct mmsghdr msgs[BATCH];
	int seg = (int)(HDR + payload);
	bool gso = setsockopt(st->udp, SOL_UDP, UDP_SEGMENT, &seg, sizeof seg) == 0;
	int max_pkts = gso ? (int)(65000 / seg) : BATCH;   // one UDP send carries 64 KB at most
	if (max_pkts > BATCH)
		max_pkts = BATCH;
	if (max_pkts < 1)
		max_pkts = 1;
	while (!st->stop) {
		ssize_t n = iio_buffer_refill(st->buf);
		if (n == -ETIMEDOUT)
			continue;               // the RX streamer is held off
		if (n < 0)
			break;
		char *data = iio_buffer_start(st->buf);
		size_t off = 0;
		while (off < (size_t)n && !st->stop) {
			rx_status(st, &consumed, 0);
			int cnt = 0;
			while (cnt < max_pkts && off < (size_t)n) {
				size_t len = (size_t)n - off < payload ? (size_t)n - off : payload;
				if (sent + len - consumed > st->peer_capacity)
					break;
				hdrs[cnt] = (struct hdr){MAGIC, TYPE_DATA, off + len == (size_t)n ? FLAG_END : 0, seq++, 0};
				iov[cnt][0] = (struct iovec){&hdrs[cnt], HDR};
				iov[cnt][1] = (struct iovec){data + off, len};
				msgs[cnt] = (struct mmsghdr){.msg_hdr = {.msg_iov = iov[cnt], .msg_iovlen = 2}};
				off += len;
				sent += len;
				cnt++;
			}
			if (cnt == 0) {
				rx_status(st, &consumed, 100);  // no room at the PC: wait for its status
				continue;
			}
			if (gso) {
				// the pairs of this batch, in order, as one message (only the last packet of a
				// buffer can be shorter, and it is the last of its batch)
				struct msghdr mh = {.msg_iov = &iov[0][0], .msg_iovlen = 2 * cnt};
				for (;;) {
					if (sendmsg(st->udp, &mh, 0) >= 0 || st->stop)
						break;
					if (errno == EINTR || errno == ENOBUFS || errno == EAGAIN || errno == ECONNREFUSED) {
						usleep(100);
						continue;
					}
					if (errno == EIO || errno == EINVAL) {      // no checksum offload: one by one
						syslog(LOG_INFO, "rx: no UDP segmentation offload, packets one by one");
						int one = 1, zero = 0;
						setsockopt(st->udp, SOL_UDP, UDP_SEGMENT, &zero, sizeof zero);
						setsockopt(st->udp, SOL_SOCKET, SO_NO_CHECK, &one, sizeof one);
						gso = false;
						max_pkts = BATCH;
						break;
					}
					syslog(LOG_WARNING, "rx send: %s", strerror(errno));
					st->stop = true;
					break;
				}
				if (gso)
					continue;
			}
			for (int done = 0; done < cnt && !st->stop;) {
				int k = sendmmsg(st->udp, msgs + done, cnt - done, 0);
				if (k < 0) {
					if (errno == EINTR || errno == ENOBUFS || errno == EAGAIN || errno == ECONNREFUSED) {
						usleep(100);    // ECONNREFUSED: the PC's port not open yet
						continue;
					}
					syslog(LOG_WARNING, "rx send: %s", strerror(errno));
					st->stop = true;
					break;
				}
				done += k;
			}
		}
	}
}

// TX: receive packets, copy them into the DMA block, push at the end of each buffer; report the
// bytes taken from the socket every 1/8 of the capacity
static void tx_loop(struct stream *st)
{
	size_t full = st->len * st->step, pos = 0;
	uint64_t consumed = 0, reported = 0, every = st->capacity / 8;
	uint32_t expect = 0, status_seq = 0;
	bool first = true;
	char *slots = malloc((size_t)BATCH * st->frame);
	struct iovec iov[BATCH];
	struct mmsghdr msgs[BATCH];
	char *dst = iio_buffer_start(st->buf);
	while (!st->stop) {
		for (int i = 0; i < BATCH; i++) {
			iov[i] = (struct iovec){slots + (size_t)i * st->frame, st->frame};
			msgs[i] = (struct mmsghdr){.msg_hdr = {.msg_iov = &iov[i], .msg_iovlen = 1}};
		}
		struct pollfd p = {st->udp, POLLIN, 0};
		if (poll(&p, 1, 100) <= 0)
			continue;
		int n = recvmmsg(st->udp, msgs, BATCH, MSG_DONTWAIT, NULL);
		if (n <= 0)
			continue;
		for (int i = 0; i < n && !st->stop; i++) {
			char *pkt = slots + (size_t)i * st->frame;
			size_t k = msgs[i].msg_len;
			struct hdr *h = (struct hdr *)pkt;
			if (k < HDR || h->magic != MAGIC || h->type != TYPE_DATA)
				continue;
			int32_t gap = (int32_t)(h->seq - expect);
			if (!first && gap > 0)
				st->lost += gap;
			else if (!first && gap < 0)
				st->backwards++;
			first = false;
			expect = h->seq + 1;
			size_t len = k - HDR;
			if (pos + len > full)
				len = full - pos;
			len -= len % st->step;
			memcpy(dst + pos, pkt + HDR, len);
			pos += len;
			consumed += k - HDR;
			if (pos == full || ((h->flags & FLAG_END) && pos > 0)) {
				ssize_t r = pos == full ? iio_buffer_push(st->buf)
							: iio_buffer_push_partial(st->buf, pos / st->step);
				if (r < 0) {
					syslog(LOG_WARNING, "push: %s", strerror((int)-r));
					st->stop = true;
				}
				dst = iio_buffer_start(st->buf);
				pos = 0;
			}
		}
		if (consumed - reported >= every) {
			char pkt[HDR + 8];
			*(struct hdr *)pkt = (struct hdr){MAGIC, TYPE_STATUS, 0, status_seq++, 0};
			memcpy(pkt + HDR, &consumed, 8);
			send(st->udp, pkt, sizeof pkt, 0);
			reported = consumed;
		}
	}
	free(slots);
}

static void *worker(void *arg)
{
	struct stream *st = arg;
	if (st->tx)
		tx_loop(st);
	else
		rx_loop(st);
	st->stop = true;
	return NULL;
}

static void *client(void *arg)
{
	int fd = (int)(intptr_t)arg;
	char line[512], dir[8], devname[64], chans[256];
	unsigned long len, kbufs, frame;
	unsigned port;
	unsigned long long peer_cap;
	struct iio_context *ctx = NULL;
	struct stream st = {0};
	st.udp = -1;

	int one = 1, zero = 0;
	setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
	// a PC that stops answering ends the stream after 5 s
	unsigned int user_timeout = 5000;
	setsockopt(fd, IPPROTO_TCP, TCP_USER_TIMEOUT, &user_timeout, sizeof user_timeout);

	if (read_line(fd, line, sizeof line) < 0 ||
	    sscanf(line, "GLU1 %7s %63s %lu %lu %255s %u %lu %llu", dir, devname, &len, &kbufs, chans, &port,
		   &frame, &peer_cap) != 8 ||
	    (strcmp(dir, "rx") && strcmp(dir, "tx")) || len == 0 || kbufs == 0 || port == 0 ||
	    port > 65535 || frame < HDR + 64 || frame > 65000 || peer_cap == 0) {
		sendf(fd, "ERR bad request\n");
		goto out;
	}
	st.tx = !strcmp(dir, "tx");
	st.len = len;
	st.frame = frame;
	st.peer_capacity = peer_cap;

	ctx = iio_create_local_context();
	struct iio_device *dev = ctx ? iio_context_find_device(ctx, devname) : NULL;
	if (!dev) {
		sendf(fd, "ERR no IIO device %s\n", devname);
		goto out;
	}
	for (unsigned i = 0; i < iio_device_get_channels_count(dev); i++)
		iio_channel_disable(iio_device_get_channel(dev, i));
	for (char *save, *c = strtok_r(chans, ",", &save); c; c = strtok_r(NULL, ",", &save)) {
		struct iio_channel *ch = iio_device_find_channel(dev, c, st.tx);
		if (!ch) {
			sendf(fd, "ERR no channel %s\n", c);
			goto out;
		}
		iio_channel_enable(ch);
	}
	iio_context_set_timeout(ctx, 1000);
	iio_device_set_kernel_buffers_count(dev, kbufs);
	st.buf = iio_device_create_buffer(dev, len, false);
	if (!st.buf) {
		sendf(fd, "ERR cannot create the buffer: %s\n", strerror(errno));
		goto out;
	}
	st.step = iio_buffer_step(st.buf);
	if (frame - HDR < st.step) {
		sendf(fd, "ERR frame too small\n");
		goto out;
	}

	// the UDP socket, connected to the PC's port at the address the TCP connection came from
	struct sockaddr_in6 peer;
	socklen_t plen = sizeof peer;
	getpeername(fd, (struct sockaddr *)&peer, &plen);
	st.udp = socket(AF_INET6, SOCK_DGRAM, 0);
	setsockopt(st.udp, IPPROTO_IPV6, IPV6_V6ONLY, &zero, sizeof zero);
	// UDP checksum 0, as the FPGA of network USRPs sends: written by the NCM driver for segmented
	// sends (kernel patch 0005), SO_NO_CHECK when packets go one by one (rx_loop)
	sock_bufs(st.udp);
	struct sockaddr_in6 me = {.sin6_family = AF_INET6, .sin6_addr = in6addr_any};
	bind(st.udp, (struct sockaddr *)&me, sizeof me);
	socklen_t mlen = sizeof me;
	getsockname(st.udp, (struct sockaddr *)&me, &mlen);
	peer.sin6_port = htons(port);
	if (connect(st.udp, (struct sockaddr *)&peer, plen) < 0) {
		sendf(fd, "ERR udp connect: %s\n", strerror(errno));
		goto out;
	}
	int rcv = 0;
	socklen_t rl = sizeof rcv;
	getsockopt(st.udp, SOL_SOCKET, SO_RCVBUF, &rcv, &rl);
	st.capacity = (uint64_t)rcv / 4;        // payload that fits, with the kernel's per-packet overhead

	sendf(fd, "OK %zu %u %llu\n", st.step, ntohs(me.sin6_port), (unsigned long long)st.capacity);
	syslog(LOG_INFO, "%s %s: %lu samples x %lu buffers, %zu bytes per sample, UDP frames %lu, capacity %llu",
	       dir, devname, len, kbufs, st.step, frame, (unsigned long long)(st.tx ? st.capacity : peer_cap));

	pthread_t t;
	pthread_create(&t, NULL, worker, &st);
	char c;
	struct pollfd p = {fd, POLLIN, 0};
	while (!st.stop) {
		if (poll(&p, 1, 200) > 0 && recv(fd, &c, 1, 0) <= 0)
			break;                  // the PC closed the stream
	}
	st.stop = true;
	pthread_join(t, NULL);
	if (st.tx)
		syslog(LOG_INFO, "%s %s: end, %llu packets lost, %llu out of order", dir, devname,
		       (unsigned long long)st.lost, (unsigned long long)st.backwards);
	else
		syslog(LOG_INFO, "%s %s: end", dir, devname);
out:
	if (st.udp >= 0)
		close(st.udp);
	if (st.buf)
		iio_buffer_destroy(st.buf);
	if (ctx)
		iio_context_destroy(ctx);
	close(fd);
	return NULL;
}

int main(int argc, char **argv)
{
	int port = argc > 1 ? atoi(argv[1]) : 7040, one = 1, zero = 0;
	signal(SIGPIPE, SIG_IGN);
	openlog("glidelink-streamd", LOG_PERROR, LOG_DAEMON);
	int s = socket(AF_INET6, SOCK_STREAM, 0);
	setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
	setsockopt(s, IPPROTO_IPV6, IPV6_V6ONLY, &zero, sizeof zero);
	struct sockaddr_in6 a = {.sin6_family = AF_INET6, .sin6_port = htons(port), .sin6_addr = in6addr_any};
	if (bind(s, (struct sockaddr *)&a, sizeof a) < 0 || listen(s, 16) < 0) {
		syslog(LOG_ERR, "port %d: %s", port, strerror(errno));
		return 1;
	}
	syslog(LOG_INFO, "listening on port %d", port);
	for (;;) {
		int fd = accept(s, NULL, NULL);
		if (fd < 0)
			continue;
		pthread_t t;
		if (pthread_create(&t, NULL, client, (void *)(intptr_t)fd) == 0)
			pthread_detach(t);
		else
			close(fd);
	}
}
