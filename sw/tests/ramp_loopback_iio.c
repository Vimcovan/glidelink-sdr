// Bit-exact full-duplex data path check through the AD9361 digital loopback, in C on libiio,
// for rates the Python version (ramp_loopback.py) cannot feed.
//
// TX sends I = a 12-bit counter running across buffers and Q = the TX buffer number; RX checks
// that I steps by exactly 1 (mod 4096) and Q only stays or steps by 1, so lost samples (I steps)
// and stale buffers (Q jumps) on either side are counted.
//
//   gcc -O2 -o ramp_loopback_iio ramp_loopback_iio.c -liio -lpthread
//   ./ramp_loopback_iio [rate_sps] [seconds] [buffer_samples]

#include <iio.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static struct iio_buffer *txbuf;
static volatile int stop;
static long tx_buffers;

static double now(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec * 1e-9;
}

static void *tx_loop(void *arg)
{
	uint32_t n = 0;

	(void)arg;
	while (!stop) {
		int16_t *p = iio_buffer_start(txbuf), *end = iio_buffer_end(txbuf);
		int16_t q = (int16_t)(((tx_buffers % 4096) - 2048) * 16);
		for (; p < end; p += 2, n++) {
			p[0] = (int16_t)(((int)(n % 4096) - 2048) * 16);
			p[1] = q;
		}
		if (iio_buffer_push(txbuf) < 0) {
			perror("TX push");
			break;
		}
		tx_buffers++;
	}
	return NULL;
}

static void enable_iq(struct iio_device *dev, int output)
{
	iio_channel_enable(iio_device_find_channel(dev, "voltage0", output));
	iio_channel_enable(iio_device_find_channel(dev, "voltage1", output));
}

int main(int argc, char **argv)
{
	long long rate = argc > 1 ? atof(argv[1]) : 30.72e6;
	double seconds = argc > 2 ? atof(argv[2]) : 10;
	size_t len = argc > 3 ? atol(argv[3]) : 65536;

	struct iio_context *ctx = iio_create_local_context();
	struct iio_device *phy = iio_context_find_device(ctx, "ad9361-phy");
	struct iio_device *rx = iio_context_find_device(ctx, "cf-ad9361-lpc");
	struct iio_device *tx = iio_context_find_device(ctx, "cf-ad9361-dds-core-lpc");
	if (!phy || !rx || !tx) {
		fprintf(stderr, "AD9361 IIO devices not found\n");
		return 1;
	}
	// shell 1.1 and later: this test uses host port 0 raw, and a program that
	// was killed may have left the packet headers on (CONFIG bits 2 / 3) or a
	// packet cut off in the shell, so clear the headers and flush the port
	struct iio_device *shell = iio_context_find_device(ctx, "glidelink-shell");
	uint32_t version = 0, cfg = 0;
	if (shell && iio_device_reg_read(shell, 0x004, &version) == 0 && version >= 0x00010100 &&
	    iio_device_reg_read(shell, 0x054, &cfg) == 0) {
		iio_device_reg_write(shell, 0x054, cfg & ~0xcu);
		iio_device_reg_write(shell, 0x05C, 3);
	}

	iio_channel_attr_write_longlong(iio_device_find_channel(phy, "voltage0", false),
					"sampling_frequency", rate);
	iio_device_debug_attr_write(phy, "loopback", "1");

	enable_iq(rx, 0);
	enable_iq(tx, 1);
	txbuf = iio_device_create_buffer(tx, len, false);
	struct iio_buffer *rxbuf = iio_device_create_buffer(rx, len, false);
	if (!txbuf || !rxbuf) {
		perror("create buffer");
		return 1;
	}

	pthread_t th;
	pthread_create(&th, NULL, tx_loop, NULL);

	long long samples = 0, i_err = 0, q_err = 0, refills = 0;
	int have_prev = 0, prev_i = 0, prev_q = 0;
	double t0 = now();
	while (now() - t0 < seconds) {
		ssize_t r = iio_buffer_refill(rxbuf);
		if (r < 0) {
			perror("RX refill");
			break;
		}
		if (++refills <= 4)
			continue;	// RX starts before the first TX buffer reaches the DAC
		const int16_t *p = iio_buffer_start(rxbuf), *end = iio_buffer_end(rxbuf);
		for (; p < end; p += 2, samples++) {
			int i = p[0], q = p[1];
			if (have_prev) {
				if (((i - prev_i) & 4095) != 1)
					i_err++;
				int dq = (q - prev_q) & 4095;
				if (dq != 0 && dq != 1)
					q_err++;
			}
			prev_i = i;
			prev_q = q;
			have_prev = 1;
		}
	}
	double dt = now() - t0;
	stop = 1;
	pthread_join(th, NULL);

	iio_buffer_destroy(rxbuf);
	iio_buffer_destroy(txbuf);
	iio_device_debug_attr_write(phy, "loopback", "0");
	printf("%.2f MSPS set, RX %.2f MSPS over %.1f s (%lld buffers of %zu), %ld TX buffers: "
	       "I steps != 1: %lld, Q jumps: %lld\n", rate / 1e6, samples / dt / 1e6, dt, refills,
	       len, tx_buffers, i_err, q_err);
	iio_context_destroy(ctx);
	return 0;
}
