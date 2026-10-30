// The bridge's high-rate paths in C on libiio (sw/bridge/glidelink_bridge.py loads it with
// ctypes, which releases the GIL during a call):
//
//   gl_rx      captures n samples from host port 0 with packet headers, all in C: in Python,
//              one readStream per 4096-sample packet tops out near 20 MSPS. The packet times
//              give each drop's position and size exactly.
//   gl_tx_cyclic_start / gl_tx_cyclic_stop
//              a libiio cyclic buffer on the TX DMA: the hardware repeats the waveform,
//              no CPU while it runs.
//
// Port setup as the Soapy module does it (setPortHeaders, activateStream): the port is
// flushed and its header bit set while its RX route is empty; the RX streamer is held off
// until the DMA has its buffers queued. The caller passes the PORT_RESET bits of the module
// slots on the port's path.
//
//   gcc -O2 -shared -fPIC -o libglidelink_fast.so glidelink_fast.c -liio

#include <errno.h>
#include <iio.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define REG_VERSION 0x004
#define REG_CONFIG 0x054
#define REG_PORT_RESET 0x05C
#define REG_ROUTE 0x1000
#define CFG_RX_ENABLE (1u << 0)
#define CFG_RX0_HDR (1u << 2)
#define CFG_TX0_HDR (1u << 3)
#define RESET_RX0 (1u << 0)
#define RESET_TX0 (1u << 1)
#define SINK_RF_TX 0
#define SINK_HOST0_RX 1
#define SRC_RF_RX 0
#define SRC_HOST0_TX 1
#define ROUTE_NONE 0xF
#define HDR_MAGIC 0xA5u
#define FLAG_DROPPED (1u << 0)
#define FLAG_CUT (1u << 7)

static uint32_t rd(struct iio_device *shell, unsigned addr)
{
	uint32_t v = 0;
	iio_device_reg_read(shell, addr, &v);
	return v;
}

static void wr(struct iio_device *shell, unsigned addr, uint32_t v)
{
	iio_device_reg_write(shell, addr, v);
}

// RX header mode on or off on host port 0 (Soapy setPortHeaders, RX side)
static void rx_headers(struct iio_device *shell, int on, uint32_t slot_bits)
{
	uint32_t cfg = rd(shell, REG_CONFIG);
	cfg = on ? (cfg | CFG_RX0_HDR) : (cfg & ~CFG_RX0_HDR);
	unsigned addr = REG_ROUTE + 4 * SINK_HOST0_RX;
	uint32_t route = rd(shell, addr);
	if (route == ROUTE_NONE)
		route = SRC_RF_RX;
	wr(shell, addr, ROUTE_NONE);
	wr(shell, REG_PORT_RESET, RESET_RX0 | slot_bits);
	wr(shell, REG_CONFIG, cfg);
	wr(shell, addr, route);
}

static void enable_pair(struct iio_device *dev, int output)
{
	unsigned n = iio_device_get_channels_count(dev);
	for (unsigned i = 0; i < n; i++) {
		struct iio_channel *c = iio_device_get_channel(dev, i);
		if (iio_channel_is_output(c) != output || !iio_channel_is_scan_element(c))
			continue;
		const char *id = iio_channel_get_id(c);
		if (!strcmp(id, "voltage0") || !strcmp(id, "voltage1"))
			iio_channel_enable(c);
		else
			iio_channel_disable(c);
	}
}

// SoapySDR::ticksToTimeNs, so times match those the Soapy module reports and takes
static long long ticks_to_ns(long long ticks, double rate)
{
	long long ratell = (long long)rate, full = ticks / ratell, err = ticks - full * ratell;
	double part = full * (rate - ratell), frac = ((err - part) * 1000000000.0) / rate;
	return full * 1000000000LL + llround(frac);
}

// n samples (CS16, 12-bit) into out, packets of host port 0 with headers. Returns the
// samples received (n unless timed out) or a negative errno. *t_first: hardware time (ns) of
// the first sample, -1 if none. Drops between packets: *overflows events, *dropped samples in
// all; the first max_drops events as (sample index in out, samples lost) in drop_pos /
// drop_len. buflen: samples per IIO buffer (4 kernel buffers, never more: docs/phase3_modules.md).
long long gl_rx(int16_t *out, long long n, long long buflen, double rate, double timeout_s,
		uint32_t slot_bits, long long *t_first, long long *overflows, long long *dropped,
		long long *drop_pos, long long *drop_len, int max_drops)
{
	*t_first = -1;
	*overflows = *dropped = 0;
	struct iio_context *ctx = iio_create_local_context();
	if (!ctx)
		return -errno;
	struct iio_device *rx = iio_context_find_device(ctx, "cf-ad9361-lpc");
	struct iio_device *shell = iio_context_find_device(ctx, "glidelink-shell");
	if (!rx || !shell) {
		iio_context_destroy(ctx);
		return -ENODEV;
	}
	iio_context_set_timeout(ctx, 1000);
	int shift = rd(shell, REG_VERSION) >= 0x00010500 ? 4 : 0;
	enable_pair(rx, 0);

	uint32_t cfg = rd(shell, REG_CONFIG);
	wr(shell, REG_CONFIG, cfg & ~CFG_RX_ENABLE);
	rx_headers(shell, 1, slot_bits);
	struct iio_buffer *buf = iio_device_create_buffer(rx, buflen, false);
	wr(shell, REG_CONFIG, rd(shell, REG_CONFIG) | CFG_RX_ENABLE);
	if (!buf) {
		int e = errno;
		rx_headers(shell, 0, slot_bits);
		iio_context_destroy(ctx);
		return -e;
	}

	long long got = 0, ret = 0, next_time = -1;
	uint32_t hdr[4];
	unsigned hdr_pos = 0;
	long long pkt_left = 0, timeouts = 0, max_timeouts = (long long)ceil(timeout_s);
	while (got < n) {
		ssize_t r = iio_buffer_refill(buf);
		if (r == -ETIMEDOUT) {
			if (++timeouts > max_timeouts)
				break;
			continue;
		}
		if (r < 0) {
			ret = r;
			break;
		}
		const uint32_t *w = iio_buffer_start(buf);
		long long avail = r / 4, pos = 0;
		while (pos < avail && got < n) {
			if (hdr_pos < 4) {
				hdr[hdr_pos++] = w[pos++];
				if (hdr_pos == 1 && ((hdr[0] >> 24) != HDR_MAGIC || (hdr[0] & 0xffff) == 0))
					hdr_pos = 0;             // not a header: resynchronise
				if (hdr_pos == 4) {
					pkt_left = hdr[0] & 0xffff;
					long long t = (long long)(((uint64_t)hdr[3] << 32) | hdr[2]);
					if (next_time < 0) {
						*t_first = ticks_to_ns(t, rate);
					} else if (t != next_time) {
						// a gap in the packet times: the shell dropped packets (RX_OVERFLOW)
						// or the DMA lost words (HOST0_RX_OVF)
						long long lost = t - next_time;
						if (*overflows < max_drops) {
							drop_pos[*overflows] = got;
							drop_len[*overflows] = lost;
						}
						++*overflows;
						*dropped += lost;
					}
					next_time = t + pkt_left;
				}
				continue;
			}
			long long k = pkt_left;
			if (k > avail - pos)
				k = avail - pos;
			if (k > n - got)
				k = n - got;
			const int16_t *p = (const int16_t *)(w + pos);
			int16_t *d = out + 2 * got;
			for (long long j = 0; j < 2 * k; j++)
				d[j] = (int16_t)(p[j] >> shift);
			pos += k;
			got += k;
			pkt_left -= k;
			if (pkt_left == 0)
				hdr_pos = 0;
		}
	}
	iio_buffer_destroy(buf);
	rx_headers(shell, 0, slot_bits);     // raw again for tools that do not know the headers
	iio_context_destroy(ctx);
	return ret < 0 ? ret : got;
}

struct gl_cyclic {
	struct iio_context *ctx;
	struct iio_buffer *buf;
};

// starts repeating n samples (CS16, 12-bit) of iq from a cyclic buffer on host port 0 (raw,
// RF TX fed from host port 0 if it has no route). n must be even (64-bit DMA words). Returns
// a handle for gl_tx_cyclic_stop, NULL (errno set) if the buffer cannot be made.
void *gl_tx_cyclic_start(const int16_t *iq, long long n, uint32_t slot_bits)
{
	if (n <= 0 || n % 2) {
		errno = EINVAL;
		return NULL;
	}
	struct gl_cyclic *h = calloc(1, sizeof(*h));
	h->ctx = iio_create_local_context();
	struct iio_device *tx = h->ctx ? iio_context_find_device(h->ctx, "cf-ad9361-dds-core-lpc") : NULL;
	struct iio_device *shell = h->ctx ? iio_context_find_device(h->ctx, "glidelink-shell") : NULL;
	if (!tx || !shell) {
		if (h->ctx)
			iio_context_destroy(h->ctx);
		free(h);
		errno = ENODEV;
		return NULL;
	}
	// TX headers off (Soapy setPortHeaders, TX side)
	wr(shell, REG_PORT_RESET, RESET_TX0 | slot_bits);
	wr(shell, REG_CONFIG, rd(shell, REG_CONFIG) & ~CFG_TX0_HDR);
	if (rd(shell, REG_ROUTE + 4 * SINK_RF_TX) == ROUTE_NONE)
		wr(shell, REG_ROUTE + 4 * SINK_RF_TX, SRC_HOST0_TX);
	enable_pair(tx, 1);
	h->buf = iio_device_create_buffer(tx, n, true);
	if (!h->buf) {
		int e = errno;
		iio_context_destroy(h->ctx);
		free(h);
		errno = e;
		return NULL;
	}
	int16_t *d = iio_buffer_start(h->buf);
	for (long long j = 0; j < 2 * n; j++) {
		int v = iq[j] < -2048 ? -2048 : iq[j] > 2047 ? 2047 : iq[j];
		d[j] = (int16_t)(v * 16);            // the DAC's MSB-aligned word
	}
	ssize_t r = iio_buffer_push(h->buf);
	if (r < 0) {
		iio_buffer_destroy(h->buf);
		iio_context_destroy(h->ctx);
		free(h);
		errno = (int)-r;
		return NULL;
	}
	return h;
}

void gl_tx_cyclic_stop(void *handle)
{
	struct gl_cyclic *h = handle;
	if (!h)
		return;
	iio_buffer_destroy(h->buf);
	iio_context_destroy(h->ctx);
	free(h);
}
