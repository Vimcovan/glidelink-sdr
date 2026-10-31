// glidelink-streamd: sample streams between the board's IIO DMA buffers and TCP clients,
// for rates iiod does not reach over the USB network link (docs/known_issues.md 1.3).
//
// iiod answers one buffer per request (a client waits a round trip for each) and copies
// every buffer once more in user space. Here a stream runs continuously: RX buffers are
// sent as they are filled, TX buffers pushed as they arrive. The board's CPU spends about
// one core per 200 MB/s of TCP (copy and checksum: the USB network function has no
// offloads), so a stream can be spread over several connections, each served by its own
// thread: buffer i goes over connection i mod K. The words pass unchanged (raw samples or
// the shell's packet headers alike); configuration (sample rate, routes, header mode, ...)
// stays with libiio / iiod.
//
// Protocol (TCP port 7040):
//   first connection   "GLS1 <rx|tx> <iio device> <samples per buffer> <kernel buffers> <ch,ch,...> [K]\n"
//                      <- "OK <bytes per sample> <stream id>\n"  or  "ERR <message>\n"
//   connections 1..K-1 "GLS1 join <stream id> <k>\n"  <- "OK\n"
//   then, per buffer, in the stream's direction, on connection i mod K:
//                      uint32 magic 0x31534C47 ("GLS1"), uint32 length in bytes, the bytes
//                      (TX: a buffer shorter than the full one is pushed as a partial buffer)
//   Closing any connection ends the stream.
//
//     glidelink_streamd [port]

#include <errno.h>
#include <iio.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <syslog.h>
#include <time.h>
#include <unistd.h>

#define MAGIC 0x31534C47u
#define SOCK_BUF (8 << 20)
#define MAX_CONNS 4
#define SLOTS_PER_CONN 3

struct slot {
	char *data;
	size_t len;
	long seq;               // buffer number held, -1 = free
};

struct stream {
	int id;
	bool tx;
	int conns, joined;
	int fd[MAX_CONNS];
	struct iio_buffer *buf;
	size_t step, len;       // bytes per sample, samples per buffer
	int nslots;
	struct slot slot[MAX_CONNS * SLOTS_PER_CONN];
	bool stop;
	pthread_mutex_t mtx;
	pthread_cond_t cond;
	struct stream *next;
};

static pthread_mutex_t streams_mtx = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t streams_cond = PTHREAD_COND_INITIALIZER;
static struct stream *streams;
static int next_id = 1;

static int read_full(int fd, void *p, size_t n)
{
	char *c = p;
	while (n) {
		ssize_t k = recv(fd, c, n, 0);
		if (k <= 0)
			return -1;
		c += k;
		n -= k;
	}
	return 0;
}

static int write_iov(int fd, struct iovec *iov, int cnt)
{
	while (cnt) {
		ssize_t k = writev(fd, iov, cnt);
		if (k < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		while (cnt && (size_t)k >= iov->iov_len) {
			k -= iov->iov_len;
			iov++;
			cnt--;
		}
		if (cnt) {
			iov->iov_base = (char *)iov->iov_base + k;
			iov->iov_len -= k;
		}
	}
	return 0;
}

static void sendf(int fd, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
#include <stdarg.h>
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

static void stop_stream(struct stream *st)
{
	pthread_mutex_lock(&st->mtx);
	if (!st->stop) {
		st->stop = true;
		for (int k = 0; k < st->conns; k++)
			if (st->fd[k] >= 0)
				shutdown(st->fd[k], SHUT_RDWR);
	}
	pthread_cond_broadcast(&st->cond);
	pthread_mutex_unlock(&st->mtx);
}

// wait until slot s holds buffer `want` (want >= 0) or is free (want = -1); false: stopped first
static bool wait_slot(struct stream *st, struct slot *s, long want)
{
	pthread_mutex_lock(&st->mtx);
	while (!st->stop && s->seq != want)
		pthread_cond_wait(&st->cond, &st->mtx);
	// a buffer already there is still passed on after a stop (TX: received data gets pushed)
	bool ok = s->seq == want && (want >= 0 || !st->stop);
	pthread_mutex_unlock(&st->mtx);
	return ok;
}

static void set_slot(struct stream *st, struct slot *s, long seq)
{
	pthread_mutex_lock(&st->mtx);
	s->seq = seq;
	pthread_cond_broadcast(&st->cond);
	pthread_mutex_unlock(&st->mtx);
}

struct worker_arg {
	struct stream *st;
	int k;
};

// RX: connection k sends buffers k, k + K, ...
static void *rx_sender(void *arg)
{
	struct worker_arg *w = arg;
	struct stream *st = w->st;
	for (long i = w->k;; i += st->conns) {
		struct slot *s = &st->slot[i % st->nslots];
		if (!wait_slot(st, s, i))
			break;
		uint32_t hdr[2] = {MAGIC, (uint32_t)s->len};
		struct iovec iov[2] = {{hdr, sizeof hdr}, {s->data, s->len}};
		if (write_iov(st->fd[w->k], iov, 2) < 0)
			break;
		set_slot(st, s, -1);
	}
	stop_stream(st);
	return NULL;
}

// RX: refill, copy into the next slot (a memory copy is cheap next to TCP's)
static void rx_filler(struct stream *st)
{
	for (long i = 0; !st->stop; i++) {
		ssize_t n;
		do {
			n = iio_buffer_refill(st->buf);   // times out while the RX streamer is held off
		} while (n == -ETIMEDOUT && !st->stop);
		if (n < 0)
			break;
		struct slot *s = &st->slot[i % st->nslots];
		if (!wait_slot(st, s, -1))
			break;
		memcpy(s->data, iio_buffer_start(st->buf), n);
		s->len = n;
		set_slot(st, s, i);
	}
	stop_stream(st);
}

// TX: connection k receives buffers k, k + K, ...
static void *tx_receiver(void *arg)
{
	struct worker_arg *w = arg;
	struct stream *st = w->st;
	size_t full = st->len * st->step;
	for (long i = w->k;; i += st->conns) {
		struct slot *s = &st->slot[i % st->nslots];
		if (!wait_slot(st, s, -1))
			break;
		uint32_t hdr[2];
		if (read_full(st->fd[w->k], hdr, sizeof hdr) < 0 || hdr[0] != MAGIC || hdr[1] > full ||
		    hdr[1] % st->step || read_full(st->fd[w->k], s->data, hdr[1]) < 0)
			break;
		s->len = hdr[1];
		set_slot(st, s, i);
	}
	stop_stream(st);
	return NULL;
}

// TX: push the buffers in order
static void tx_pusher(struct stream *st)
{
	for (long i = 0;; i++) {
		struct slot *s = &st->slot[i % st->nslots];
		if (!wait_slot(st, s, i))
			break;
		memcpy(iio_buffer_start(st->buf), s->data, s->len);
		size_t samples = s->len / st->step;
		ssize_t r = samples == st->len ? iio_buffer_push(st->buf) : iio_buffer_push_partial(st->buf, samples);
		set_slot(st, s, -1);
		if (r < 0) {
			syslog(LOG_WARNING, "push: %s", strerror((int)-r));
			break;
		}
	}
	stop_stream(st);
}

static void run_stream(struct stream *st)
{
	pthread_t t[MAX_CONNS];
	struct worker_arg wa[MAX_CONNS];
	for (int k = 0; k < st->conns; k++) {
		wa[k] = (struct worker_arg){st, k};
		pthread_create(&t[k], NULL, st->tx ? tx_receiver : rx_sender, &wa[k]);
	}
	if (st->tx)
		tx_pusher(st);
	else
		rx_filler(st);
	for (int k = 0; k < st->conns; k++)
		pthread_join(t[k], NULL);
}

// a connection joining stream `id` as connection k: hand the socket over, the stream's
// first connection serves it
static void join(int fd, int id, int k)
{
	pthread_mutex_lock(&streams_mtx);
	struct stream *st = streams;
	while (st && st->id != id)
		st = st->next;
	if (!st || k <= 0 || k >= st->conns || st->fd[k] >= 0) {
		pthread_mutex_unlock(&streams_mtx);
		sendf(fd, "ERR no stream %d connection %d\n", id, k);
		close(fd);
		return;
	}
	st->fd[k] = fd;
	st->joined++;
	sendf(fd, "OK\n");
	pthread_cond_broadcast(&streams_cond);
	pthread_mutex_unlock(&streams_mtx);
}

static void *client(void *arg)
{
	int fd = (int)(intptr_t)arg;
	char line[512], dir[8], devname[64], chans[256];
	unsigned long len, kbufs;
	int conns = 1, id, k;
	struct iio_context *ctx = NULL;
	struct stream *st = NULL;

	int sz = SOCK_BUF, one = 1;
	setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sz, sizeof sz);
	setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &sz, sizeof sz);
	setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
	// a client that stops answering (cable pulled, PC asleep, frames dropped on the way) ends the
	// stream after 5 s instead of holding the IIO buffer for TCP's retransmission minutes
	unsigned int user_timeout = 5000;
	setsockopt(fd, IPPROTO_TCP, TCP_USER_TIMEOUT, &user_timeout, sizeof user_timeout);

	if (read_line(fd, line, sizeof line) < 0) {
		close(fd);
		return NULL;
	}
	if (sscanf(line, "GLS1 join %d %d", &id, &k) == 2) {
		join(fd, id, k);
		return NULL;
	}
	int n = sscanf(line, "GLS1 %7s %63s %lu %lu %255s %d", dir, devname, &len, &kbufs, chans, &conns);
	if (n < 5 || (strcmp(dir, "rx") && strcmp(dir, "tx")) || len == 0 || kbufs == 0 || conns < 1 ||
	    conns > MAX_CONNS) {
		sendf(fd, "ERR bad request\n");
		close(fd);
		return NULL;
	}
	st = calloc(1, sizeof *st);
	st->tx = !strcmp(dir, "tx");
	st->conns = conns;
	st->joined = 1;
	st->len = len;
	for (k = 0; k < MAX_CONNS; k++)
		st->fd[k] = -1;
	st->fd[0] = fd;
	pthread_mutex_init(&st->mtx, NULL);
	pthread_cond_init(&st->cond, NULL);

	ctx = iio_create_local_context();
	struct iio_device *dev = ctx ? iio_context_find_device(ctx, devname) : NULL;
	if (!dev) {
		sendf(fd, "ERR no IIO device %s\n", devname);
		goto out;
	}
	for (unsigned i = 0; i < iio_device_get_channels_count(dev); i++)
		iio_channel_disable(iio_device_get_channel(dev, i));
	for (char *save, *c = strtok_r(chans, ",", &save); c; c = strtok_r(NULL, ",", &save)) {
		struct iio_channel *ch = iio_device_find_channel(dev, c, st->tx);
		if (!ch) {
			sendf(fd, "ERR no channel %s\n", c);
			goto out;
		}
		iio_channel_enable(ch);
	}
	iio_context_set_timeout(ctx, 1000);
	iio_device_set_kernel_buffers_count(dev, kbufs);
	st->buf = iio_device_create_buffer(dev, len, false);
	if (!st->buf) {
		sendf(fd, "ERR cannot create the buffer: %s\n", strerror(errno));
		goto out;
	}
	st->step = iio_buffer_step(st->buf);
	st->nslots = conns * SLOTS_PER_CONN;
	for (int i = 0; i < st->nslots; i++) {
		st->slot[i].data = malloc(len * st->step);
		st->slot[i].seq = -1;
	}

	pthread_mutex_lock(&streams_mtx);
	st->id = next_id++;
	st->next = streams;
	streams = st;
	pthread_mutex_unlock(&streams_mtx);
	sendf(fd, "OK %zu %d\n", st->step, st->id);

	// the other connections join within 5 s
	struct timespec dl;
	clock_gettime(CLOCK_REALTIME, &dl);
	dl.tv_sec += 5;
	pthread_mutex_lock(&streams_mtx);
	while (st->joined < st->conns && pthread_cond_timedwait(&streams_cond, &streams_mtx, &dl) == 0)
		;
	bool all = st->joined == st->conns;
	pthread_mutex_unlock(&streams_mtx);
	if (all) {
		syslog(LOG_INFO, "%s %s: %lu samples x %lu buffers, %zu bytes per sample, %d connections", dir,
		       devname, len, kbufs, st->step, conns);
		run_stream(st);
		syslog(LOG_INFO, "%s %s: end", dir, devname);
	} else {
		syslog(LOG_WARNING, "%s %s: only %d of %d connections joined", dir, devname, st->joined, conns);
	}

	pthread_mutex_lock(&streams_mtx);
	for (struct stream **p = &streams; *p; p = &(*p)->next)
		if (*p == st) {
			*p = st->next;
			break;
		}
	pthread_mutex_unlock(&streams_mtx);
out:
	if (st->buf)
		iio_buffer_destroy(st->buf);
	if (ctx)
		iio_context_destroy(ctx);
	for (k = 0; k < MAX_CONNS; k++)
		if (st->fd[k] >= 0)
			close(st->fd[k]);
	for (int i = 0; i < st->nslots; i++)
		free(st->slot[i].data);
	pthread_mutex_destroy(&st->mtx);
	pthread_cond_destroy(&st->cond);
	free(st);
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
